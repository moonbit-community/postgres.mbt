// Copyright 2025 International Digital Economy Academy
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

///|
#cfg(not(platform="windows"))
#external
priv type SSL_CTX

///|
#cfg(not(platform="windows"))
extern "C" fn SSL_CTX::is_null(self : SSL_CTX) -> Bool = "moonbit_postgres_client_tls_ssl_ctx_is_null"

///|
#cfg(not(platform="windows"))
extern "C" fn SSL_CTX::client() -> SSL_CTX = "moonbit_postgres_client_tls_client_ctx"

///|
#cfg(not(platform="windows"))
extern "C" fn SSL_CTX::server() -> SSL_CTX = "moonbit_postgres_client_tls_server_ctx"

///|
#cfg(not(platform="windows"))
extern "C" fn SSL_CTX::free(self : SSL_CTX) = "moonbit_postgres_client_tls_ssl_ctx_free"

///|
#cfg(not(platform="windows"))
extern "C" fn SSL_CTX::set_default_verify_paths(self : SSL_CTX) -> Int = "moonbit_postgres_client_tls_ssl_ctx_set_default_verify_paths"

///|
#cfg(not(platform="windows"))
#borrow(file)
extern "C" fn SSL_CTX::load_verify_file(self : SSL_CTX, file : Bytes) -> Int = "moonbit_postgres_client_tls_ssl_ctx_load_verify_file"

///|
#cfg(not(platform="windows"))
extern "C" fn SSL_CTX::set_min_protocol_version(
  self : SSL_CTX,
  version : Int,
) -> Int = "moonbit_postgres_client_tls_ssl_ctx_set_min_protocol_version"

///|
#cfg(not(platform="windows"))
let server_ctx : Ref[SSL_CTX?] = Ref::new(None)

///|
#cfg(not(platform="windows"))
fn get_server_ctx() -> SSL_CTX {
  match server_ctx.val {
    Some(ctx) => ctx
    None => {
      load_openssl()
      let ctx = SSL_CTX::server()
      guard !ctx.is_null() else {
        abort("failed to initialize SSL server context")
      }
      server_ctx.val = Some(ctx)
      ctx
    }
  }
}

///|
#cfg(not(platform="windows"))
#external
priv type SSL

///|
#cfg(not(platform="windows"))
extern "C" fn SSL::new(ctx : SSL_CTX, rbio : BIO, wbio : BIO) -> SSL = "moonbit_postgres_client_tls_ssl_new"

///|
#cfg(not(platform="windows"))
extern "C" fn SSL::connect(self : SSL) -> Int = "moonbit_postgres_client_tls_ssl_connect"

///|
#cfg(not(platform="windows"))
#borrow(host)
extern "C" fn SSL::set_host(self : SSL, host : Bytes) -> Int = "moonbit_postgres_client_tls_ssl_set_host"

///|
#cfg(not(platform="windows"))
#borrow(host)
extern "C" fn SSL::set_ip(self : SSL, host : Bytes) -> Int = "moonbit_postgres_client_tls_ssl_set_ip"

///|
#cfg(not(platform="windows"))
#borrow(host)
extern "C" fn SSL::set_sni(self : SSL, host : Bytes) -> Int = "moonbit_postgres_client_tls_ssl_set_sni"

///|
#cfg(not(platform="windows"))
extern "C" fn SSL::set_verify(self : SSL, verify : Bool) = "moonbit_postgres_client_tls_ssl_set_verify"

///|
#cfg(not(platform="windows"))
extern "C" fn SSL::accept(self : SSL) -> Int = "moonbit_postgres_client_tls_ssl_accept"

///|
pub(all) enum X509FileType {
  PEM = 1
  ANS1 = 2
}

///|
#cfg(not(platform="windows"))
#borrow(file)
extern "C" fn SSL::use_certificate_file(
  self : SSL,
  file : Bytes,
  file_type : X509FileType,
) -> Int = "moonbit_postgres_client_tls_ssl_use_certificate_file"

///|
#cfg(not(platform="windows"))
#borrow(file)
extern "C" fn SSL::use_private_key_file(
  self : SSL,
  file : Bytes,
  file_type : X509FileType,
) -> Int = "moonbit_postgres_client_tls_ssl_use_private_key_file"

///|
#cfg(not(platform="windows"))
#borrow(buf)
extern "C" fn SSL::read(
  self : SSL,
  buf : FixedArray[Byte],
  offset : Int,
  len : Int,
) -> Int = "moonbit_postgres_client_tls_ssl_read"

///|
#cfg(not(platform="windows"))
#borrow(buf)
extern "C" fn SSL::write(
  self : SSL,
  buf : Bytes,
  offset : Int,
  len : Int,
) -> Int = "moonbit_postgres_client_tls_ssl_write"

///|
#cfg(not(platform="windows"))
extern "C" fn SSL::shutdown(self : SSL) -> Int = "moonbit_postgres_client_tls_ssl_shutdown"

///|
#cfg(not(platform="windows"))
extern "C" fn SSL::free(self : SSL) = "moonbit_postgres_client_tls_ssl_free"

///|
#cfg(not(platform="windows"))
extern "C" fn SSL::get_error(self : SSL, ret : Int) -> Int = "moonbit_postgres_client_tls_ssl_get_error"

///|
#cfg(not(platform="windows"))
#borrow(out)
extern "C" fn SSL::tls_server_end_point(
  self : SSL,
  out : FixedArray[Byte],
) -> Int = "moonbit_postgres_client_tls_ssl_tls_server_end_point"

///|
#cfg(not(platform="windows"))
const SSL_ERROR_SSL = 1

///|
#cfg(not(platform="windows"))
const SSL_ERROR_WANT_READ = 2

///|
#cfg(not(platform="windows"))
const SSL_ERROR_WANT_WRITE = 3

///|
#cfg(not(platform="windows"))
const SSL_ERROR_SYSCALL = 5

///|
#cfg(not(platform="windows"))
const SSL_ERROR_ZERO_RETURN = 6

///|
#cfg(not(platform="windows"))
#borrow(buf)
extern "C" fn err_get_error_ffi(buf : Bytes) -> Int = "moonbit_postgres_client_tls_get_error"

///|
#cfg(not(platform="windows"))
fn err_get_error() -> String {
  let buf = Bytes::make(256, 0)
  let len = err_get_error_ffi(buf)
  @bytes_util.ascii_to_string(buf[:len])
}

///|
#cfg(not(platform="windows"))
#external
priv type BIO

///|
#cfg(not(platform="windows"))
extern "C" fn BIO::get_endpoint(bio : BIO) -> Transport = "moonbit_postgres_client_tls_bio_get_endpoint"

///|
#cfg(not(platform="windows"))
extern "C" fn BIO::set_flags(bio : BIO, flags : Int) = "moonbit_postgres_client_tls_bio_set_flags"

///|
#cfg(not(platform="windows"))
#owned(data)
extern "C" fn create_bio(data : Transport) -> BIO = "moonbit_postgres_client_tls_create_bio"

///|
#cfg(not(platform="windows"))
const BIO_FLAGS_READ = 0x01

///|
#cfg(not(platform="windows"))
const BIO_FLAGS_WRITE = 0x02

///|
#cfg(not(platform="windows"))
const BIO_FLAGS_SHOULD_RETRY = 0x08

///|
#cfg(not(platform="windows"))
fn BIO::read(bio : BIO, dst : @c_buffer.Buffer, len : Int) -> Int {
  let ep = bio.get_endpoint()
  match ep.state {
    Normal => ()
    Closed => return 0
    Error(_) => return -1
  }
  let read_buf = ep.reader._get_internal_buffer().repr()
  guard read_buf.len > 0 else {
    bio.set_flags(BIO_FLAGS_READ | BIO_FLAGS_SHOULD_RETRY)
    -1
  }
  let len = @cmp.minimum(read_buf.len, len)
  dst.blit_from_bytes(
    src=read_buf.buf.unsafe_reinterpret_as_bytes(),
    offset=read_buf.start,
    len~,
  )
  read_buf.drop(len)
  len
}

///|
#cfg(not(platform="windows"))
fn BIO::write(bio : BIO, src : @c_buffer.Buffer, len : Int) -> Int {
  let ep = bio.get_endpoint()
  guard ep.state is Normal else { -1 }
  let end = ep.write_buf.start + ep.write_buf.len
  let remaining = ep.write_buf.buf.length() - end
  guard remaining > 0 else {
    bio.set_flags(BIO_FLAGS_WRITE | BIO_FLAGS_SHOULD_RETRY)
    -1
  }
  let len = @cmp.minimum(len, remaining)
  src.blit_to_bytes(dst=ep.write_buf.buf, offset=end, len~)
  ep.write_buf.len += len
  len
}

///|
/// A TLS-encrypted connection
#cfg(not(platform="windows"))
struct Tls {
  ssl : SSL
  ctx : SSL_CTX?
  host : String?
  transport : Transport
  read_buf : @io.ReaderBuffer
  mut shutdown : Bool
  mut closed : Bool
}

///|
#cfg(not(platform="windows"))
const TLS_PROTOCOL_VERSION_1_2 = 0x0303

///|
#cfg(not(platform="windows"))
fn String::looks_like_ip_address(self : String) -> Bool {
  if self.contains(":") {
    true
  } else if self.contains(".") {
    for ch in self {
      if !(('0' <= ch && ch <= '9') || ch == '.') {
        return false
      }
    }
    true
  } else {
    false
  }
}

///|
#cfg(not(platform="windows"))
fn configure_client_ctx(options : ClientOptions) -> SSL_CTX raise {
  load_openssl()
  let ctx = SSL_CTX::client()
  guard !ctx.is_null() else {
    raise TlsError("failed to initialize SSL client context")
  }
  try {
    if options.use_system_trust_store {
      guard ctx.set_default_verify_paths() == 1 else {
        raise TlsError(err_get_error())
      }
    }
    match options.root_cert_file {
      Some(file) => {
        let file = @utf8.encode(file)
        guard ctx.load_verify_file(file) == 1 else {
          raise TlsError(err_get_error())
        }
      }
      None => ()
    }
    guard ctx.set_min_protocol_version(TLS_PROTOCOL_VERSION_1_2) == 1 else {
      raise TlsError(err_get_error())
    }
  } catch {
    err => {
      ctx.free()
      raise err
    }
  } noraise {
    _ => ctx
  }
}

///|
#cfg(not(platform="windows"))
fn[R : @io.Reader, W : @io.Writer] Tls::from_pair(
  ctx : SSL_CTX,
  r : R,
  w : W,
  owned_ctx : SSL_CTX?,
  host~ : String?,
) -> Tls {
  let transport = Transport::new(r, w)
  let rbio = create_bio(transport)
  let wbio = create_bio(transport)
  let ssl = SSL::new(ctx, rbio, wbio)
  {
    ssl,
    ctx: owned_ctx,
    host,
    transport,
    read_buf: @io.ReaderBuffer::new(),
    shutdown: false,
    closed: false,
  }
}

///|
#cfg(not(platform="windows"))
async fn Tls::handle_error(self : Tls, err : Int) -> Unit {
  match err {
    SSL_ERROR_WANT_READ => {
      self.transport.flush_write()
      self.transport.read_more()
    }
    SSL_ERROR_WANT_WRITE => {
      self.transport.flush_write()
      self.transport.write_buf.enlarge_to(1)
    }
    SSL_ERROR_SSL | SSL_ERROR_SYSCALL => raise TlsError(err_get_error())
    SSL_ERROR_ZERO_RETURN => raise ConnectionClosed
    err => abort("unexpected error code \{err} from OpenSSL")
  }
}

///|
/// Create a TLS client that read from `r` and write to `w`.
/// `client_from_pair` will block until TLS handshake to remote server completed.
///
/// If `verify` is `true` (`true` by default),
/// `client_from_pair` will perform verification on server's certificate,
/// using the default verification setting of the OpenSSL library.
///
/// If `host` is present, it will be used to verify the peer's certificate.
///
#cfg(not(platform="windows"))
pub async fn[R : @io.Reader, W : @io.Writer] Tls::client_from_pair(
  r : R,
  w : W,
  verify? : Bool = true,
  host? : String,
) -> Tls {
  Tls::client_from_pair_with_options(
    r,
    w,
    ClientOptions::new(
      verify_peer=verify,
      verify_host=host,
      use_system_trust_store=true,
    ),
  )
}

///|
#cfg(not(platform="windows"))
pub async fn[R : @io.Reader, W : @io.Writer] Tls::client_from_pair_with_options(
  r : R,
  w : W,
  options : ClientOptions,
) -> Tls {
  init_openssl()
  let ctx = configure_client_ctx(options)
  let self = Tls::from_pair(ctx, r, w, Some(ctx), host=options.verify_host)
  try {
    if !options.verify_peer {
      self.ssl.set_verify(false)
    }
    match options.verify_host {
      Some(host) => {
        let encoded_host = @utf8.encode(host)
        let ok = if host.looks_like_ip_address() {
          self.ssl.set_ip(encoded_host)
        } else {
          self.ssl.set_host(encoded_host)
        }
        guard ok > 0 else { raise TlsError(err_get_error()) }
      }
      None => ()
    }
    match options.verify_host {
      Some(host) =>
        if !host.looks_like_ip_address() {
          let host = @utf8.encode(host)
          guard self.ssl.set_sni(host) > 0 else {
            raise TlsError(err_get_error())
          }
        }
      None => ()
    }
    while self.ssl.connect() is ret && ret <= 0 {
      self.handle_error(self.ssl.get_error(ret))
    }
    self.transport.flush_write()
  } catch {
    err => {
      self.close()
      raise err
    }
  } noraise {
    _ => self
  }
}

///|
/// WARNING: this API is currently for testing only,
/// it may block the whole thread while reading certificate,
/// and may break any time in the future. DO NOT USE.
///
/// Create a TLS server connection that read from `r` and write to `w`.
/// `server_from_pair` will block until TLS handshake with client completed.
///
/// `private_key_file`, `private_key_type` specifies the private key of the server.
/// `certificate_file` and `certificate_type` specifies the certificate of the server.
#cfg(not(platform="windows"))
#internal(internal, "do not use, for internal testing only")
pub async fn[R : @io.Reader, W : @io.Writer] Tls::server_from_pair(
  r : R,
  w : W,
  private_key_file~ : String,
  private_key_type~ : X509FileType,
  certificate_file~ : String,
  certificate_type~ : X509FileType,
) -> Tls {
  init_openssl()
  let private_key_file = @utf8.encode(private_key_file)
  let certificate_file = @utf8.encode(certificate_file)
  let self = Tls::from_pair(get_server_ctx(), r, w, None, host=None)
  try {
    if self.ssl.use_certificate_file(certificate_file, certificate_type) != 1 {
      raise TlsError(err_get_error())
    }
    if self.ssl.use_private_key_file(private_key_file, private_key_type) != 1 {
      raise TlsError(err_get_error())
    }
    while self.ssl.accept() is ret && ret <= 0 {
      self.handle_error(self.ssl.get_error(ret))
    }
    self.transport.flush_write()
  } catch {
    err => {
      self.close()
      raise err
    }
  } noraise {
    _ => self
  }
}

///|
/// WARNING: this API is currently for testing only,
/// it may block the whole thread while reading certificate,
/// and may break any time in the future. DO NOT USE.
///
/// Create a TLS server connection that read from and write to `inner`.
/// `server` will block until TLS handshake with client completed.
///
/// `private_key_file`, `private_key_type` specifies the private key of the server.
/// `certificate_file` and `certificate_type` specifies the certificate of the server.
#cfg(not(platform="windows"))
#internal(internal, "do not use, for internal testing only")
pub async fn[Inner : @io.Reader + @io.Writer] Tls::server(
  inner : Inner,
  private_key_file~ : String,
  private_key_type~ : X509FileType,
  certificate_file~ : String,
  certificate_type~ : X509FileType,
) -> Tls {
  Tls::server_from_pair(
    inner,
    inner,
    private_key_file~,
    private_key_type~,
    certificate_file~,
    certificate_type~,
  )
}

///|
#cfg(not(platform="windows"))
pub impl @io.Reader for Tls with _direct_read(self, buf, offset~, max_len~) {
  let n = while self.ssl.read(buf, offset, max_len) is ret {
    if ret > 0 {
      break ret
    }
    let err = self.ssl.get_error(ret)
    if err is SSL_ERROR_ZERO_RETURN {
      // the peer initiates closure
      self.shutdown()
      break 0
    }
    if self.transport.state is Closed &&
      self.transport.reader._get_internal_buffer().repr().len is 0 {
      // Not all TLS client/servers close the connection properly.
      // Some peers just close the underlying TCP connection
      // without performing a TLS closure.
      // So we treat this case as normal here.
      break 0
    }
    self.handle_error(err)
  } nobreak {
    0
  }
  // imposible
  self.transport.flush_write()
  n
}

///|
#cfg(not(platform="windows"))
pub impl @io.Reader for Tls with _get_internal_buffer(self) {
  self.read_buf
}

///|
#cfg(not(platform="windows"))
pub impl @io.Writer for Tls with write_once(self, buf, offset~, len~) {
  let n = while self.ssl.write(buf, offset, len) is ret {
    if ret > 0 {
      break ret
    }
    self.handle_error(self.ssl.get_error(ret))
  } nobreak {
    0
  }
  // imposible
  self.transport.flush_write()
  n
}

///|
#cfg(not(platform="windows"))
pub fn Tls::channel_binding(self : Tls) -> ChannelBinding raise {
  let digest = FixedArray::make(64, b'\x00')
  let len = self.ssl.tls_server_end_point(digest)
  if len < 0 {
    raise TlsError(err_get_error())
  }
  if len == 0 {
    NoBinding
  } else {
    TlsServerEndPoint(digest.unsafe_reinterpret_as_bytes()[:len].to_owned())
  }
}

///|
/// Close a TLS connection and release related resource.
/// THIS FUNCTION MUST BE CALLED BEFORE CLOSING UNDERLYING TRANSPORT!!!
///
/// Note that this function will not perform the TLS shutdown process,
/// for graceful shutdown of a TLS connection, see `TLS::shutdown`.
#cfg(not(platform="windows"))
pub fn Tls::close(self : Tls) -> Unit {
  guard !self.closed else {  }
  self.closed = true
  if self.transport.state is Normal {
    self.transport.state = Closed
  }
  self.ssl.free()
  match self.ctx {
    Some(ctx) => ctx.free()
    None => ()
  }
  // We must make sure the host string lives longer than `self.ssl`
  ignore(self.host)
}

///|
/// Shutdown a TLS connection gracefully.
/// This function MUST be called before `close`,
/// and MUST NOT be called if the TLS connection fail with other error.
///
/// `shutdown` is used to initiate the closure of a TLS connection.
/// So there is no need to call `shutdown` if you receive EOF from the peer.
///
/// When calling `shutdown`,
/// there may still be pending data sent by the peer on the wire.
/// So to close a TLS connection cleanly,
/// make sure you read from the connection until EOF after calling `shutdown`.
///
/// Note that the main purpose of TLS shutdown is to ensure integrity
/// before closing the underlying transport.
/// So if your application protocol has its own way of ensuring integrity
/// (e.g. `Content-Length` in HTTP/1.1),
/// it is not necessary to call `shutdown`.
#cfg(not(platform="windows"))
pub async fn Tls::shutdown(self : Tls) -> Unit {
  guard !self.shutdown else {  }
  self.shutdown = true
  match self.transport.state {
    Normal => ()
    Closed => raise ConnectionClosed
    Error(err) => raise err
  }
  while self.ssl.shutdown() is ret && ret < 0 {
    let err = self.ssl.get_error(ret)
    self.handle_error(err)
  } nobreak {
    self.transport.flush_write()
  }
}

///|
// mute unused warning
#cfg(not(platform="windows"))
let _unused : Unit = {
  ignore(@os_error.check_errno)
  ignore(@os_string.encode)
}
