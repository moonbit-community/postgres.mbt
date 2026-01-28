///|
/// Convert bytes to lowercase hex bytes.
pub fn hex_encode(input : BytesView) -> Bytes {
  let out = Array::make(input.length() * 2, b'0')
  for i, b in input.iter2() {
    let v = b.to_int()
    let hi = (v >> 4) & 0x0f
    let lo = v & 0x0f
    out[i * 2] = nibble_to_hex(hi)
    out[i * 2 + 1] = nibble_to_hex(lo)
  }
  Bytes::from_array(out[:])
}

///|
fn nibble_to_hex(n : Int) -> Byte {
  if n < 10 {
    (n + '0'.to_int()).to_byte()
  } else {
    (n - 10 + 'a'.to_int()).to_byte()
  }
}

///|
fn hex_to_nibble(b : Byte) -> Int raise @proto.ProtocolError {
  if b >= b'0' && b <= b'9' {
    return b.to_int() - '0'.to_int()
  }
  if b >= b'a' && b <= b'f' {
    return b.to_int() - 'a'.to_int() + 10
  }
  if b >= b'A' && b <= b'F' {
    return b.to_int() - 'A'.to_int() + 10
  }
  raise @proto.ProtocolError::InvalidInput("invalid hex digit")
}

///|
/// Decode a hex-encoded UTF-8 string into bytes (unchecked).
fn hex_decode_string(s : String) -> Bytes raise @proto.ProtocolError {
  let bytes = @utf8.encode(s)
  if bytes.length() % 2 != 0 {
    raise @proto.ProtocolError::InvalidInput("hex string length must be even")
  }
  let out = Array::make(bytes.length() / 2, b'0')
  let mut i = 0
  let mut o = 0
  while i < bytes.length() {
    let hi = hex_to_nibble(bytes[i])
    let lo = hex_to_nibble(bytes[i + 1])
    out[o] = ((hi << 4) | lo).to_byte()
    i = i + 2
    o = o + 1
  }
  Bytes::from_array(out[:])
}

///|
/// Compute SHA-256 digest bytes.
pub fn sha256_bytes(data : BytesView) -> Bytes {
  let digest = @sha256.Digest::new()
  for b in data {
    digest.write(b)
  }
  let hex = digest.check_sum()
  // digest.check_sum always returns valid hex.
  try! hex_decode_string(hex)
}

///|
/// Compute HMAC-SHA256 digest bytes.
pub fn hmac_sha256(key : BytesView, data : BytesView) -> Bytes {
  let block_size = 64
  let mut key_bytes = key.to_bytes()
  if key_bytes.length() > block_size {
    key_bytes = sha256_bytes(key_bytes[:])
  }
  let ipad = Array::make(block_size, b'\x00')
  let opad = Array::make(block_size, b'\x00')
  for i in 0..<block_size {
    let kb = if i < key_bytes.length() { key_bytes[i] } else { b'\x00' }
    ipad[i] = kb ^ b'\x36'
    opad[i] = kb ^ b'\x5c'
  }
  let inner = @buffer.new(size_hint=block_size + data.length())
  inner.write_iter(ipad.iter())
  inner.write_bytesview(data)
  let inner_hash = sha256_bytes(inner.to_bytes()[:])
  let outer = @buffer.new(size_hint=block_size + inner_hash.length())
  outer.write_iter(opad.iter())
  outer.write_bytesview(inner_hash[:])
  sha256_bytes(outer.to_bytes()[:])
}

///|
/// Compute MD5 digest bytes.
pub fn md5_bytes(data : BytesView) -> Bytes {
  md5_digest(data)
}

///|
/// Compute lowercase hex MD5 digest bytes.
pub fn md5_hex(data : BytesView) -> Bytes {
  hex_encode(md5_digest(data)[:])
}

///|
fn md5_digest(data : BytesView) -> Bytes {
  let mut a0 = 0x67452301U
  let mut b0 = 0xefcdab89U
  let mut c0 = 0x98badcfeU
  let mut d0 = 0x10325476U
  let bit_len = data.length().to_uint64() * 8UL
  let padded = Array::from_iter(data.iter())
  padded.push(b'\x80')
  while padded.length() % 64 != 56 {
    padded.push(b'\x00')
  }

  // append length in bits, little-endian
  for i in 0..<8 {
    padded.push(((bit_len >> (i * 8)) & 0xffUL).to_byte())
  }
  let mut idx = 0
  while idx < padded.length() {
    let chunk = padded[idx:idx + 64]
    let m = FixedArray::make(16, 0U)
    for i in 0..<16 {
      let j = i * 4
      let b0 = chunk[j].to_uint()
      let b1 = chunk[j + 1].to_uint()
      let b2 = chunk[j + 2].to_uint()
      let b3 = chunk[j + 3].to_uint()
      m[i] = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
    let mut a = a0
    let mut b = b0
    let mut c = c0
    let mut d = d0
    for i in 0..<64 {
      let (f, g) = md5_round(b, c, d, i)
      let temp = d
      d = c
      c = b
      let sum = u32_add(u32_add(a, f), u32_add(md5_k[i], m[g]))
      let rotated = rotl32(sum, md5_s[i])
      b = u32_add(b, rotated)
      a = temp
    }
    a0 = u32_add(a0, a)
    b0 = u32_add(b0, b)
    c0 = u32_add(c0, c)
    d0 = u32_add(d0, d)
    idx = idx + 64
  }
  let out = Array::make(16, b'\x00')
  write_u32_le(out, 0, a0)
  write_u32_le(out, 4, b0)
  write_u32_le(out, 8, c0)
  write_u32_le(out, 12, d0)
  Bytes::from_array(out[:])
}

///|
fn u32_add(a : UInt, b : UInt) -> UInt {
  (a + b) & 0xffff_ffffU
}

///|
fn rotl32(x : UInt, s : Int) -> UInt {
  let s = s % 32
  ((x << s) | (x >> (32 - s))) & 0xffff_ffffU
}

///|
fn md5_round(b : UInt, c : UInt, d : UInt, i : Int) -> (UInt, Int) {
  if i < 16 {
    let f = (b & c) | (b.lnot() & d)
    (f, i)
  } else if i < 32 {
    let f = (d & b) | (d.lnot() & c)
    (f, (5 * i + 1) % 16)
  } else if i < 48 {
    let f = b ^ c ^ d
    (f, (3 * i + 5) % 16)
  } else {
    let f = c ^ (b | d.lnot())
    (f, 7 * i % 16)
  }
}

///|
fn write_u32_le(buf : Array[Byte], idx : Int, value : UInt) -> Unit {
  buf[idx] = (value & 0xffU).to_byte()
  buf[idx + 1] = ((value >> 8) & 0xffU).to_byte()
  buf[idx + 2] = ((value >> 16) & 0xffU).to_byte()
  buf[idx + 3] = ((value >> 24) & 0xffU).to_byte()
}

///|
let md5_s : FixedArray[Int] = [
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9,
  14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  4, 11, 16, 23, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
]

///|
let md5_k : FixedArray[UInt] = [
  0xd76aa478U, 0xe8c7b756U, 0x242070dbU, 0xc1bdceeeU, 0xf57c0fafU, 0x4787c62aU, 0xa8304613U,
  0xfd469501U, 0x698098d8U, 0x8b44f7afU, 0xffff5bb1U, 0x895cd7beU, 0x6b901122U, 0xfd987193U,
  0xa679438eU, 0x49b40821U, 0xf61e2562U, 0xc040b340U, 0x265e5a51U, 0xe9b6c7aaU, 0xd62f105dU,
  0x02441453U, 0xd8a1e681U, 0xe7d3fbc8U, 0x21e1cde6U, 0xc33707d6U, 0xf4d50d87U, 0x455a14edU,
  0xa9e3e905U, 0xfcefa3f8U, 0x676f02d9U, 0x8d2a4c8aU, 0xfffa3942U, 0x8771f681U, 0x6d9d6122U,
  0xfde5380cU, 0xa4beea44U, 0x4bdecfa9U, 0xf6bb4b60U, 0xbebfbc70U, 0x289b7ec6U, 0xeaa127faU,
  0xd4ef3085U, 0x04881d05U, 0xd9d4d039U, 0xe6db99e5U, 0x1fa27cf8U, 0xc4ac5665U, 0xf4292244U,
  0x432aff97U, 0xab9423a7U, 0xfc93a039U, 0x655b59c3U, 0x8f0ccc92U, 0xffeff47dU, 0x85845dd1U,
  0x6fa87e4fU, 0xfe2ce6e0U, 0xa3014314U, 0x4e0811a1U, 0xf7537e82U, 0xbd3af235U, 0x2ad7d2bbU,
  0xeb86d391U,
]
