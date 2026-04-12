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
pub suberror TlsError {
  TlsError(String)
} derive(Debug, ToJson)

///|
pub suberror ConnectionClosed derive(Debug, ToJson)

///|
pub enum ChannelBinding {
  NoBinding
  TlsServerEndPoint(Bytes)
}

///|
/// Optional TLS client-handshake settings for one outbound connection.
///
/// The default constructor keeps certificate verification enabled and uses the
/// platform trust store unless `root_cert_file` overrides it.
pub struct ClientOptions {
  verify_peer : Bool
  verify_host : String?
  use_system_trust_store : Bool
  root_cert_file : String?
} derive(Debug, Eq)

///|
/// Construct TLS client options for one outbound connection.
pub fn ClientOptions::new(
  verify_peer? : Bool = true,
  verify_host? : String? = None,
  use_system_trust_store? : Bool = true,
  root_cert_file? : String? = None,
) -> ClientOptions {
  { verify_peer, verify_host, use_system_trust_store, root_cert_file }
}

///|
/// Create a TLS client that read from write to `inner`.
/// `client` will block until TLS handshake to remote server completed.
///
/// If `verify` is `true` (`true` by default),
/// `client` will perform verification on server's certificate,
/// using the default verification setting of the OpenSSL library.
///
/// If `host` is present, it will be used to verify the peer's certificate.
///
pub async fn[Inner : @io.Reader + @io.Writer] Tls::client(
  inner : Inner,
  verify? : Bool = true,
  host? : String,
) -> Tls {
  Tls::client_with_options(
    inner,
    ClientOptions::new(
      verify_peer=verify,
      verify_host=host,
      use_system_trust_store=true,
    ),
  )
}

///|
/// Create a TLS client using explicit handshake options.
pub async fn[Inner : @io.Reader + @io.Writer] Tls::client_with_options(
  inner : Inner,
  options : ClientOptions,
) -> Tls {
  Tls::client_from_pair_with_options(inner, inner, options)
}
