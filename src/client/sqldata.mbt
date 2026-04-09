// Traits and generic helpers for PostgreSQL value encoding and decoding.

///|
/// Trait implemented by values that can be encoded as query parameters.
///
/// The driver asks three questions before sending a parameter:
/// 1. `accepts`: does the codec support the PostgreSQL target type?
/// 2. `format`: should PostgreSQL receive text (`0`) or binary (`1`) data?
/// 3. `to_sql`: write the actual payload or mark the value as `NULL`.
///
/// The compatibility check happens before serialization, which keeps failures
/// deterministic and improves error messages for callers.
pub(open) trait ToSql {
  /// Return the PostgreSQL format code to use for this value.
  format(Self, Type) -> Int = _
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
  1
}

///|
/// Trait implemented by values that can be decoded from a result column.
///
/// `Row::get` performs the `accepts` check before invoking `from_sql`, so a
/// decoder can assume it only receives compatible PostgreSQL types unless the
/// row was constructed manually in tests.
pub(open) trait FromSql {
  /// Decode a non-NULL value.
  from_sql(Type, Int, BytesView) -> Self raise Error
  /// Return whether this decoder accepts the PostgreSQL column type.
  accepts(Type) -> Bool
  /// Human-readable type name used in `WrongTypeError`.
  moonbit_type_name() -> String
  /// Decode a `NULL` value. The default implementation rejects `NULL`.
  from_sql_null(Type, Int) -> Self raise Error = _
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
    None => 1
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
