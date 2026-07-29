// TCP/TLS connection setup and PostgreSQL startup authentication.

///|
/// Channel-binding material exposed by the active transport, if any.
priv enum TlsChannelBinding {
  NoBinding
  TlsServerEndPoint(Bytes)
}

///|
/// Result of opening the socket and negotiating TLS.
priv struct ConnectionSetup {
  stream : Stream
  channel_binding : TlsChannelBinding
}

///|
let deprecated_md5_authentication_message = "server requested deprecated md5 authentication; use scram-sha-256 or password"

///|
let channel_binding_required_unsupported_message = "channel binding required but not supported by server's authentication request"

///|
let channel_binding_required_not_used_message = "channel binding required, but server authenticated client without channel binding"

///|
/// Resolve the socket host for the current connection target.
fn Config::connect_host(self : Config) -> String {
  match self.hostaddr {
    Some(hostaddr) => hostaddr
    None => if self.host == "" { "127.0.0.1" } else { self.host }
  }
}

///|
fn SslMode::requires_tls(self : SslMode) -> Bool {
  match self {
    Disable => false
    VerifyCa | VerifyFull => true
  }
}

///|
fn Config::tls_verify_host(self : Config) -> String? raise {
  match self.ssl_mode {
    VerifyFull =>
      if self.host != "" {
        Some(self.host)
      } else {
        match self.hostaddr {
          Some(hostaddr) => Some(hostaddr)
          None =>
            raise ClientError::Ssl(
              "sslmode=verify-full requires explicit host or hostaddr",
            )
        }
      }
    Disable | VerifyCa => None
  }
}

///|
fn Config::tls_root_cert_file(self : Config) -> String? {
  match self.ssl_root_cert {
    Some(root_cert) =>
      if root_cert == "system" {
        None
      } else {
        Some(root_cert)
      }
    None => None
  }
}

///|
fn Config::validate_tls_config(self : Config) -> Unit raise {
  match self.ssl_root_cert {
    Some(root_cert) =>
      if root_cert == "system" && self.ssl_mode != VerifyFull {
        raise ClientError::Ssl(
          "sslrootcert=system requires sslmode=verify-full",
        )
      }
    None => ()
  }
  if self.ssl_mode is VerifyFull {
    ignore(self.tls_verify_host())
  }
}

///|
fn Config::tls_trusted_root(self : Config) -> @tls.TrustedRoot {
  if !self.ssl_mode.requires_tls() {
    NoVerification
  } else {
    match self.tls_root_cert_file() {
      Some(file) => CustomPemFile(file)
      None => SystemRoot
    }
  }
}

///|
fn TlsChannelBinding::from_tls(tls : @tls.Tls) -> TlsChannelBinding raise {
  let digest = tls.server_endpoint_channel_binding() catch {
    err =>
      match err {
        @tls.TlsError::TlsError(message) =>
          if message == "tls-server-endpoint channel binding unavailable" {
            return NoBinding
          } else {
            raise err
          }
        _ => raise err
      }
  }
  TlsServerEndPoint(digest)
}

///|
fn tls_error_message(err : Error) -> String {
  match err {
    @tls.TlsError::TlsError(message) => message
    @tls.ConnectionClosed => "TLS connection closed"
    _ => err.to_string()
  }
}

///|
/// Open the underlying socket and negotiate TLS according to `Config.ssl_mode`.
async fn connect_stream(config : Config) -> ConnectionSetup {
  config.validate_tls_config()
  let conn = @socket.Tcp::connect_to_host(
    config.connect_host(),
    port=config.port,
  )
  if config.keepalives == Some(true) {
    conn.enable_keepalive(
      idle_before_keep_alive=config.keepalives_idle_s.unwrap_or(7200),
    )
  }
  match config.ssl_mode {
    Disable => { stream: Plain(conn), channel_binding: NoBinding }
    VerifyCa | VerifyFull => {
      let request = Buffer()
      // PostgreSQL SSL negotiation is a one-byte capability probe that happens
      // before the normal startup packet.
      @frontend.ssl_request(request)
      conn.write(request.to_bytes())
      let response = conn.read_exactly(1)
      match response[0] {
        b'S' => {
          // Upgrade the existing TCP connection in place so the subsequent
          // startup/authentication exchange stays on the same transport.
          let tls = @tls.Tls::client(
            conn,
            host?=config.tls_verify_host(),
            trust=config.tls_trusted_root(),
          ) catch {
            err => {
              conn.close()
              raise ClientError::Ssl(tls_error_message(err))
            }
          }
          let channel_binding = TlsChannelBinding::from_tls(tls) catch {
            err => {
              tls.close()
              raise ClientError::Ssl(tls_error_message(err))
            }
          }
          { stream: Secure(tls), channel_binding }
        }
        b'N' => {
          conn.close()
          raise ClientError::Ssl("server does not support TLS")
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
async fn startup(setup : ConnectionSetup, config : Config) -> StartupState {
  let stream = setup.stream
  // Startup parameters are sent exactly once; afterward the server drives the
  // rest of the handshake with backend messages.
  let parameters : Array[(BytesView, BytesView)] = [
    (b"user"[:], @proto.utf8_encode(config.user)[:]),
    (b"database"[:], @proto.utf8_encode(config.database)[:]),
    (b"client_encoding"[:], b"UTF8"[:]),
    (b"application_name"[:], @proto.utf8_encode(config.application_name)[:]),
  ]
  match config.options {
    Some(options) =>
      parameters.push((b"options"[:], @proto.utf8_encode(options)[:]))
    None => ()
  }
  let buf = Buffer()
  @frontend.startup_message(parameters.iter(), buf)
  stream.write(buf.to_bytes())
  let status : Map[String, String] = Map([])
  let mut process_id = 0
  let mut secret_key = 0
  let mut transaction_status = b'I'
  let mut scram : @auth.ScramSha256? = None
  let mut scram_channel_bound = false
  let mut channel_binding_used = false
  // SCRAM authentication spans multiple round trips, so its local state has to
  // survive across several backend auth messages.
  for msg = read_message(stream) {
    match msg {
      AuthenticationOk => {
        verify_required_channel_binding(config, channel_binding_used)
        continue read_message(stream)
      }
      AuthenticationCleartextPassword => {
        reject_unsupported_channel_binding(config)
        send_password_message(stream, config.password)
        continue read_message(stream)
      }
      AuthenticationMd5Password(_) => {
        reject_unsupported_channel_binding(config)
        raise ClientError::Authentication(deprecated_md5_authentication_message)
      }
      AuthenticationSasl(body) => {
        let (next_scram, channel_bound) = begin_scram(
          stream,
          body,
          config.password,
          config.channel_binding,
          setup.channel_binding,
        )
        scram = Some(next_scram)
        scram_channel_bound = channel_bound
        continue read_message(stream)
      }
      AuthenticationSaslContinue(body) => {
        continue_scram(stream, scram, body.data())
        continue read_message(stream)
      }
      AuthenticationSaslFinal(body) => {
        finish_scram(scram, body.data())
        if scram_channel_bound {
          channel_binding_used = true
        }
        continue read_message(stream)
      }
      ParameterStatus(body) => {
        // Capture the initial session parameter snapshot now so steady-state
        // runtime helpers start with the same view PostgreSQL advertised here.
        status[body.name_str()] = body.value_str()
        continue read_message(stream)
      }
      BackendKeyData(body) => {
        // These values are later reused by `CancelToken` on a separate short-
        // lived control connection.
        process_id = body.process_id
        secret_key = body.secret_key
        continue read_message(stream)
      }
      NoticeResponse(_) => continue read_message(stream)
      ReadyForQuery(body) => {
        verify_required_channel_binding(config, channel_binding_used)
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
      ErrorResponse(body) =>
        raise ClientError::Database(parse_database_error(body.fields()))
      AuthenticationKerberosV5
      | AuthenticationScmCredential
      | AuthenticationGss
      | AuthenticationGssContinue(_)
      | AuthenticationSspi => {
        reject_unsupported_channel_binding(config)
        raise ClientError::Authentication(
          "server requested an unsupported authentication method",
        )
      }
      _ => raise ClientError::UnexpectedMessage("unexpected startup message")
    }
  }
}

///|
fn reject_unsupported_channel_binding(config : Config) -> Unit raise {
  if config.channel_binding is Require {
    raise ClientError::Authentication(
      channel_binding_required_unsupported_message,
    )
  }
}

///|
fn verify_required_channel_binding(
  config : Config,
  channel_binding_used : Bool,
) -> Unit raise {
  if config.channel_binding is Require && !channel_binding_used {
    raise ClientError::Authentication(channel_binding_required_not_used_message)
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
  let packet = Buffer(size_hint=header.length() + body.length())
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
  let buf = Buffer()
  @frontend.password_message(@proto.utf8_encode(password)[:], buf)
  stream.write(buf.to_bytes())
}

///|
/// Start a SCRAM-SHA-256 authentication exchange.
#warnings("-14")
async fn begin_scram(
  stream : Stream,
  body : @backend.AuthenticationSaslBody,
  password : String?,
  channel_binding : ChannelBinding,
  transport_binding : TlsChannelBinding,
) -> (@auth.ScramSha256, Bool) {
  let password = require_password(password)
  let nonce = secure_random_bytes(18)
  let (mechanism, scram_binding) = choose_scram_binding(
    body, channel_binding, transport_binding,
  )
  let channel_bound = scram_binding is TlsServerEndPoint(_)
  let scram = @auth.ScramSha256::new(
    @proto.utf8_encode(password)[:],
    scram_binding,
    nonce[:],
  )
  let buf = Buffer()
  @frontend.sasl_initial_response(mechanism[:], scram.message(), buf)
  stream.write(buf.to_bytes())
  (scram, channel_bound)
}

///|
/// Continue an in-flight SCRAM exchange with the server challenge payload.
async fn continue_scram(
  stream : Stream,
  scram : @auth.ScramSha256?,
  data : BytesView,
) -> Unit {
  let scram = require_scram(scram)
  // Each server challenge mutates the SCRAM state machine before the next
  // client proof is serialized and written.
  scram.update(data)
  let buf = Buffer()
  @frontend.sasl_response(scram.message(), buf)
  stream.write(buf.to_bytes())
}

///|
/// Finish an in-flight SCRAM exchange.
fn finish_scram(scram : @auth.ScramSha256?, data : BytesView) -> Unit raise {
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
fn require_scram(scram : @auth.ScramSha256?) -> @auth.ScramSha256 raise {
  match scram {
    Some(scram) => scram
    None =>
      raise ClientError::UnexpectedMessage(
        "received SCRAM continuation without an active SCRAM exchange",
      )
  }
}

///|
/// Choose the SCRAM mechanism and GS2 binding header for the current target.
fn choose_scram_binding(
  body : @backend.AuthenticationSaslBody,
  requested : ChannelBinding,
  transport_binding : TlsChannelBinding,
) -> (Bytes, @auth.ChannelBinding) raise {
  match requested {
    Disable => {
      guard supports_scram(body) else {
        raise ClientError::Authentication(
          "server does not offer SCRAM-SHA-256 authentication",
        )
      }
      (@auth.SCRAM_SHA_256, @auth.ChannelBinding::unsupported())
    }
    Prefer =>
      match transport_binding {
        TlsServerEndPoint(signature) =>
          if supports_scram_plus(body) {
            (
              @auth.SCRAM_SHA_256_PLUS,
              @auth.ChannelBinding::tls_server_end_point(signature),
            )
          } else if supports_scram(body) {
            (@auth.SCRAM_SHA_256, @auth.ChannelBinding::unsupported())
          } else {
            raise ClientError::Authentication(
              "server does not offer SCRAM-SHA-256 authentication",
            )
          }
        NoBinding => {
          guard supports_scram(body) else {
            raise ClientError::Authentication(
              "server does not offer SCRAM-SHA-256 authentication",
            )
          }
          (@auth.SCRAM_SHA_256, @auth.ChannelBinding::unsupported())
        }
      }
    Require =>
      match transport_binding {
        TlsServerEndPoint(signature) =>
          if supports_scram_plus(body) {
            (
              @auth.SCRAM_SHA_256_PLUS,
              @auth.ChannelBinding::tls_server_end_point(signature),
            )
          } else {
            raise ClientError::Authentication(
              "server does not offer SCRAM-SHA-256-PLUS authentication",
            )
          }
        NoBinding =>
          raise ClientError::Authentication(
            "channel binding requires TLS with tls-server-end-point support",
          )
      }
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
        if mechanism == @auth.SCRAM_SHA_256 {
          break true
        } else {
          continue mechanisms.next()
        }
    }
  }
}

///|
/// Return whether the server offered SCRAM-SHA-256-PLUS.
fn supports_scram_plus(body : @backend.AuthenticationSaslBody) -> Bool raise {
  let mechanisms = body.mechanisms()
  for mechanism = mechanisms.next() {
    match mechanism {
      None => break false
      Some(mechanism) =>
        if mechanism == @auth.SCRAM_SHA_256_PLUS {
          break true
        } else {
          continue mechanisms.next()
        }
    }
  }
}
