// PostgreSQL type descriptors used by encoding, decoding, and catalog lookups.

///|
/// Classifies the structural shape of a PostgreSQL type.
///
/// Most user-facing codecs only care whether a type is a simple scalar or an
/// array, but the richer variants let the client cache enough metadata for
/// advanced introspection and future extension points.
pub enum Kind {
  /// A plain scalar type such as `int4` or `timestamp`.
  Simple
  /// An array type whose element type is identified by OID.
  Array(@proto.Oid)
  /// An enum type with the full ordered label set cached locally.
  Enum(Array[String])
  /// A composite/record-like type with named fields.
  Composite(Array[Field])
  /// A domain that wraps another base type.
  Domain(@proto.Oid)
  /// A range type whose subtype is identified by OID.
  Range(@proto.Oid)
  /// A pseudo type such as `void`.
  Pseudo
  /// A placeholder used when only the OID is known.
  Unknown
} derive(Debug, Eq)

///|
/// Field descriptor stored inside `Kind::Composite`.
pub struct Field {
  /// Field name as reported by PostgreSQL system catalogs.
  name : String
  /// OID of the field type.
  type_oid : @proto.Oid
} derive(Debug, Eq)

///|
/// Stable description of a PostgreSQL type known to the client.
///
/// Built-in descriptors are created eagerly for common scalar and array types.
/// Less common server-defined types are resolved lazily through catalog queries
/// and then cached in the shared client state.
pub struct Type {
  /// Numeric PostgreSQL object identifier.
  oid : @proto.Oid
  /// Server-visible type name, such as `"int4"` or `"_uuid"`.
  name : String
  /// Structural classification used by higher-level logic.
  kind : Kind
} derive(Debug, Eq)

///|
/// Return the built-in PostgreSQL `bool` type descriptor.
pub fn Type::bool() -> Type {
  { oid: BOOL_OID, name: "bool", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `bytea` type descriptor.
pub fn Type::bytea() -> Type {
  { oid: BYTEA_OID, name: "bytea", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `char` type descriptor.
pub fn Type::char() -> Type {
  { oid: CHAR_OID, name: "char", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `name` type descriptor.
pub fn Type::name_type() -> Type {
  { oid: NAME_OID, name: "name", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `int8` type descriptor.
pub fn Type::int8() -> Type {
  { oid: INT8_OID, name: "int8", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `int2` type descriptor.
pub fn Type::int2() -> Type {
  { oid: INT2_OID, name: "int2", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `int4` type descriptor.
pub fn Type::int4() -> Type {
  { oid: INT4_OID, name: "int4", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `text` type descriptor.
pub fn Type::text() -> Type {
  { oid: TEXT_OID, name: "text", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `oid` type descriptor.
pub fn Type::oid_type() -> Type {
  { oid: OID_TYPE_OID, name: "oid", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `float4` type descriptor.
pub fn Type::float4() -> Type {
  { oid: FLOAT4_OID, name: "float4", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `float8` type descriptor.
pub fn Type::float8() -> Type {
  { oid: FLOAT8_OID, name: "float8", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `varchar` type descriptor.
pub fn Type::varchar() -> Type {
  { oid: VARCHAR_OID, name: "varchar", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `date` type descriptor.
pub fn Type::date() -> Type {
  { oid: DATE_OID, name: "date", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `time` type descriptor.
pub fn Type::time() -> Type {
  { oid: TIME_OID, name: "time", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `timestamp` type descriptor.
pub fn Type::timestamp() -> Type {
  { oid: TIMESTAMP_OID, name: "timestamp", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `timestamptz` type descriptor.
pub fn Type::timestamptz() -> Type {
  { oid: TIMESTAMPTZ_OID, name: "timestamptz", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `uuid` type descriptor.
pub fn Type::uuid() -> Type {
  { oid: UUID_OID, name: "uuid", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `json` type descriptor.
pub fn Type::json() -> Type {
  { oid: JSON_OID, name: "json", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `jsonb` type descriptor.
pub fn Type::jsonb() -> Type {
  { oid: JSONB_OID, name: "jsonb", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `bool[]` type descriptor.
pub fn Type::bool_array() -> Type {
  { oid: BOOL_ARRAY_OID, name: "_bool", kind: Kind::Array(BOOL_OID) }
}

///|
/// Return the built-in PostgreSQL `bytea[]` type descriptor.
pub fn Type::bytea_array() -> Type {
  { oid: BYTEA_ARRAY_OID, name: "_bytea", kind: Kind::Array(BYTEA_OID) }
}

///|
/// Return the built-in PostgreSQL `int2[]` type descriptor.
pub fn Type::int2_array() -> Type {
  { oid: INT2_ARRAY_OID, name: "_int2", kind: Kind::Array(INT2_OID) }
}

///|
/// Return the built-in PostgreSQL `int4[]` type descriptor.
pub fn Type::int4_array() -> Type {
  { oid: INT4_ARRAY_OID, name: "_int4", kind: Kind::Array(INT4_OID) }
}

///|
/// Return the built-in PostgreSQL `text[]` type descriptor.
pub fn Type::text_array() -> Type {
  { oid: TEXT_ARRAY_OID, name: "_text", kind: Kind::Array(TEXT_OID) }
}

///|
/// Return the built-in PostgreSQL `varchar[]` type descriptor.
pub fn Type::varchar_array() -> Type {
  { oid: VARCHAR_ARRAY_OID, name: "_varchar", kind: Kind::Array(VARCHAR_OID) }
}

///|
/// Return the built-in PostgreSQL `int8[]` type descriptor.
pub fn Type::int8_array() -> Type {
  { oid: INT8_ARRAY_OID, name: "_int8", kind: Kind::Array(INT8_OID) }
}

///|
/// Return the built-in PostgreSQL `float4[]` type descriptor.
pub fn Type::float4_array() -> Type {
  { oid: FLOAT4_ARRAY_OID, name: "_float4", kind: Kind::Array(FLOAT4_OID) }
}

///|
/// Return the built-in PostgreSQL `float8[]` type descriptor.
pub fn Type::float8_array() -> Type {
  { oid: FLOAT8_ARRAY_OID, name: "_float8", kind: Kind::Array(FLOAT8_OID) }
}

///|
/// Return the built-in PostgreSQL `timestamp[]` type descriptor.
pub fn Type::timestamp_array() -> Type {
  {
    oid: TIMESTAMP_ARRAY_OID,
    name: "_timestamp",
    kind: Kind::Array(TIMESTAMP_OID),
  }
}

///|
/// Return the built-in PostgreSQL `date[]` type descriptor.
pub fn Type::date_array() -> Type {
  { oid: DATE_ARRAY_OID, name: "_date", kind: Kind::Array(DATE_OID) }
}

///|
/// Return the built-in PostgreSQL `uuid[]` type descriptor.
pub fn Type::uuid_array() -> Type {
  { oid: UUID_ARRAY_OID, name: "_uuid", kind: Kind::Array(UUID_OID) }
}

///|
/// Construct a placeholder descriptor for a type that has not been catalogued.
///
/// Unknown descriptors let the client carry OID information through error
/// messages and metadata paths even when it has not yet queried PostgreSQL's
/// system catalogs for richer shape information.
pub fn Type::unknown(oid : @proto.Oid, name? : String = "unknown") -> Type {
  { oid, name, kind: Kind::Unknown }
}

///|
/// Resolve a well-known built-in type without querying PostgreSQL catalogs.
///
/// This is the hot path for the scalar and array types the package currently
/// ships first-class codecs for.
fn builtin_type(oid : @proto.Oid) -> Type? {
  match oid {
    BOOL_OID => Some(Type::bool())
    BYTEA_OID => Some(Type::bytea())
    CHAR_OID => Some(Type::char())
    NAME_OID => Some(Type::name_type())
    INT8_OID => Some(Type::int8())
    INT2_OID => Some(Type::int2())
    INT4_OID => Some(Type::int4())
    TEXT_OID => Some(Type::text())
    OID_TYPE_OID => Some(Type::oid_type())
    JSON_OID => Some(Type::json())
    FLOAT4_OID => Some(Type::float4())
    FLOAT8_OID => Some(Type::float8())
    BOOL_ARRAY_OID => Some(Type::bool_array())
    BYTEA_ARRAY_OID => Some(Type::bytea_array())
    INT2_ARRAY_OID => Some(Type::int2_array())
    INT4_ARRAY_OID => Some(Type::int4_array())
    TEXT_ARRAY_OID => Some(Type::text_array())
    VARCHAR_ARRAY_OID => Some(Type::varchar_array())
    INT8_ARRAY_OID => Some(Type::int8_array())
    FLOAT4_ARRAY_OID => Some(Type::float4_array())
    FLOAT8_ARRAY_OID => Some(Type::float8_array())
    VARCHAR_OID => Some(Type::varchar())
    DATE_OID => Some(Type::date())
    TIME_OID => Some(Type::time())
    TIMESTAMP_OID => Some(Type::timestamp())
    TIMESTAMP_ARRAY_OID => Some(Type::timestamp_array())
    DATE_ARRAY_OID => Some(Type::date_array())
    TIMESTAMPTZ_OID => Some(Type::timestamptz())
    UUID_OID => Some(Type::uuid())
    UUID_ARRAY_OID => Some(Type::uuid_array())
    JSONB_OID => Some(Type::jsonb())
    _ => None
  }
}

///|
/// Return the best local descriptor available for an OID.
///
/// This helper never performs I/O. It is used while parsing row descriptions,
/// where only the OID is available initially and a fully catalogued type may be
/// resolved later by the client's shared type cache.
fn resolve_type(oid : @proto.Oid) -> Type {
  builtin_type(oid).unwrap_or(Type::unknown(oid, name="oid_\{oid.to_string()}"))
}

///|
/// Build a uniform `ClientError::WrongType` value for codec compatibility checks.
fn wrong_type_error(moonbit_type : String, postgres_type : Type) -> ClientError {
  ClientError::WrongType({ moonbit_type, postgres_type })
}

///|
/// Return whether a PostgreSQL type should be treated as textual by default.
///
/// Besides core text-like OIDs, this helper recognizes a handful of common
/// extension types that are naturally represented as strings in user code.
fn is_text_type(type_ : Type) -> Bool {
  match type_.oid {
    NAME_OID | TEXT_OID | VARCHAR_OID => true
    _ =>
      match type_.name {
        "bpchar" | "citext" | "lquery" | "ltree" | "ltxtquery" | "unknown" =>
          true
        _ => false
      }
  }
}

///|
/// Return whether the built-in `Bytes` codec should accept this PostgreSQL type.
fn is_bytes_type(type_ : Type) -> Bool {
  match type_.oid {
    BYTEA_OID | UUID_OID => true
    _ => false
  }
}
