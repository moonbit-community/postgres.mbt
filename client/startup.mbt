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
fn Config::uses_system_trust_store(self : Config) -> Bool {
  match self.ssl_root_cert {
    Some(root_cert) => root_cert == "system"
    None => true
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
#cfg(not(platform="windows"))
fn Config::validate_platform_tls_config(self : Config) -> Unit {
  ignore(self)
}

///|
#cfg(platform="windows")
fn Config::validate_platform_tls_config(self : Config) -> Unit raise {
  if !self.uses_system_trust_store() {
    raise ClientError::Ssl(
      "custom trust-store selection is not supported on Windows",
    )
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
  self.validate_platform_tls_config()
}

///|
fn Config::tls_client_options(self : Config) -> @local_tls.ClientOptions raise {
  @local_tls.ClientOptions::new(
    verify_peer=self.ssl_mode.requires_tls(),
    verify_host=self.tls_verify_host(),
    use_system_trust_store=self.uses_system_trust_store(),
    root_cert_file=self.tls_root_cert_file(),
  )
}

///|
fn from_transport_channel_binding(
  binding : @local_tls.ChannelBinding,
) -> TlsChannelBinding {
  match binding {
    @local_tls.ChannelBinding::NoBinding => NoBinding
    @local_tls.ChannelBinding::TlsServerEndPoint(digest) =>
      TlsServerEndPoint(digest)
  }
}

///|
fn tls_error_message(err : Error) -> String {
  match err {
    @local_tls.TlsError::TlsError(message) => message
    @local_tls.ConnectionClosed => "TLS connection closed"
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
          let tls = @local_tls.Tls::client_with_options(
            conn,
            config.tls_client_options(),
          ) catch {
            err => {
              conn.close()
              raise ClientError::Ssl(tls_error_message(err))
            }
          }
          let channel_binding = from_transport_channel_binding(
            tls.channel_binding() catch {
              err => {
                tls.close()
                raise ClientError::Ssl(tls_error_message(err))
              }
            },
          )
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
  let buf = @buffer.new()
  @frontend.startup_message(parameters.iter(), buf)
  stream.write(buf.to_bytes())
  let status : Map[String, String] = {}
  let mut process_id = 0
  let mut secret_key = 0
  let mut transaction_status = b'I'
  let mut scram : @auth.ScramSha256? = None
  // SCRAM authentication spans multiple round trips, so its local state has to
  // survive across several backend auth messages.
  for msg = read_message(stream) {
    match msg {
      @backend.Message::AuthenticationOk => continue read_message(stream)
      @backend.Message::AuthenticationCleartextPassword => {
        send_password_message(stream, config.password)
        continue read_message(stream)
      }
      @backend.Message::AuthenticationMd5Password(_) =>
        raise ClientError::Authentication(deprecated_md5_authentication_message)
      @backend.Message::AuthenticationSasl(body) => {
        scram = Some(
          begin_scram(
            stream,
            body,
            config.password,
            config.channel_binding,
            setup.channel_binding,
          ),
        )
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
/// Start a SCRAM-SHA-256 authentication exchange.
#warnings("-14")
async fn begin_scram(
  stream : Stream,
  body : @backend.AuthenticationSaslBody,
  password : String?,
  channel_binding : ChannelBinding,
  transport_binding : TlsChannelBinding,
) -> @auth.ScramSha256 {
  let password = require_password(password)
  let nonce = @local_tls.rand_bytes(18)
  let (mechanism, scram_binding) = choose_scram_binding(
    body, channel_binding, transport_binding,
  )
  let scram = @auth.ScramSha256::new(
    @proto.utf8_encode(password)[:],
    scram_binding,
    nonce[:],
  )
  let buf = @buffer.new()
  @frontend.sasl_initial_response(mechanism[:], scram.message(), buf)
  stream.write(buf.to_bytes())
  scram
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
  let buf = @buffer.new()
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
