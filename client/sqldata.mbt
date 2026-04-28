// Traits and generic helpers for PostgreSQL value encoding and decoding.

///|
/// PostgreSQL wire-format selection for parameters and result columns.
pub(all) enum WireFormat {
  Text
  Binary
} derive(Debug, Eq)

///|
fn encode_wire_format(format : WireFormat) -> Int {
  match format {
    WireFormat::Text => 0
    WireFormat::Binary => 1
  }
}

///|
fn decode_wire_format(code : Int) -> WireFormat raise {
  match code {
    0 => WireFormat::Text
    1 => WireFormat::Binary
    _ =>
      raise ClientError::Protocol(
        "unsupported wire format code: \{code.to_string()}",
      )
  }
}

///|
/// Trait implemented by values that can be encoded as query parameters.
///
/// The driver asks three questions before sending a parameter:
/// 1. `accepts`: does the codec support the PostgreSQL target type?
/// 2. `format`: should PostgreSQL receive `WireFormat::Text` or
///    `WireFormat::Binary` data?
/// 3. `to_sql`: write the actual payload or mark the value as `NULL`.
///
/// The compatibility check happens before serialization, which keeps failures
/// deterministic and improves error messages for callers.
/// A minimal custom text codec usually overrides `format` to return
/// `WireFormat::Text`,
/// checks the target OID in `accepts`, writes UTF-8 bytes in `to_sql`, and
/// returns `IsNull::No`.
pub(open) trait ToSql {
  /// Return the PostgreSQL wire format to use for this value.
  format(Self, Type) -> WireFormat = _
  /// Return whether this value can be encoded for the provided PostgreSQL type.
  accepts(Self, Type) -> Bool
  /// Human-readable type name used in `WrongTypeError`.
  moonbit_type_name(Self) -> String
  /// Serialize the value into `buf`, or return `IsNull::Yes` for `NULL`.
  to_sql(Self, Type, @buffer.Buffer) -> @proto.IsNull raise Error
}

///|
/// Default `ToSql` implementations use PostgreSQL binary format.
impl ToSql with format(_, _) {
  WireFormat::Binary
}

///|
/// Trait implemented by values that can be decoded from a result column.
///
/// `Row::get` performs the `accepts` check before invoking `from_sql`, so a
/// decoder can assume it only receives compatible PostgreSQL types unless the
/// row was constructed manually in tests. For nullable columns, either decode
/// into `T?` or implement `from_sql_null` directly.
pub(open) trait FromSql {
  /// Decode a non-NULL value.
  from_sql(Type, WireFormat, BytesView) -> Self raise Error
  /// Return whether this decoder accepts the PostgreSQL column type.
  accepts(Type) -> Bool
  /// Human-readable type name used in `WrongTypeError`.
  moonbit_type_name() -> String
  /// Decode a `NULL` value. The default implementation rejects `NULL`.
  from_sql_null(Type, WireFormat) -> Self raise Error = _
}

///|
/// The default NULL decoder rejects nullable database values.
impl FromSql with from_sql_null(type_, _) {
  raise ClientError::Decode("unexpected NULL for type \{type_.name}")
}

///|
/// Optional parameters encode `None` as SQL `NULL` and delegate `Some` values.
pub impl[T : ToSql] ToSql for T? with format(self, type_) {
  match self {
    None => WireFormat::Binary
    Some(value) => value.format(type_)
  }
}

///|
/// Optional parameters accept every PostgreSQL type when the value is `None`.
pub impl[T : ToSql] ToSql for T? with accepts(self, type_) {
  match self {
    None => true
    Some(value) => value.accepts(type_)
  }
}

///|
/// Optional parameters include the wrapped type name in diagnostics when present.
pub impl[T : ToSql] ToSql for T? with moonbit_type_name(self) {
  match self {
    None => "Option"
    Some(value) => "\{value.moonbit_type_name()}?"
  }
}

///|
/// Optional parameters serialize `None` as SQL `NULL`.
pub impl[T : ToSql] ToSql for T? with to_sql(self, type_, buf) {
  match self {
    None => @proto.IsNull::Yes
    Some(value) => value.to_sql(type_, buf)
  }
}

///|
/// Optional decoders wrap successful non-NULL decoding in `Some`.
pub impl[T : FromSql] FromSql for T? with from_sql(type_, format, raw) {
  let value : T = FromSql::from_sql(type_, format, raw)
  Some(value)
}

///|
/// Optional decoders accept the same PostgreSQL types as their wrapped decoder.
pub impl[T : FromSql] FromSql for T? with accepts(type_) {
  T::accepts(type_)
}

///|
/// Optional decoders annotate the wrapped type name in diagnostics.
pub impl[T : FromSql] FromSql for T? with moonbit_type_name() {
  "\{T::moonbit_type_name()}?"
}

///|
/// Optional decoders map SQL `NULL` to `None`.
pub impl[T : FromSql] FromSql for T? with from_sql_null(_, _) {
  None
}

///|
/// Built-in arrays use PostgreSQL's binary array payload and delegate element
/// encoding to the existing scalar codecs.
pub impl[T : ToSql] ToSql for Array[T] with format(_, _) {
  WireFormat::Binary
}

///|
pub impl[T : ToSql] ToSql for Array[T] with accepts(self, type_) {
  match array_element_type(type_) {
    None => false
    Some(element_type) => self.all(element => element.accepts(element_type))
  }
}

///|
pub impl[T : ToSql] ToSql for Array[T] with moonbit_type_name(self) {
  if self.length() == 0 {
    "Array"
  } else {
    "Array[\{self[0].moonbit_type_name()}]"
  }
}

///|
pub impl[T : ToSql] ToSql for Array[T] with to_sql(self, type_, buf) {
  guard array_element_type(type_) is Some(element_type) else {
    raise ClientError::Encode("cannot encode Array for type \{type_.name}")
  }
  let dimensions = if self.length() == 0 {
    []
  } else {
    [@types.ArrayDimension::new(self.length(), 1)]
  }
  write_array_payload(dimensions, element_type.oid, self, element_type, buf)
  @proto.IsNull::No
}

///|
pub impl[T : FromSql] FromSql for Array[T] with accepts(type_) {
  match array_element_type(type_) {
    None => false
    Some(element_type) => T::accepts(element_type)
  }
}

///|
pub impl[T : FromSql] FromSql for Array[T] with moonbit_type_name() {
  "Array[\{T::moonbit_type_name()}]"
}

///|
pub impl[T : FromSql] FromSql for Array[T] with from_sql(type_, format, raw) {
  guard array_element_type(type_) is Some(element_type) else {
    raise ClientError::Decode("cannot decode Array from \{type_.name}")
  }
  match format {
    WireFormat::Text =>
      raise ClientError::Decode("text array decoding is not supported")
    WireFormat::Binary => {
      let pg_array = @types.array_from_sql(raw)
      if pg_array.dimensions > 1 {
        raise ClientError::Decode("multidimensional arrays are not supported")
      }
      let values : Array[T] = []
      let array_values = pg_array.values()
      for value = array_values.next() {
        match value {
          None => break values
          Some(None) => {
            values.push(T::from_sql_null(element_type, WireFormat::Binary))
            continue array_values.next()
          }
          Some(Some(payload)) => {
            values.push(
              T::from_sql(element_type, WireFormat::Binary, payload[:]),
            )
            continue array_values.next()
          }
        }
      }
    }
  }
}

///|
fn[T : ToSql] array_element_to_sql(
  element : T,
  element_type : Type,
  buf : @buffer.Buffer,
) -> @proto.IsNull raise Error {
  guard element.accepts(element_type) else {
    raise wrong_type_error(element.moonbit_type_name(), element_type)
  }
  match element_type.oid {
    JSONB_OID => jsonb_array_element_to_sql(element, element_type, buf)
    _ => element.to_sql(element_type, buf)
  }
}

///|
fn[T : ToSql] jsonb_array_element_to_sql(
  element : T,
  element_type : Type,
  buf : @buffer.Buffer,
) -> @proto.IsNull raise Error {
  let payload = @buffer.new()
  match element.to_sql(element_type, payload) {
    @proto.IsNull::Yes => @proto.IsNull::Yes
    @proto.IsNull::No => {
      buf.write_byte(b'\x01')
      buf.write_bytes(payload.to_bytes())
      @proto.IsNull::No
    }
  }
}

///|
fn[T : ToSql] write_array_payload(
  dimensions : Array[@types.ArrayDimension],
  element_oid : @proto.Oid,
  elements : Array[T],
  element_type : Type,
  buf : @buffer.Buffer,
) -> Unit raise Error {
  let payload = @buffer.new()
  let mut expected_elements = 1
  for dimension in dimensions {
    if dimension.len < 0 {
      raise ClientError::Encode("invalid array dimension size")
    }
    if dimension.len != 0 {
      let max = 0x7fff_ffff / dimension.len
      if expected_elements > max {
        raise ClientError::Encode("too many array elements")
      }
    }
    expected_elements = expected_elements * dimension.len
    payload.write_int_be(@proto.checked_i32(dimension.len))
    payload.write_int_be(@proto.checked_i32(dimension.lower_bound))
  }
  if dimensions.length() == 0 {
    expected_elements = 0
  }
  if elements.length() != expected_elements {
    raise ClientError::Encode("array element count does not match dimensions")
  }
  let mut has_nulls = false
  for element in elements {
    let element_payload = @buffer.new()
    let is_null = array_element_to_sql(element, element_type, element_payload)
    match is_null {
      @proto.IsNull::Yes => {
        has_nulls = true
        payload.write_int_be(-1)
      }
      @proto.IsNull::No => {
        payload.write_int_be(@proto.i32_from_usize(element_payload.length()))
        payload.write_bytes(element_payload.to_bytes())
      }
    }
  }
  buf.write_int_be(@proto.i32_from_usize(dimensions.length()))
  buf.write_int_be(if has_nulls { 1 } else { 0 })
  buf.write_uint_be(element_oid)
  buf.write_bytes(payload.to_bytes())
}
