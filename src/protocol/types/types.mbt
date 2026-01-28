///|
let range_upper_unbounded : Byte = 0b0001_0000

///|
let range_lower_unbounded : Byte = 0b0000_1000

///|
let range_upper_inclusive : Byte = 0b0000_0100

///|
let range_lower_inclusive : Byte = 0b0000_0010

///|
let range_empty : Byte = 0b0000_0001

///|
let pgsql_af_inet : Byte = 2

///|
let pgsql_af_inet6 : Byte = 3

///|
/// Serialize a BOOL value.
pub fn bool_to_sql(v : Bool, buf : @buffer.Buffer) -> Unit {
  buf.write_byte(if v { 1 } else { 0 })
}

///|
/// Deserialize a BOOL value.
pub fn bool_from_sql(buf : BytesView) -> Bool raise @proto.ProtocolError {
  if buf.length() != 1 {
    raise @proto.ProtocolError::InvalidInput("invalid buffer size")
  }
  buf[0] != 0
}

///|
/// Serialize a BYTEA value.
pub fn bytea_to_sql(v : BytesView, buf : @buffer.Buffer) -> Unit {
  buf.write_bytesview(v)
}

///|
/// Deserialize a BYTEA value.
pub fn bytea_from_sql(buf : BytesView) -> BytesView {
  buf
}

///|
/// Serialize a TEXT/VARCHAR/CHAR/NAME/CITEXT value.
pub fn text_to_sql(v : BytesView, buf : @buffer.Buffer) -> Unit {
  buf.write_bytesview(v)
}

///|
/// Deserialize a TEXT/VARCHAR/CHAR/NAME/CITEXT value.
pub fn text_from_sql(buf : BytesView) -> Bytes raise @proto.ProtocolError {
  @proto.validate_utf8(buf)
  buf.to_bytes()
}

///|
/// Serialize a "char" value.
pub fn char_to_sql(
  v : Int,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  if v < -128 || v > 127 {
    raise @proto.ProtocolError::Overflow("value out of range for i8")
  }
  let u = if v < 0 { v + 256 } else { v }
  buf.write_byte(u.to_byte())
}

///|
/// Deserialize a "char" value.
pub fn char_from_sql(buf : BytesView) -> Int raise @proto.ProtocolError {
  if buf.length() != 1 {
    raise @proto.ProtocolError::InvalidInput("invalid buffer size")
  }
  let b = buf[0].to_int()
  if b >= 128 {
    b - 256
  } else {
    b
  }
}

///|
/// Serialize an INT2 value.
pub fn int2_to_sql(
  v : Int,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_int16_be(@proto.checked_i16(v))
}

///|
/// Deserialize an INT2 value.
pub fn int2_from_sql(buf : BytesView) -> Int raise @proto.ProtocolError {
  let r = @proto.ByteReader::new(buf)
  let v = r.read_i16_be()
  if not(r.is_empty()) {
    raise @proto.ProtocolError::InvalidInput("invalid buffer size")
  }
  v
}

///|
/// Serialize an INT4 value.
pub fn int4_to_sql(
  v : Int,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_int_be(@proto.checked_i32(v))
}

///|
/// Deserialize an INT4 value.
pub fn int4_from_sql(buf : BytesView) -> Int raise @proto.ProtocolError {
  let r = @proto.ByteReader::new(buf)
  let v = r.read_i32_be()
  if not(r.is_empty()) {
    raise @proto.ProtocolError::InvalidInput("invalid buffer size")
  }
  v
}

///|
/// Serialize an OID value.
pub fn oid_to_sql(v : @proto.Oid, buf : @buffer.Buffer) -> Unit {
  buf.write_uint_be(v)
}

///|
/// Deserialize an OID value.
pub fn oid_from_sql(buf : BytesView) -> @proto.Oid raise @proto.ProtocolError {
  let r = @proto.ByteReader::new(buf)
  let v = r.read_u32_be()
  if not(r.is_empty()) {
    raise @proto.ProtocolError::InvalidInput("invalid buffer size")
  }
  v
}

///|
/// Serialize an INT8 value.
pub fn int8_to_sql(v : Int64, buf : @buffer.Buffer) -> Unit {
  buf.write_int64_be(v)
}

///|
/// Deserialize an INT8 value.
pub fn int8_from_sql(buf : BytesView) -> Int64 raise @proto.ProtocolError {
  let r = @proto.ByteReader::new(buf)
  let v = r.read_i64_be()
  if not(r.is_empty()) {
    raise @proto.ProtocolError::InvalidInput("invalid buffer size")
  }
  v
}

///|
/// Serialize a PG_LSN value.
pub fn lsn_to_sql(v : @proto.Lsn, buf : @buffer.Buffer) -> Unit {
  buf.write_uint64_be(v)
}

///|
/// Deserialize a PG_LSN value.
pub fn lsn_from_sql(buf : BytesView) -> @proto.Lsn raise @proto.ProtocolError {
  let r = @proto.ByteReader::new(buf)
  let v = r.read_u64_be()
  if not(r.is_empty()) {
    raise @proto.ProtocolError::InvalidInput("invalid buffer size")
  }
  v
}

///|
/// Serialize a FLOAT4 value.
pub fn float4_to_sql(v : Float, buf : @buffer.Buffer) -> Unit {
  buf.write_float_be(v)
}

///|
/// Deserialize a FLOAT4 value.
pub fn float4_from_sql(buf : BytesView) -> Float raise @proto.ProtocolError {
  let r = @proto.ByteReader::new(buf)
  let v = r.read_f32_be()
  if not(r.is_empty()) {
    raise @proto.ProtocolError::InvalidInput("invalid buffer size")
  }
  v
}

///|
/// Serialize a FLOAT8 value.
pub fn float8_to_sql(v : Double, buf : @buffer.Buffer) -> Unit {
  buf.write_double_be(v)
}

///|
/// Deserialize a FLOAT8 value.
pub fn float8_from_sql(buf : BytesView) -> Double raise @proto.ProtocolError {
  let r = @proto.ByteReader::new(buf)
  let v = r.read_f64_be()
  if not(r.is_empty()) {
    raise @proto.ProtocolError::InvalidInput("invalid buffer size")
  }
  v
}

///|
/// Serialize an HSTORE value.
pub fn hstore_to_sql(
  values : Iter[(BytesView, BytesView?)],
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  let payload = @buffer.new()
  let mut count = 0
  for entry in values {
    let (key, value) = entry
    count = count + 1
    write_pascal_string(key, payload)
    match value {
      Some(v) => write_pascal_string(v, payload)
      None => payload.write_int_be(-1)
    }
  }
  let count_i32 = @proto.i32_from_usize(count)
  buf.write_int_be(count_i32)
  buf.write_bytes(payload.to_bytes())
}

///|
fn write_pascal_string(
  s : BytesView,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  let size = @proto.i32_from_usize(s.length())
  buf.write_int_be(size)
  buf.write_bytesview(s)
}

///|
/// Deserialize an HSTORE value.
pub fn hstore_from_sql(
  buf : BytesView,
) -> HstoreEntries raise @proto.ProtocolError {
  let r = @proto.ByteReader::new(buf)
  let count = r.read_i32_be()
  if count < 0 {
    raise @proto.ProtocolError::InvalidInput("invalid entry count")
  }
  { remaining: count, buf: buf[4:] }
}

///|
/// Iterator over HSTORE entries.
pub struct HstoreEntries {
  mut remaining : Int
  mut buf : BytesView
}

///|
pub fn HstoreEntries::next(
  self : HstoreEntries,
) -> (Bytes, Bytes?)? raise @proto.ProtocolError {
  if self.remaining == 0 {
    if self.buf.length() != 0 {
      raise @proto.ProtocolError::InvalidInput("invalid buffer size")
    }
    return None
  }
  self.remaining = self.remaining - 1
  let r = @proto.ByteReader::new(self.buf)
  let key_len = r.read_i32_be()
  if key_len < 0 {
    raise @proto.ProtocolError::InvalidInput("invalid key length")
  }
  if self.buf.length() < 4 + key_len {
    raise @proto.ProtocolError::UnexpectedEof("unexpected EOF")
  }
  let key = self.buf[4:4 + key_len]
  self.buf = self.buf[4 + key_len:]
  let r2 = @proto.ByteReader::new(self.buf)
  let value_len = r2.read_i32_be()
  if value_len < 0 {
    self.buf = self.buf[4:]
    return Some((key.to_bytes(), None))
  }
  if self.buf.length() < 4 + value_len {
    raise @proto.ProtocolError::UnexpectedEof("unexpected EOF")
  }
  let value = self.buf[4:4 + value_len]
  self.buf = self.buf[4 + value_len:]
  Some((key.to_bytes(), Some(value.to_bytes())))
}

///|
/// Serialize a VARBIT or BIT value.
pub fn varbit_to_sql(
  len : Int,
  v : Iter[Byte],
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  let len_i32 = @proto.i32_from_usize(len)
  buf.write_int_be(len_i32)
  for byte in v {
    buf.write_byte(byte)
  }
}

///|
/// Deserialize a VARBIT or BIT value.
pub fn varbit_from_sql(buf : BytesView) -> Varbit raise @proto.ProtocolError {
  let r = @proto.ByteReader::new(buf)
  let len = r.read_i32_be()
  if len < 0 {
    raise @proto.ProtocolError::InvalidInput(
      "invalid varbit length: varbit < 0",
    )
  }
  let bytes_len = (len + 7) / 8
  if buf.length() != 4 + bytes_len {
    raise @proto.ProtocolError::InvalidInput(
      "invalid message length: varbit mismatch",
    )
  }
  { len, bytes: buf[4:] }
}

///|
/// A VARBIT value.
pub struct Varbit {
  len : Int
  bytes : BytesView
}

///|
pub fn Varbit::len(self : Varbit) -> Int {
  self.len
}

///|
pub fn Varbit::is_empty(self : Varbit) -> Bool {
  self.len == 0
}

///|
pub fn Varbit::bytes(self : Varbit) -> BytesView {
  self.bytes
}

///|
/// Serialize a TIMESTAMP/TIMESTAMPTZ value (microseconds since 2000-01-01).
pub fn timestamp_to_sql(v : Int64, buf : @buffer.Buffer) -> Unit {
  buf.write_int64_be(v)
}

///|
/// Deserialize a TIMESTAMP/TIMESTAMPTZ value.
pub fn timestamp_from_sql(buf : BytesView) -> Int64 raise @proto.ProtocolError {
  let r = @proto.ByteReader::new(buf)
  let v = r.read_i64_be()
  if not(r.is_empty()) {
    raise @proto.ProtocolError::InvalidInput(
      "invalid message length: timestamp not drained",
    )
  }
  v
}

///|
/// Serialize a DATE value (days since 2000-01-01).
pub fn date_to_sql(
  v : Int,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_int_be(@proto.checked_i32(v))
}

///|
/// Deserialize a DATE value.
pub fn date_from_sql(buf : BytesView) -> Int raise @proto.ProtocolError {
  let r = @proto.ByteReader::new(buf)
  let v = r.read_i32_be()
  if not(r.is_empty()) {
    raise @proto.ProtocolError::InvalidInput(
      "invalid message length: date not drained",
    )
  }
  v
}

///|
/// Serialize a TIME/TIMETZ value (microseconds since midnight).
pub fn time_to_sql(v : Int64, buf : @buffer.Buffer) -> Unit {
  buf.write_int64_be(v)
}

///|
/// Deserialize a TIME/TIMETZ value.
pub fn time_from_sql(buf : BytesView) -> Int64 raise @proto.ProtocolError {
  let r = @proto.ByteReader::new(buf)
  let v = r.read_i64_be()
  if not(r.is_empty()) {
    raise @proto.ProtocolError::InvalidInput(
      "invalid message length: time not drained",
    )
  }
  v
}

///|
/// Serialize a MACADDR value.
pub fn macaddr_to_sql(
  v : BytesView,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  if v.length() != 6 {
    raise @proto.ProtocolError::InvalidInput("invalid MAC address length")
  }
  buf.write_bytesview(v)
}

///|
/// Deserialize a MACADDR value.
pub fn macaddr_from_sql(buf : BytesView) -> Bytes raise @proto.ProtocolError {
  if buf.length() != 6 {
    raise @proto.ProtocolError::InvalidInput(
      "invalid message length: macaddr length mismatch",
    )
  }
  buf.to_bytes()
}

///|
/// Serialize a UUID value.
pub fn uuid_to_sql(
  v : BytesView,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  if v.length() != 16 {
    raise @proto.ProtocolError::InvalidInput("invalid UUID length")
  }
  buf.write_bytesview(v)
}

///|
/// Deserialize a UUID value.
pub fn uuid_from_sql(buf : BytesView) -> Bytes raise @proto.ProtocolError {
  if buf.length() != 16 {
    raise @proto.ProtocolError::InvalidInput(
      "invalid message length: uuid size mismatch",
    )
  }
  buf.to_bytes()
}

///|
/// Serialize an array value.
pub fn[T] array_to_sql(
  dimensions : Iter[ArrayDimension],
  element_type : @proto.Oid,
  elements : Iter[T],
  serializer : (T, @buffer.Buffer) -> @proto.IsNull raise @proto.ProtocolError,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  let payload = @buffer.new()
  let mut num_dimensions = 0
  for dimension in dimensions {
    num_dimensions = num_dimensions + 1
    payload.write_int_be(@proto.checked_i32(dimension.len))
    payload.write_int_be(@proto.checked_i32(dimension.lower_bound))
  }
  let mut has_nulls = false
  for element in elements {
    @proto.write_nullable(
      fn(b) {
        let r = serializer(element, b)
        match r {
          @proto.IsNull::Yes => has_nulls = true
          @proto.IsNull::No => ()
        }
        r
      },
      payload,
    )
  }
  let num_dimensions_i32 = @proto.i32_from_usize(num_dimensions)
  buf.write_int_be(num_dimensions_i32)
  buf.write_int_be(if has_nulls { 1 } else { 0 })
  buf.write_uint_be(element_type)
  buf.write_bytes(payload.to_bytes())
}

///|
/// Deserialize an array value.
pub fn array_from_sql(buf : BytesView) -> PgArray raise @proto.ProtocolError {
  let r = @proto.ByteReader::new(buf)
  let dimensions = r.read_i32_be()
  if dimensions < 0 {
    raise @proto.ProtocolError::InvalidInput("invalid dimension count")
  }
  let has_nulls = r.read_i32_be() != 0
  let element_type = r.read_u32_be()
  let mut elements = 1
  for _ in 0..<dimensions {
    let len = r.read_i32_be()
    let _lower = r.read_i32_be()
    if len < 0 {
      raise @proto.ProtocolError::InvalidInput("invalid dimension size")
    }
    elements = elements * len
  }
  if dimensions == 0 {
    elements = 0
  }
  { dimensions, has_nulls, element_type, elements, buf: buf.to_bytes() }
}

///|
/// A Postgres array.
pub struct PgArray {
  dimensions : Int
  has_nulls : Bool
  element_type : @proto.Oid
  elements : Int
  buf : Bytes
}

///|
pub fn PgArray::has_nulls(self : PgArray) -> Bool {
  self.has_nulls
}

///|
pub fn PgArray::element_type(self : PgArray) -> @proto.Oid {
  self.element_type
}

///|
pub fn PgArray::dimensions(self : PgArray) -> ArrayDimensions {
  let start = 12
  let end = start + self.dimensions * 8
  { buf: self.buf[start:end] }
}

///|
pub fn PgArray::values(self : PgArray) -> ArrayValues {
  let start = 12 + self.dimensions * 8
  { remaining: self.elements, buf: self.buf[start:] }
}

///|
/// Iterator over array dimensions.
pub struct ArrayDimensions {
  mut buf : BytesView
}

///|
pub fn ArrayDimensions::next(
  self : ArrayDimensions,
) -> ArrayDimension? raise @proto.ProtocolError {
  if self.buf.length() == 0 {
    return None
  }
  let r = @proto.ByteReader::new(self.buf)
  let len = r.read_i32_be()
  let lower_bound = r.read_i32_be()
  self.buf = self.buf[8:]
  Some({ len, lower_bound })
}

///|
/// Dimension info.
pub struct ArrayDimension {
  len : Int
  lower_bound : Int
} derive(Show, Eq)

///|
pub fn ArrayDimension::new(len : Int, lower_bound : Int) -> ArrayDimension {
  { len, lower_bound }
}

///|
pub fn ArrayDimension::len(self : ArrayDimension) -> Int {
  self.len
}

///|
pub fn ArrayDimension::lower_bound(self : ArrayDimension) -> Int {
  self.lower_bound
}

///|
/// Iterator over array values.
pub struct ArrayValues {
  mut remaining : Int
  mut buf : BytesView
}

///|
pub fn ArrayValues::next(
  self : ArrayValues,
) -> Bytes?? raise @proto.ProtocolError {
  if self.remaining == 0 {
    if self.buf.length() != 0 {
      raise @proto.ProtocolError::InvalidInput(
        "invalid message length: arrayvalue not drained",
      )
    }
    return None
  }
  self.remaining = self.remaining - 1
  let r = @proto.ByteReader::new(self.buf)
  let len = r.read_i32_be()
  if len < 0 {
    self.buf = self.buf[4:]
    return Some(None)
  }
  if self.buf.length() < 4 + len {
    raise @proto.ProtocolError::InvalidInput("invalid value length")
  }
  let val = self.buf[4:4 + len]
  self.buf = self.buf[4 + len:]
  Some(Some(val.to_bytes()))
}

///|
/// Serialize an empty range.
pub fn empty_range_to_sql(buf : @buffer.Buffer) -> Unit {
  buf.write_byte(range_empty)
}

///|
/// One side of a range.
pub enum RangeBound[T] {
  Inclusive(T)
  Exclusive(T)
  Unbounded
}

///|
/// Serialize a range value.
pub fn range_to_sql(
  lower : (@buffer.Buffer) -> RangeBound[@proto.IsNull] raise @proto.ProtocolError,
  upper : (@buffer.Buffer) -> RangeBound[@proto.IsNull] raise @proto.ProtocolError,
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  let payload = @buffer.new()
  let mut tag : Byte = 0
  match write_bound(lower, payload) {
    RangeBound::Inclusive(_) => tag = tag | range_lower_inclusive
    RangeBound::Exclusive(_) => ()
    RangeBound::Unbounded => tag = tag | range_lower_unbounded
  }
  match write_bound(upper, payload) {
    RangeBound::Inclusive(_) => tag = tag | range_upper_inclusive
    RangeBound::Exclusive(_) => ()
    RangeBound::Unbounded => tag = tag | range_upper_unbounded
  }
  buf.write_byte(tag)
  buf.write_bytes(payload.to_bytes())
}

///|
fn write_bound(
  bound : (@buffer.Buffer) -> RangeBound[@proto.IsNull] raise @proto.ProtocolError,
  buf : @buffer.Buffer,
) -> RangeBound[Unit] raise @proto.ProtocolError {
  let payload = @buffer.new()
  let (null, ret) = match bound(payload) {
    RangeBound::Inclusive(null) => (Some(null), RangeBound::Inclusive(()))
    RangeBound::Exclusive(null) => (Some(null), RangeBound::Exclusive(()))
    RangeBound::Unbounded => (None, RangeBound::Unbounded)
  }
  match null {
    Some(n) => {
      let len = match n {
        @proto.IsNull::No => @proto.i32_from_usize(payload.length())
        @proto.IsNull::Yes => -1
      }
      buf.write_int_be(len)
      if n is @proto.IsNull::No {
        buf.write_bytes(payload.to_bytes())
      }
    }
    None => ()
  }
  ret
}

///|
/// Deserialize a range value.
pub fn range_from_sql(buf : BytesView) -> Range raise @proto.ProtocolError {
  let r = @proto.ByteReader::new(buf)
  let tag = r.read_u8()
  if tag == range_empty {
    if not(r.is_empty()) {
      raise @proto.ProtocolError::InvalidInput("invalid message size")
    }
    return Range::Empty
  }
  let rest0 = buf[1:]
  let (lower, rest1) = read_bound(
    rest0, tag, range_lower_unbounded, range_lower_inclusive,
  )
  let (upper, rest2) = read_bound(
    rest1, tag, range_upper_unbounded, range_upper_inclusive,
  )
  if rest2.length() != 0 {
    raise @proto.ProtocolError::InvalidInput("invalid message size")
  }
  Range::Nonempty(lower, upper)
}

///|
fn read_bound(
  buf : BytesView,
  tag : Byte,
  unbounded : Byte,
  inclusive : Byte,
) -> (RangeBound[Bytes?], BytesView) raise @proto.ProtocolError {
  if (tag & unbounded) != 0 {
    return (RangeBound::Unbounded, buf)
  }
  let r = @proto.ByteReader::new(buf)
  let len = r.read_i32_be()
  if len < 0 {
    let rest = buf[4:]
    if (tag & inclusive) != 0 {
      return (RangeBound::Inclusive(None), rest)
    }
    return (RangeBound::Exclusive(None), rest)
  }
  if buf.length() < 4 + len {
    raise @proto.ProtocolError::InvalidInput("invalid message size")
  }
  let value = buf[4:4 + len].to_bytes()
  let rest = buf[4 + len:]
  if (tag & inclusive) != 0 {
    (RangeBound::Inclusive(Some(value)), rest)
  } else {
    (RangeBound::Exclusive(Some(value)), rest)
  }
}

///|
/// A Postgres range.
pub enum Range {
  Empty
  Nonempty(RangeBound[Bytes?], RangeBound[Bytes?])
}

///|
/// Serialize a point value.
pub fn point_to_sql(x : Double, y : Double, buf : @buffer.Buffer) -> Unit {
  buf.write_double_be(x)
  buf.write_double_be(y)
}

///|
/// Deserialize a point value.
pub fn point_from_sql(buf : BytesView) -> Point raise @proto.ProtocolError {
  let r = @proto.ByteReader::new(buf)
  let x = r.read_f64_be()
  let y = r.read_f64_be()
  if not(r.is_empty()) {
    raise @proto.ProtocolError::InvalidInput("invalid buffer size")
  }
  { x, y }
}

///|
pub struct Point {
  x : Double
  y : Double
} derive(Show, Eq)

///|
pub fn Point::x(self : Point) -> Double {
  self.x
}

///|
pub fn Point::y(self : Point) -> Double {
  self.y
}

///|
/// Serialize a box value.
pub fn box_to_sql(
  x1 : Double,
  y1 : Double,
  x2 : Double,
  y2 : Double,
  buf : @buffer.Buffer,
) -> Unit {
  buf.write_double_be(x1)
  buf.write_double_be(y1)
  buf.write_double_be(x2)
  buf.write_double_be(y2)
}

///|
/// Deserialize a box value.
pub fn box_from_sql(buf : BytesView) -> Box raise @proto.ProtocolError {
  let r = @proto.ByteReader::new(buf)
  let x1 = r.read_f64_be()
  let y1 = r.read_f64_be()
  let x2 = r.read_f64_be()
  let y2 = r.read_f64_be()
  if not(r.is_empty()) {
    raise @proto.ProtocolError::InvalidInput("invalid buffer size")
  }
  { upper_right: { x: x1, y: y1 }, lower_left: { x: x2, y: y2 } }
}

///|
pub struct Box {
  upper_right : Point
  lower_left : Point
} derive(Show, Eq)

///|
pub fn Box::upper_right(self : Box) -> Point {
  self.upper_right
}

///|
pub fn Box::lower_left(self : Box) -> Point {
  self.lower_left
}

///|
/// Serialize a path value.
pub fn path_to_sql(
  closed : Bool,
  points : Iter[(Double, Double)],
  buf : @buffer.Buffer,
) -> Unit raise @proto.ProtocolError {
  buf.write_byte(if closed { 1 } else { 0 })
  let payload = @buffer.new()
  let mut num_points = 0
  for point in points {
    let (x, y) = point
    num_points = num_points + 1
    payload.write_double_be(x)
    payload.write_double_be(y)
  }
  let num_points_i32 = @proto.i32_from_usize(num_points)
  buf.write_int_be(num_points_i32)
  buf.write_bytes(payload.to_bytes())
}

///|
/// Deserialize a path value.
pub fn path_from_sql(buf : BytesView) -> Path raise @proto.ProtocolError {
  let r = @proto.ByteReader::new(buf)
  let closed = r.read_u8() != 0
  let points = r.read_i32_be()
  { closed, points, buf: buf[5:] }
}

///|
/// A Postgres path.
pub struct Path {
  closed : Bool
  points : Int
  buf : BytesView
}

///|
pub fn Path::closed(self : Path) -> Bool {
  self.closed
}

///|
pub fn Path::points(self : Path) -> PathPoints {
  { remaining: self.points, buf: self.buf }
}

///|
/// Iterator over path points.
pub struct PathPoints {
  mut remaining : Int
  mut buf : BytesView
}

///|
pub fn PathPoints::next(self : PathPoints) -> Point? raise @proto.ProtocolError {
  if self.remaining == 0 {
    if self.buf.length() != 0 {
      raise @proto.ProtocolError::InvalidInput(
        "invalid message length: path points not drained",
      )
    }
    return None
  }
  self.remaining = self.remaining - 1
  let r = @proto.ByteReader::new(self.buf)
  let x = r.read_f64_be()
  let y = r.read_f64_be()
  self.buf = self.buf[16:]
  Some({ x, y })
}

///|
/// IP address types.
pub enum IpAddr {
  V4(Ipv4Addr)
  V6(Ipv6Addr)
}

///|
pub struct Ipv4Addr {
  octets : Bytes
}

///|
pub struct Ipv6Addr {
  octets : Bytes
}

///|
pub fn Ipv4Addr::from_octets(
  octets : BytesView,
) -> Ipv4Addr raise @proto.ProtocolError {
  if octets.length() != 4 {
    raise @proto.ProtocolError::InvalidInput("invalid IPv4 length")
  }
  { octets: octets.to_bytes() }
}

///|
pub fn Ipv6Addr::from_octets(
  octets : BytesView,
) -> Ipv6Addr raise @proto.ProtocolError {
  if octets.length() != 16 {
    raise @proto.ProtocolError::InvalidInput("invalid IPv6 length")
  }
  { octets: octets.to_bytes() }
}

///|
pub fn Ipv4Addr::octets(self : Ipv4Addr) -> BytesView {
  self.octets[:]
}

///|
pub fn Ipv6Addr::octets(self : Ipv6Addr) -> BytesView {
  self.octets[:]
}

///|
/// Serialize a Postgres inet.
pub fn inet_to_sql(addr : IpAddr, netmask : Byte, buf : @buffer.Buffer) -> Unit {
  match addr {
    V4(v4) => {
      buf.write_byte(pgsql_af_inet)
      buf.write_byte(netmask)
      buf.write_byte(0)
      buf.write_byte(4)
      buf.write_bytesview(v4.octets[:])
    }
    V6(v6) => {
      buf.write_byte(pgsql_af_inet6)
      buf.write_byte(netmask)
      buf.write_byte(0)
      buf.write_byte(16)
      buf.write_bytesview(v6.octets[:])
    }
  }
}

///|
/// Deserialize a Postgres inet.
pub fn inet_from_sql(buf : BytesView) -> Inet raise @proto.ProtocolError {
  let r = @proto.ByteReader::new(buf)
  let family = r.read_u8()
  let netmask = r.read_u8()
  let _is_cidr = r.read_u8()
  let len = r.read_u8()
  let addr = match family {
    _ if family == pgsql_af_inet => {
      if netmask > 32 {
        raise @proto.ProtocolError::InvalidInput("invalid IPv4 netmask")
      }
      if len != 4 {
        raise @proto.ProtocolError::InvalidInput("invalid IPv4 address length")
      }
      let octets = r.read_bytes(4).to_bytes()
      IpAddr::V4({ octets, })
    }
    _ if family == pgsql_af_inet6 => {
      if netmask > 128 {
        raise @proto.ProtocolError::InvalidInput("invalid IPv6 netmask")
      }
      if len != 16 {
        raise @proto.ProtocolError::InvalidInput("invalid IPv6 address length")
      }
      let octets = r.read_bytes(16).to_bytes()
      IpAddr::V6({ octets, })
    }
    _ => raise @proto.ProtocolError::InvalidInput("invalid IP family")
  }
  if not(r.is_empty()) {
    raise @proto.ProtocolError::InvalidInput("invalid buffer size")
  }
  { addr, netmask }
}

///|
/// A Postgres network address.
pub struct Inet {
  addr : IpAddr
  netmask : Byte
}

///|
pub fn Inet::addr(self : Inet) -> IpAddr {
  self.addr
}

///|
pub fn Inet::netmask(self : Inet) -> Byte {
  self.netmask
}

///|
/// Serialize a Postgres ltree string.
pub fn ltree_to_sql(v : BytesView, buf : @buffer.Buffer) -> Unit {
  buf.write_byte(b'\x01')
  buf.write_bytesview(v)
}

///|
/// Deserialize a Postgres ltree string.
pub fn ltree_from_sql(buf : BytesView) -> Bytes raise @proto.ProtocolError {
  match buf {
    [b'\x01', .. rest] => rest.to_bytes()
    _ =>
      raise @proto.ProtocolError::InvalidInput("ltree version 1 only supported")
  }
}

///|
/// Serialize a Postgres lquery string.
pub fn lquery_to_sql(v : BytesView, buf : @buffer.Buffer) -> Unit {
  buf.write_byte(b'\x01')
  buf.write_bytesview(v)
}

///|
/// Deserialize a Postgres lquery string.
pub fn lquery_from_sql(buf : BytesView) -> Bytes raise @proto.ProtocolError {
  match buf {
    [b'\x01', .. rest] => rest.to_bytes()
    _ =>
      raise @proto.ProtocolError::InvalidInput(
        "lquery version 1 only supported",
      )
  }
}

///|
/// Serialize a Postgres ltxtquery string.
pub fn ltxtquery_to_sql(v : BytesView, buf : @buffer.Buffer) -> Unit {
  buf.write_byte(b'\x01')
  buf.write_bytesview(v)
}

///|
/// Deserialize a Postgres ltxtquery string.
pub fn ltxtquery_from_sql(buf : BytesView) -> Bytes raise @proto.ProtocolError {
  match buf {
    [b'\x01', .. rest] => rest.to_bytes()
    _ =>
      raise @proto.ProtocolError::InvalidInput(
        "ltxtquery version 1 only supported",
      )
  }
}
