// Built-in codecs for primitive MoonBit values.

///|
// `Bool` maps directly to PostgreSQL `bool`.
pub impl ToSql for Bool with fn accepts(_, type_) {
  type_.oid == BOOL_OID
}

///|
pub impl ToSql for Bool with fn moonbit_type_name(_) {
  "Bool"
}

///|
pub impl ToSql for Bool with fn to_sql(self, _, buf) {
  @types.bool_to_sql(self, buf)
  No
}

///|
pub impl FromSql for Bool with fn accepts(type_) {
  type_.oid == BOOL_OID
}

///|
pub impl FromSql for Bool with fn moonbit_type_name() {
  "Bool"
}

///|
pub impl FromSql for Bool with fn from_sql(_, format, raw) {
  match format {
    Text => decode_utf8(raw) == "t" || decode_utf8(raw) == "true"
    Binary => @types.bool_from_sql(raw)
  }
}

///|
// `Int` is intentionally limited to PostgreSQL `int2` and `int4`.
pub impl ToSql for Int with fn to_sql(self, type_, buf) {
  match type_.oid {
    INT2_OID => @types.int2_to_sql(self, buf)
    INT4_OID => @types.int4_to_sql(self, buf)
    _ => raise ClientError::Encode("cannot encode Int for type \{type_.name}")
  }
  No
}

///|
pub impl ToSql for Int with fn accepts(_, type_) {
  match type_.oid {
    INT2_OID | INT4_OID => true
    _ => false
  }
}

///|
pub impl ToSql for Int with fn moonbit_type_name(_) {
  "Int"
}

///|
pub impl FromSql for Int with fn from_sql(type_, format, raw) {
  match format {
    Text => @string.parse_int(decode_utf8(raw))
    Binary =>
      match type_.oid {
        INT2_OID => @types.int2_from_sql(raw)
        INT4_OID => @types.int4_from_sql(raw)
        _ => raise ClientError::Decode("cannot decode Int from \{type_.name}")
      }
  }
}

///|
pub impl FromSql for Int with fn accepts(type_) {
  match type_.oid {
    INT2_OID | INT4_OID => true
    _ => false
  }
}

///|
pub impl FromSql for Int with fn moonbit_type_name() {
  "Int"
}

///|
// `Int64` maps to PostgreSQL `int8`.
pub impl ToSql for Int64 with fn accepts(_, type_) {
  type_.oid == INT8_OID
}

///|
pub impl ToSql for Int64 with fn moonbit_type_name(_) {
  "Int64"
}

///|
pub impl ToSql for Int64 with fn to_sql(self, _, buf) {
  @types.int8_to_sql(self, buf)
  No
}

///|
pub impl FromSql for Int64 with fn accepts(type_) {
  type_.oid == INT8_OID
}

///|
pub impl FromSql for Int64 with fn moonbit_type_name() {
  "Int64"
}

///|
pub impl FromSql for Int64 with fn from_sql(_, format, raw) {
  match format {
    Text => @string.parse_int64(decode_utf8(raw))
    Binary => @types.int8_from_sql(raw)
  }
}

///|
// `Float` maps to PostgreSQL single precision `float4`.
pub impl ToSql for Float with fn accepts(_, type_) {
  type_.oid == FLOAT4_OID
}

///|
pub impl ToSql for Float with fn moonbit_type_name(_) {
  "Float"
}

///|
pub impl ToSql for Float with fn to_sql(self, _, buf) {
  @types.float4_to_sql(self, buf)
  No
}

///|
pub impl FromSql for Float with fn accepts(type_) {
  type_.oid == FLOAT4_OID
}

///|
pub impl FromSql for Float with fn moonbit_type_name() {
  "Float"
}

///|
pub impl FromSql for Float with fn from_sql(_, format, raw) {
  match format {
    Text => Float::from_double(@string.parse_double(decode_utf8(raw)))
    Binary => @types.float4_from_sql(raw)
  }
}

///|
// `Double` maps to PostgreSQL double precision `float8`.
pub impl ToSql for Double with fn accepts(_, type_) {
  type_.oid == FLOAT8_OID
}

///|
pub impl ToSql for Double with fn moonbit_type_name(_) {
  "Double"
}

///|
pub impl ToSql for Double with fn to_sql(self, _, buf) {
  @types.float8_to_sql(self, buf)
  No
}

///|
pub impl FromSql for Double with fn accepts(type_) {
  type_.oid == FLOAT8_OID
}

///|
pub impl FromSql for Double with fn moonbit_type_name() {
  "Double"
}

///|
pub impl FromSql for Double with fn from_sql(_, format, raw) {
  match format {
    Text => @string.parse_double(decode_utf8(raw))
    Binary => @types.float8_from_sql(raw)
  }
}

///|
// `UInt` is reserved for PostgreSQL `oid`.
pub impl ToSql for UInt with fn accepts(_, type_) {
  type_.oid == OID_TYPE_OID
}

///|
pub impl ToSql for UInt with fn moonbit_type_name(_) {
  "UInt"
}

///|
pub impl ToSql for UInt with fn to_sql(self, _, buf) {
  @types.oid_to_sql(self, buf)
  No
}

///|
pub impl FromSql for UInt with fn accepts(type_) {
  type_.oid == OID_TYPE_OID
}

///|
pub impl FromSql for UInt with fn moonbit_type_name() {
  "UInt"
}

///|
pub impl FromSql for UInt with fn from_sql(_, format, raw) {
  match format {
    Text => @string.parse_uint(decode_utf8(raw))
    Binary => @types.oid_from_sql(raw)
  }
}

///|
// `String` prefers text format because PostgreSQL text types are naturally textual.
pub impl ToSql for String with fn accepts(_, type_) {
  is_text_type(type_)
}

///|
pub impl ToSql for String with fn moonbit_type_name(_) {
  "String"
}

///|
pub impl ToSql for String with fn format(_, _) {
  Text
}

///|
pub impl ToSql for String with fn to_sql(self, _, buf) {
  buf.write_bytes(@proto.utf8_encode(self))
  No
}

///|
pub impl FromSql for String with fn accepts(type_) {
  is_text_type(type_)
}

///|
pub impl FromSql for String with fn moonbit_type_name() {
  "String"
}

///|
pub impl FromSql for String with fn from_sql(_, _, raw) {
  decode_utf8(raw)
}

///|
// `Bytes` currently covers PostgreSQL `bytea` and raw `uuid` storage.
pub impl ToSql for Bytes with fn accepts(_, type_) {
  is_bytes_type(type_)
}

///|
pub impl ToSql for Bytes with fn moonbit_type_name(_) {
  "Bytes"
}

///|
pub impl ToSql for Bytes with fn to_sql(self, type_, buf) {
  match type_.oid {
    BYTEA_OID => @types.bytea_to_sql(self[:], buf)
    UUID_OID => @types.uuid_to_sql(self[:], buf)
    _ => raise ClientError::Encode("cannot encode bytes for type \{type_.name}")
  }
  No
}

///|
pub impl FromSql for Bytes with fn accepts(type_) {
  is_bytes_type(type_)
}

///|
pub impl FromSql for Bytes with fn moonbit_type_name() {
  "Bytes"
}

///|
pub impl FromSql for Bytes with fn from_sql(type_, format, raw) {
  match format {
    Text =>
      if type_.oid == BYTEA_OID {
        raw.to_owned()
      } else {
        @proto.utf8_encode(decode_utf8(raw))
      }
    Binary =>
      match type_.oid {
        BYTEA_OID => @types.bytea_from_sql(raw).to_owned()
        UUID_OID => @types.uuid_from_sql(raw)
        _ => raw.to_owned()
      }
  }
}

///|
// `Json` is sent as text so the same codec covers PostgreSQL `json` and `jsonb`.
pub impl ToSql for Json with fn accepts(_, type_) {
  is_json_type(type_)
}

///|
pub impl ToSql for Json with fn moonbit_type_name(_) {
  "Json"
}

///|
pub impl ToSql for Json with fn format(_, _) {
  Text
}

///|
pub impl ToSql for Json with fn to_sql(self, _, buf) {
  buf.write_bytes(@proto.utf8_encode(self.stringify()))
  No
}

///|
pub impl FromSql for Json with fn accepts(type_) {
  is_json_type(type_)
}

///|
pub impl FromSql for Json with fn moonbit_type_name() {
  "Json"
}

///|
pub impl FromSql for Json with fn from_sql(type_, format, raw) {
  match format {
    Text => @json.parse(decode_utf8(raw)[:])
    Binary =>
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
