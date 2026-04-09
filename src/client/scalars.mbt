// Built-in codecs for primitive MoonBit values.

///|
// `Bool` maps directly to PostgreSQL `bool`.
pub impl ToSql for Bool with accepts(_, type_) {
  type_.oid == 16U
}

///|
pub impl ToSql for Bool with moonbit_type_name(_) {
  "Bool"
}

///|
pub impl ToSql for Bool with to_sql(self, _, buf) {
  @types.bool_to_sql(self, buf)
  @proto.IsNull::No
}

///|
pub impl FromSql for Bool with accepts(type_) {
  type_.oid == 16U
}

///|
pub impl FromSql for Bool with moonbit_type_name() {
  "Bool"
}

///|
pub impl FromSql for Bool with from_sql(_, format, raw) {
  match format {
    0 => decode_utf8(raw) == "t" || decode_utf8(raw) == "true"
    1 => @types.bool_from_sql(raw)
    _ => raise ClientError::Decode("unsupported format code for bool")
  }
}

///|
// `Int` is intentionally limited to PostgreSQL `int2` and `int4`.
pub impl ToSql for Int with to_sql(self, type_, buf) {
  match type_.oid {
    21U => @types.int2_to_sql(self, buf)
    23U => @types.int4_to_sql(self, buf)
    _ => raise ClientError::Encode("cannot encode Int for type \{type_.name}")
  }
  @proto.IsNull::No
}

///|
pub impl ToSql for Int with accepts(_, type_) {
  match type_.oid {
    21U | 23U => true
    _ => false
  }
}

///|
pub impl ToSql for Int with moonbit_type_name(_) {
  "Int"
}

///|
pub impl FromSql for Int with from_sql(type_, format, raw) {
  match format {
    0 => @string.parse_int(decode_utf8(raw))
    1 =>
      match type_.oid {
        21U => @types.int2_from_sql(raw)
        23U => @types.int4_from_sql(raw)
        _ => raise ClientError::Decode("cannot decode Int from \{type_.name}")
      }
    _ => raise ClientError::Decode("unsupported format code for int")
  }
}

///|
pub impl FromSql for Int with accepts(type_) {
  match type_.oid {
    21U | 23U => true
    _ => false
  }
}

///|
pub impl FromSql for Int with moonbit_type_name() {
  "Int"
}

///|
// `Int64` maps to PostgreSQL `int8`.
pub impl ToSql for Int64 with accepts(_, type_) {
  type_.oid == 20U
}

///|
pub impl ToSql for Int64 with moonbit_type_name(_) {
  "Int64"
}

///|
pub impl ToSql for Int64 with to_sql(self, _, buf) {
  @types.int8_to_sql(self, buf)
  @proto.IsNull::No
}

///|
pub impl FromSql for Int64 with accepts(type_) {
  type_.oid == 20U
}

///|
pub impl FromSql for Int64 with moonbit_type_name() {
  "Int64"
}

///|
pub impl FromSql for Int64 with from_sql(_, format, raw) {
  match format {
    0 => @string.parse_int64(decode_utf8(raw))
    1 => @types.int8_from_sql(raw)
    _ => raise ClientError::Decode("unsupported format code for int8")
  }
}

///|
// `Float` maps to PostgreSQL single precision `float4`.
pub impl ToSql for Float with accepts(_, type_) {
  type_.oid == 700U
}

///|
pub impl ToSql for Float with moonbit_type_name(_) {
  "Float"
}

///|
pub impl ToSql for Float with to_sql(self, _, buf) {
  @types.float4_to_sql(self, buf)
  @proto.IsNull::No
}

///|
pub impl FromSql for Float with accepts(type_) {
  type_.oid == 700U
}

///|
pub impl FromSql for Float with moonbit_type_name() {
  "Float"
}

///|
pub impl FromSql for Float with from_sql(_, format, raw) {
  match format {
    0 => Float::from_double(@string.parse_double(decode_utf8(raw)))
    1 => @types.float4_from_sql(raw)
    _ => raise ClientError::Decode("unsupported format code for float4")
  }
}

///|
// `Double` maps to PostgreSQL double precision `float8`.
pub impl ToSql for Double with accepts(_, type_) {
  type_.oid == 701U
}

///|
pub impl ToSql for Double with moonbit_type_name(_) {
  "Double"
}

///|
pub impl ToSql for Double with to_sql(self, _, buf) {
  @types.float8_to_sql(self, buf)
  @proto.IsNull::No
}

///|
pub impl FromSql for Double with accepts(type_) {
  type_.oid == 701U
}

///|
pub impl FromSql for Double with moonbit_type_name() {
  "Double"
}

///|
pub impl FromSql for Double with from_sql(_, format, raw) {
  match format {
    0 => @string.parse_double(decode_utf8(raw))
    1 => @types.float8_from_sql(raw)
    _ => raise ClientError::Decode("unsupported format code for float8")
  }
}

///|
// `UInt` is reserved for PostgreSQL `oid`.
pub impl ToSql for UInt with accepts(_, type_) {
  type_.oid == 26U
}

///|
pub impl ToSql for UInt with moonbit_type_name(_) {
  "UInt"
}

///|
pub impl ToSql for UInt with to_sql(self, _, buf) {
  @types.oid_to_sql(self, buf)
  @proto.IsNull::No
}

///|
pub impl FromSql for UInt with accepts(type_) {
  type_.oid == 26U
}

///|
pub impl FromSql for UInt with moonbit_type_name() {
  "UInt"
}

///|
pub impl FromSql for UInt with from_sql(_, format, raw) {
  match format {
    0 => @string.parse_uint(decode_utf8(raw))
    1 => @types.oid_from_sql(raw)
    _ => raise ClientError::Decode("unsupported format code for oid")
  }
}

///|
// `String` prefers text format because PostgreSQL text types are naturally textual.
pub impl ToSql for String with accepts(_, type_) {
  is_text_type(type_)
}

///|
pub impl ToSql for String with moonbit_type_name(_) {
  "String"
}

///|
pub impl ToSql for String with format(_, _) {
  0
}

///|
pub impl ToSql for String with to_sql(self, _, buf) {
  buf.write_bytes(@proto.utf8_encode(self))
  @proto.IsNull::No
}

///|
pub impl FromSql for String with accepts(type_) {
  is_text_type(type_)
}

///|
pub impl FromSql for String with moonbit_type_name() {
  "String"
}

///|
pub impl FromSql for String with from_sql(_, _, raw) {
  decode_utf8(raw)
}

///|
// `Bytes` currently covers PostgreSQL `bytea` and raw `uuid` storage.
pub impl ToSql for Bytes with accepts(_, type_) {
  is_bytes_type(type_)
}

///|
pub impl ToSql for Bytes with moonbit_type_name(_) {
  "Bytes"
}

///|
pub impl ToSql for Bytes with to_sql(self, type_, buf) {
  match type_.oid {
    17U => @types.bytea_to_sql(self[:], buf)
    2950U => @types.uuid_to_sql(self[:], buf)
    _ => raise ClientError::Encode("cannot encode bytes for type \{type_.name}")
  }
  @proto.IsNull::No
}

///|
pub impl FromSql for Bytes with accepts(type_) {
  is_bytes_type(type_)
}

///|
pub impl FromSql for Bytes with moonbit_type_name() {
  "Bytes"
}

///|
pub impl FromSql for Bytes with from_sql(type_, format, raw) {
  match format {
    0 =>
      if type_.oid == 17U {
        raw.to_bytes()
      } else {
        @proto.utf8_encode(decode_utf8(raw))
      }
    1 =>
      match type_.oid {
        17U => @types.bytea_from_sql(raw).to_bytes()
        2950U => @types.uuid_from_sql(raw)
        _ => raw.to_bytes()
      }
    _ => raise ClientError::Decode("unsupported format code for bytes")
  }
}
