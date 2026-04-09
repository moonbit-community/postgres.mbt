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
  { oid: 16U, name: "bool", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `bytea` type descriptor.
pub fn Type::bytea() -> Type {
  { oid: 17U, name: "bytea", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `char` type descriptor.
pub fn Type::char() -> Type {
  { oid: 18U, name: "char", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `name` type descriptor.
pub fn Type::name_type() -> Type {
  { oid: 19U, name: "name", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `int8` type descriptor.
pub fn Type::int8() -> Type {
  { oid: 20U, name: "int8", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `int2` type descriptor.
pub fn Type::int2() -> Type {
  { oid: 21U, name: "int2", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `int4` type descriptor.
pub fn Type::int4() -> Type {
  { oid: 23U, name: "int4", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `text` type descriptor.
pub fn Type::text() -> Type {
  { oid: 25U, name: "text", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `oid` type descriptor.
pub fn Type::oid_type() -> Type {
  { oid: 26U, name: "oid", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `float4` type descriptor.
pub fn Type::float4() -> Type {
  { oid: 700U, name: "float4", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `float8` type descriptor.
pub fn Type::float8() -> Type {
  { oid: 701U, name: "float8", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `varchar` type descriptor.
pub fn Type::varchar() -> Type {
  { oid: 1043U, name: "varchar", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `date` type descriptor.
pub fn Type::date() -> Type {
  { oid: 1082U, name: "date", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `time` type descriptor.
pub fn Type::time() -> Type {
  { oid: 1083U, name: "time", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `timestamp` type descriptor.
pub fn Type::timestamp() -> Type {
  { oid: 1114U, name: "timestamp", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `timestamptz` type descriptor.
pub fn Type::timestamptz() -> Type {
  { oid: 1184U, name: "timestamptz", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `uuid` type descriptor.
pub fn Type::uuid() -> Type {
  { oid: 2950U, name: "uuid", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `json` type descriptor.
pub fn Type::json() -> Type {
  { oid: 114U, name: "json", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `jsonb` type descriptor.
pub fn Type::jsonb() -> Type {
  { oid: 3802U, name: "jsonb", kind: Kind::Simple }
}

///|
/// Return the built-in PostgreSQL `bool[]` type descriptor.
pub fn Type::bool_array() -> Type {
  { oid: 1000U, name: "_bool", kind: Kind::Array(16U) }
}

///|
/// Return the built-in PostgreSQL `bytea[]` type descriptor.
pub fn Type::bytea_array() -> Type {
  { oid: 1001U, name: "_bytea", kind: Kind::Array(17U) }
}

///|
/// Return the built-in PostgreSQL `int2[]` type descriptor.
pub fn Type::int2_array() -> Type {
  { oid: 1005U, name: "_int2", kind: Kind::Array(21U) }
}

///|
/// Return the built-in PostgreSQL `int4[]` type descriptor.
pub fn Type::int4_array() -> Type {
  { oid: 1007U, name: "_int4", kind: Kind::Array(23U) }
}

///|
/// Return the built-in PostgreSQL `text[]` type descriptor.
pub fn Type::text_array() -> Type {
  { oid: 1009U, name: "_text", kind: Kind::Array(25U) }
}

///|
/// Return the built-in PostgreSQL `varchar[]` type descriptor.
pub fn Type::varchar_array() -> Type {
  { oid: 1015U, name: "_varchar", kind: Kind::Array(1043U) }
}

///|
/// Return the built-in PostgreSQL `int8[]` type descriptor.
pub fn Type::int8_array() -> Type {
  { oid: 1016U, name: "_int8", kind: Kind::Array(20U) }
}

///|
/// Return the built-in PostgreSQL `float4[]` type descriptor.
pub fn Type::float4_array() -> Type {
  { oid: 1021U, name: "_float4", kind: Kind::Array(700U) }
}

///|
/// Return the built-in PostgreSQL `float8[]` type descriptor.
pub fn Type::float8_array() -> Type {
  { oid: 1022U, name: "_float8", kind: Kind::Array(701U) }
}

///|
/// Return the built-in PostgreSQL `timestamp[]` type descriptor.
pub fn Type::timestamp_array() -> Type {
  { oid: 1115U, name: "_timestamp", kind: Kind::Array(1114U) }
}

///|
/// Return the built-in PostgreSQL `date[]` type descriptor.
pub fn Type::date_array() -> Type {
  { oid: 1182U, name: "_date", kind: Kind::Array(1082U) }
}

///|
/// Return the built-in PostgreSQL `uuid[]` type descriptor.
pub fn Type::uuid_array() -> Type {
  { oid: 2951U, name: "_uuid", kind: Kind::Array(2950U) }
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
    16U => Some(Type::bool())
    17U => Some(Type::bytea())
    18U => Some(Type::char())
    19U => Some(Type::name_type())
    20U => Some(Type::int8())
    21U => Some(Type::int2())
    23U => Some(Type::int4())
    25U => Some(Type::text())
    26U => Some(Type::oid_type())
    114U => Some(Type::json())
    700U => Some(Type::float4())
    701U => Some(Type::float8())
    1000U => Some(Type::bool_array())
    1001U => Some(Type::bytea_array())
    1005U => Some(Type::int2_array())
    1007U => Some(Type::int4_array())
    1009U => Some(Type::text_array())
    1015U => Some(Type::varchar_array())
    1016U => Some(Type::int8_array())
    1021U => Some(Type::float4_array())
    1022U => Some(Type::float8_array())
    1043U => Some(Type::varchar())
    1082U => Some(Type::date())
    1083U => Some(Type::time())
    1114U => Some(Type::timestamp())
    1115U => Some(Type::timestamp_array())
    1182U => Some(Type::date_array())
    1184U => Some(Type::timestamptz())
    2950U => Some(Type::uuid())
    2951U => Some(Type::uuid_array())
    3802U => Some(Type::jsonb())
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
    19U | 25U | 1043U => true
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
    17U | 2950U => true
    _ => false
  }
}
