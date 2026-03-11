///|
/// Convert bytes to lowercase hex bytes.
pub fn hex_encode(input : BytesView) -> Bytes {
  @proto.utf8_encode(@xcrypto.bytes_to_hex_string(input))
}

///|
/// Compute SHA-256 digest bytes.
pub fn sha256_bytes(data : BytesView) -> Bytes {
  Bytes::from_iter(@xcrypto.sha256(data).iter())
}

///|
/// Compute HMAC-SHA256 digest bytes.
pub fn hmac_sha256(key : BytesView, data : BytesView) -> Bytes {
  Bytes::from_iter(@xcrypto.hmac(@xcrypto.SHA256::new(), key, data).iter())
}

///|
/// Compute MD5 digest bytes.
pub fn md5_bytes(data : BytesView) -> Bytes {
  Bytes::from_iter(@xcrypto.md5(data).iter())
}

///|
/// Compute lowercase hex MD5 digest bytes.
pub fn md5_hex(data : BytesView) -> Bytes {
  @proto.utf8_encode(@xcrypto.bytes_to_hex_string(@xcrypto.md5(data)))
}
