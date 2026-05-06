// Built-in codecs for primitive MoonBit values.

///|
// `Bool` maps directly to PostgreSQL `bool`.
pub impl ToSql for Bool with accepts(_, type_) {
  type_.oid == BOOL_OID
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
  type_.oid == BOOL_OID
}

///|
pub impl FromSql for Bool with moonbit_type_name() {
  "Bool"
}

///|
pub impl FromSql for Bool with from_sql(_, format, raw) {
  match format {
    WireFormat::Text => decode_utf8(raw) == "t" || decode_utf8(raw) == "true"
    WireFormat::Binary => @types.bool_from_sql(raw)
  }
}

///|
// `Int` is intentionally limited to PostgreSQL `int2` and `int4`.
pub impl ToSql for Int with to_sql(self, type_, buf) {
  match type_.oid {
    INT2_OID => @types.int2_to_sql(self, buf)
    INT4_OID => @types.int4_to_sql(self, buf)
    _ => raise ClientError::Encode("cannot encode Int for type \{type_.name}")
  }
  @proto.IsNull::No
}

///|
pub impl ToSql for Int with accepts(_, type_) {
  match type_.oid {
    INT2_OID | INT4_OID => true
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
    WireFormat::Text => @string.parse_int(decode_utf8(raw))
    WireFormat::Binary =>
      match type_.oid {
        INT2_OID => @types.int2_from_sql(raw)
        INT4_OID => @types.int4_from_sql(raw)
        _ => raise ClientError::Decode("cannot decode Int from \{type_.name}")
      }
  }
}

///|
pub impl FromSql for Int with accepts(type_) {
  match type_.oid {
    INT2_OID | INT4_OID => true
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
  type_.oid == INT8_OID
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
  type_.oid == INT8_OID
}

///|
pub impl FromSql for Int64 with moonbit_type_name() {
  "Int64"
}

///|
pub impl FromSql for Int64 with from_sql(_, format, raw) {
  match format {
    WireFormat::Text => @string.parse_int64(decode_utf8(raw))
    WireFormat::Binary => @types.int8_from_sql(raw)
  }
}

///|
// `Float` maps to PostgreSQL single precision `float4`.
pub impl ToSql for Float with accepts(_, type_) {
  type_.oid == FLOAT4_OID
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
  type_.oid == FLOAT4_OID
}

///|
pub impl FromSql for Float with moonbit_type_name() {
  "Float"
}

///|
pub impl FromSql for Float with from_sql(_, format, raw) {
  match format {
    WireFormat::Text =>
      Float::from_double(@string.parse_double(decode_utf8(raw)))
    WireFormat::Binary => @types.float4_from_sql(raw)
  }
}

///|
// `Double` maps to PostgreSQL double precision `float8`.
pub impl ToSql for Double with accepts(_, type_) {
  type_.oid == FLOAT8_OID
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
  type_.oid == FLOAT8_OID
}

///|
pub impl FromSql for Double with moonbit_type_name() {
  "Double"
}

///|
pub impl FromSql for Double with from_sql(_, format, raw) {
  match format {
    WireFormat::Text => @string.parse_double(decode_utf8(raw))
    WireFormat::Binary => @types.float8_from_sql(raw)
  }
}

///|
// `UInt` is reserved for PostgreSQL `oid`.
pub impl ToSql for UInt with accepts(_, type_) {
  type_.oid == OID_TYPE_OID
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
  type_.oid == OID_TYPE_OID
}

///|
pub impl FromSql for UInt with moonbit_type_name() {
  "UInt"
}

///|
pub impl FromSql for UInt with from_sql(_, format, raw) {
  match format {
    WireFormat::Text => @string.parse_uint(decode_utf8(raw))
    WireFormat::Binary => @types.oid_from_sql(raw)
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
  WireFormat::Text
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
    BYTEA_OID => @types.bytea_to_sql(self[:], buf)
    UUID_OID => @types.uuid_to_sql(self[:], buf)
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
    WireFormat::Text =>
      if type_.oid == BYTEA_OID {
        raw.to_owned()
      } else {
        @proto.utf8_encode(decode_utf8(raw))
      }
    WireFormat::Binary =>
      match type_.oid {
        BYTEA_OID => @types.bytea_from_sql(raw).to_owned()
        UUID_OID => @types.uuid_from_sql(raw)
        _ => raw.to_owned()
      }
  }
}

///|
// `Json` is sent as text so the same codec covers PostgreSQL `json` and `jsonb`.
pub impl ToSql for Json with accepts(_, type_) {
  is_json_type(type_)
}

///|
pub impl ToSql for Json with moonbit_type_name(_) {
  "Json"
}

///|
pub impl ToSql for Json with format(_, _) {
  WireFormat::Text
}

///|
pub impl ToSql for Json with to_sql(self, _, buf) {
  buf.write_bytes(@proto.utf8_encode(self.stringify()))
  @proto.IsNull::No
}

///|
pub impl FromSql for Json with accepts(type_) {
  is_json_type(type_)
}

///|
pub impl FromSql for Json with moonbit_type_name() {
  "Json"
}

///|
pub impl FromSql for Json with from_sql(type_, format, raw) {
  match format {
    WireFormat::Text => @json.parse(decode_utf8(raw)[:])
    WireFormat::Binary =>
      match type_.oid {
        JSONB_OID => decode_jsonb_binary(raw)
        _ => @json.parse(decode_utf8(raw)[:])
      }
  }
}

///|
fn decode_jsonb_binary(raw : BytesView) -> Json raise Error {
  match raw {
    [b'\x01', .. payload] => @json.parse(decode_utf8(payload)[:])
    _ => raise ClientError::Decode("jsonb version 1 only supported")
  }
}
