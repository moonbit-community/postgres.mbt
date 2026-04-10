// TCP/TLS connection setup and PostgreSQL startup authentication.

///|
/// Open the underlying socket and negotiate TLS according to `Config.ssl_mode`.
async fn connect_stream(config : Config) -> Stream {
  let conn = @socket.Tcp::connect_to_host(config.host, port=config.port)
  match config.ssl_mode {
    Disable => Plain(conn)
    Prefer | Require => {
      let request = @buffer.new()
      // PostgreSQL SSL negotiation is a one-byte capability probe that happens
      // before the normal startup packet.
      @frontend.ssl_request(request)
      conn.write(request.to_bytes())
      let response = conn.read_exactly(1)
      match response[0] {
        b'S' => {
          // Upgrade the existing TCP connection in place so the subsequent
          // startup/authentication exchange stays on the same transport.
          let tls = @tls.Tls::client(conn, host=config.host) catch {
            err => {
              conn.close()
              raise ClientError::Ssl(err.to_string())
            }
          }
          Secure(tls)
        }
        b'N' =>
          if config.ssl_mode is Require {
            conn.close()
            raise ClientError::Ssl("server does not support TLS")
          } else {
            Plain(conn)
          }
        _ => {
          conn.close()
          raise ClientError::Ssl("invalid SSL negotiation response")
        }
      }
    }
  }
}

///|
/// Startup information captured before the normal request loop begins.
priv struct StartupState {
  process_id : Int
  secret_key : Int
  parameters : Map[String, String]
  transaction_status : Byte
}

///|
/// Complete PostgreSQL startup, including authentication and parameter capture.
///
/// The function runs before `Shared` exists, so it works directly with the raw
/// transport stream. Once `ReadyForQuery` arrives, the caller has everything
/// needed to construct the shared runtime state.
async fn startup(stream : Stream, config : Config) -> StartupState {
  // Startup parameters are sent exactly once; afterward the server drives the
  // rest of the handshake with backend messages.
  let parameters : Array[(BytesView, BytesView)] = [
    (b"user"[:], @proto.utf8_encode(config.user)[:]),
    (b"database"[:], @proto.utf8_encode(config.database)[:]),
    (b"client_encoding"[:], b"UTF8"[:]),
    (b"application_name"[:], @proto.utf8_encode(config.application_name)[:]),
  ]
  let buf = @buffer.new()
  @frontend.startup_message(parameters.iter(), buf)
  stream.write(buf.to_bytes())
  let status : Map[String, String] = {}
  let mut process_id = 0
  let mut secret_key = 0
  let mut transaction_status = b'I'
  let mut scram : @sasl.ScramSha256? = None
  // SCRAM authentication spans multiple round trips, so its local state has to
  // survive across several backend auth messages.
  for msg = read_message(stream) {
    match msg {
      @backend.Message::AuthenticationOk => continue read_message(stream)
      @backend.Message::AuthenticationCleartextPassword => {
        send_password_message(stream, config.password)
        continue read_message(stream)
      }
      @backend.Message::AuthenticationMd5Password(body) => {
        send_md5_password_message(
          stream,
          config.user,
          config.password,
          body.salt,
        )
        continue read_message(stream)
      }
      @backend.Message::AuthenticationSasl(body) => {
        scram = Some(begin_scram(stream, body, config.password))
        continue read_message(stream)
      }
      @backend.Message::AuthenticationSaslContinue(body) => {
        continue_scram(stream, scram, body.data())
        continue read_message(stream)
      }
      @backend.Message::AuthenticationSaslFinal(body) => {
        finish_scram(scram, body.data())
        continue read_message(stream)
      }
      @backend.Message::ParameterStatus(body) => {
        // Capture the initial session parameter snapshot now so steady-state
        // runtime helpers start with the same view PostgreSQL advertised here.
        status[body.name_str()] = body.value_str()
        continue read_message(stream)
      }
      @backend.Message::BackendKeyData(body) => {
        // These values are later reused by `CancelToken` on a separate short-
        // lived control connection.
        process_id = body.process_id
        secret_key = body.secret_key
        continue read_message(stream)
      }
      @backend.Message::NoticeResponse(_) => continue read_message(stream)
      @backend.Message::ReadyForQuery(body) => {
        // `ReadyForQuery` is the handoff point from startup/authentication into
        // the ordinary request scheduling loop.
        transaction_status = body.status
        return {
          process_id,
          secret_key,
          parameters: status,
          transaction_status,
        }
      }
      @backend.Message::ErrorResponse(body) =>
        raise ClientError::Database(parse_database_error(body.fields()))
      @backend.Message::AuthenticationKerberosV5
      | @backend.Message::AuthenticationScmCredential
      | @backend.Message::AuthenticationGss
      | @backend.Message::AuthenticationGssContinue(_)
      | @backend.Message::AuthenticationSspi =>
        raise ClientError::Authentication(
          "server requested an unsupported authentication method",
        )
      _ => raise ClientError::UnexpectedMessage("unexpected startup message")
    }
  }
}

///|
/// Read and parse one backend message during startup.
async fn read_message(stream : Stream) -> @backend.Message {
  let header = stream.read_exactly(5)
  let body_len = @proto.ByteReader::new(header[1:]).read_i32_be()
  let body = stream.read_exactly(body_len - 4)
  // Reassemble the full packet so startup uses the same parser and validation
  // path as the steady-state connection loop.
  let packet = @buffer.new(size_hint=header.length() + body.length())
  packet.write_bytes(header)
  packet.write_bytes(body)
  match @backend.Message::parse(packet.to_bytes()[:]) {
    Some(parsed) => parsed.message
    None => raise ClientError::UnexpectedMessage("incomplete backend message")
  }
}

///|
/// Send a cleartext password response.
async fn send_password_message(stream : Stream, password : String?) -> Unit {
  let password = require_password(password)
  let buf = @buffer.new()
  @frontend.password_message(@proto.utf8_encode(password)[:], buf)
  stream.write(buf.to_bytes())
}

///|
/// Send an MD5 password response using PostgreSQL's legacy auth flow.
async fn send_md5_password_message(
  stream : Stream,
  user : String,
  password : String?,
  salt : BytesView,
) -> Unit {
  let password = require_password(password)
  let digest = @auth.md5_hash(
    @proto.utf8_encode(user)[:],
    @proto.utf8_encode(password)[:],
    salt,
  )
  let buf = @buffer.new()
  @frontend.password_message(digest[:], buf)
  stream.write(buf.to_bytes())
}

///|
/// Start a SCRAM-SHA-256 authentication exchange.
#warnings("-14")
async fn begin_scram(
  stream : Stream,
  body : @backend.AuthenticationSaslBody,
  password : String?,
) -> @sasl.ScramSha256 {
  guard supports_scram(body) else {
    raise ClientError::Authentication(
      "server does not offer SCRAM-SHA-256 authentication",
    )
  }
  let password = require_password(password)
  let nonce = @tls.rand_bytes(18)
  // This client currently uses plain SCRAM-SHA-256 without channel binding and
  // keeps the nonce locally for later challenge/response rounds.
  let scram = @sasl.ScramSha256::new(
    @proto.utf8_encode(password)[:],
    @sasl.ChannelBinding::unsupported(),
    nonce[:],
  )
  let buf = @buffer.new()
  @frontend.sasl_initial_response(@sasl.SCRAM_SHA_256[:], scram.message(), buf)
  stream.write(buf.to_bytes())
  scram
}

///|
/// Continue an in-flight SCRAM exchange with the server challenge payload.
async fn continue_scram(
  stream : Stream,
  scram : @sasl.ScramSha256?,
  data : BytesView,
) -> Unit {
  let scram = require_scram(scram)
  // Each server challenge mutates the SCRAM state machine before the next
  // client proof is serialized and written.
  scram.update(data)
  let buf = @buffer.new()
  @frontend.sasl_response(scram.message(), buf)
  stream.write(buf.to_bytes())
}

///|
/// Finish an in-flight SCRAM exchange.
fn finish_scram(scram : @sasl.ScramSha256?, data : BytesView) -> Unit raise {
  require_scram(scram).finish(data)
}

///|
/// Require that a password is present in the connection config.
fn require_password(password : String?) -> String raise {
  match password {
    Some(password) => password
    None => raise ClientError::Authentication("server requires a password")
  }
}

///|
/// Require that a SCRAM exchange has already been started.
fn require_scram(scram : @sasl.ScramSha256?) -> @sasl.ScramSha256 raise {
  match scram {
    Some(scram) => scram
    None =>
      raise ClientError::UnexpectedMessage(
        "received SCRAM continuation without an active SCRAM exchange",
      )
  }
}

///|
/// Return whether the server offered SCRAM-SHA-256.
fn supports_scram(body : @backend.AuthenticationSaslBody) -> Bool raise {
  let mechanisms = body.mechanisms()
  // PostgreSQL may advertise multiple SASL mechanisms; accept as soon as the
  // standard SCRAM-SHA-256 entry appears.
  for mechanism = mechanisms.next() {
    match mechanism {
      None => break false
      Some(mechanism) =>
        if mechanism == @sasl.SCRAM_SHA_256 {
          break true
        } else {
          continue mechanisms.next()
        }
    }
  }
}
