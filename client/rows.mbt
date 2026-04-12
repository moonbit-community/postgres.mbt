// Row metadata and typed row access helpers.

///|
/// Metadata describing one result column.
///
/// A `Column` combines protocol-level row-description fields with the driver's
/// resolved `Type` descriptor so higher-level code can inspect both raw wire
/// details and semantic type information.
pub struct Column {
  /// Column label chosen by the query.
  name : String
  /// Source table OID, or `0` when PostgreSQL cannot provide one.
  table_oid : @proto.Oid
  /// Source column number inside the table, or `0` when unavailable.
  column_id : Int
  /// Resolved PostgreSQL type descriptor.
  type_ : Type
  /// Storage size reported by PostgreSQL, or `-1` for variable-width types.
  type_size : Int
  /// Type modifier reported by PostgreSQL.
  type_modifier : Int
  /// Wire format used for this column in the current result stream.
  format : WireFormat
} derive(Debug, Eq)

///|
/// One fully materialized row from an extended query.
///
/// The row stores its column metadata alongside the raw field payloads so each
/// `get` call can validate the target type, decode on demand, and still support
/// low-level access through `get_raw`.
pub struct Row {
  /// Column metadata for each position.
  columns : Array[Column]
  /// Raw field payloads. `None` represents SQL `NULL`.
  values : Array[Bytes?]
} derive(Debug, Eq)

///|
/// Return the number of values in this row.
pub fn Row::len(self : Row) -> Int {
  self.values.length()
}

///|
/// Return the index of the named column, if present.
///
/// Column matching is exact and scans from left to right, so the first matching
/// name wins when a query produces duplicate column labels.
pub fn Row::index_of(self : Row, name : String) -> Int? {
  for index, column in self.columns {
    if column.name == name {
      return Some(index)
    }
  }
  None
}

///|
/// Return the raw field bytes at `index`.
///
/// This is the escape hatch for callers that want to perform custom decoding or
/// inspect values that do not yet have a `FromSql` implementation.
pub fn Row::get_raw(self : Row, index : Int) -> Bytes? {
  self.values[index]
}

///|
/// Return the raw field bytes for the named column.
pub fn Row::get_raw_name(self : Row, name : String) -> Bytes? raise {
  match self.index_of(name) {
    None => raise ClientError::ColumnNotFound(name)
    Some(index) => self.get_raw(index)
  }
}

///|
/// Decode the field at `index` as `T`.
///
/// The compatibility check happens before any decoder code runs, so a custom
/// `FromSql` implementation can rely on receiving a PostgreSQL type it claimed
/// to support.
pub fn[T : FromSql] Row::get(self : Row, index : Int) -> T raise {
  let column = self.columns[index]
  guard T::accepts(column.type_) else {
    raise wrong_type_error(T::moonbit_type_name(), column.type_)
  }
  match self.values[index] {
    None => FromSql::from_sql_null(column.type_, column.format)
    Some(value) => FromSql::from_sql(column.type_, column.format, value[:])
  }
}

///|
/// Decode the named column as `T`.
pub fn[T : FromSql] Row::get_name(self : Row, name : String) -> T raise {
  match self.index_of(name) {
    None => raise ClientError::ColumnNotFound(name)
    Some(index) => self.get(index)
  }
}

///|
/// Decode the field at `index` as `T`, returning `None` when out of range.
pub fn[T : FromSql] Row::try_get(self : Row, index : Int) -> T? raise {
  if index < 0 || index >= self.len() {
    return None
  }
  Some(self.get(index))
}

///|
/// Decode the named column as `T`, returning `None` when the column is absent.
pub fn[T : FromSql] Row::try_get_name(self : Row, name : String) -> T? raise {
  match self.index_of(name) {
    None => None
    Some(index) => Some(self.get(index))
  }
}

///|
/// Decode the field at `index` as nullable text.
///
/// This is shorthand for `self.get[String?](index)` and therefore preserves SQL
/// `NULL` as `None`.
pub fn Row::get_text(self : Row, index : Int) -> String? raise {
  self.get(index)
}

///|
/// Decode the named field as nullable text.
pub fn Row::get_text_name(self : Row, name : String) -> String? raise {
  self.get_name(name)
}
