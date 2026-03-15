///|
pub enum SslMode {
  Disable
  Prefer
  Require
} derive(Show, Eq)

///|
pub fn SslMode::disable() -> SslMode {
  Disable
}

///|
pub fn SslMode::prefer() -> SslMode {
  Prefer
}

///|
pub fn SslMode::require() -> SslMode {
  Require
}

///|
pub enum QueryParam {
  Null
  Text(Bytes)
} derive(Show, Eq)

///|
pub fn QueryParam::null() -> QueryParam {
  Null
}

///|
pub fn QueryParam::bytes(value : BytesView) -> QueryParam {
  Text(value.to_bytes())
}

///|
pub fn QueryParam::string(value : String) -> QueryParam {
  Text(@proto.utf8_encode(value))
}

///|
pub fn QueryParam::bool(value : Bool) -> QueryParam {
  QueryParam::string(if value { "true" } else { "false" })
}

///|
pub fn QueryParam::int(value : Int) -> QueryParam {
  QueryParam::string(value.to_string())
}

///|
pub fn QueryParam::int64(value : Int64) -> QueryParam {
  QueryParam::string(value.to_string())
}

///|
pub fn QueryParam::double(value : Double) -> QueryParam {
  QueryParam::string(value.to_string())
}

///|
fn QueryParam::value(self : QueryParam) -> Bytes? {
  match self {
    Null => None
    Text(value) => Some(value)
  }
}

///|
pub struct DatabaseError {
  severity : String?
  code : String?
  message : String
  detail : String?
  hint : String?
} derive(Show, Eq)

///|
pub fn DatabaseError::severity(self : DatabaseError) -> String? {
  self.severity
}

///|
pub fn DatabaseError::code(self : DatabaseError) -> String? {
  self.code
}

///|
pub fn DatabaseError::message(self : DatabaseError) -> String {
  self.message
}

///|
pub fn DatabaseError::detail(self : DatabaseError) -> String? {
  self.detail
}

///|
pub fn DatabaseError::hint(self : DatabaseError) -> String? {
  self.hint
}

///|
pub suberror ClientError {
  Database(DatabaseError)
  Authentication(String)
  Unsupported(String)
  UnexpectedMessage(String)
  Ssl(String)
} derive(Show, Eq)

///|
pub struct Column {
  name : String
  table_oid : @proto.Oid
  column_id : Int
  type_oid : @proto.Oid
  type_size : Int
  type_modifier : Int
  format : Int
} derive(Show, Eq)

///|
pub fn Column::name(self : Column) -> String {
  self.name
}

///|
pub fn Column::table_oid(self : Column) -> @proto.Oid {
  self.table_oid
}

///|
pub fn Column::column_id(self : Column) -> Int {
  self.column_id
}

///|
pub fn Column::type_oid(self : Column) -> @proto.Oid {
  self.type_oid
}

///|
pub fn Column::type_size(self : Column) -> Int {
  self.type_size
}

///|
pub fn Column::type_modifier(self : Column) -> Int {
  self.type_modifier
}

///|
pub fn Column::format(self : Column) -> Int {
  self.format
}

///|
pub struct Row {
  columns : Array[Column]
  values : Array[Bytes?]
} derive(Show, Eq)

///|
pub fn Row::columns(self : Row) -> Array[Column] {
  self.columns
}

///|
pub fn Row::values(self : Row) -> Array[Bytes?] {
  self.values
}

///|
pub fn Row::len(self : Row) -> Int {
  self.values.length()
}

///|
pub fn Row::get(self : Row, index : Int) -> Bytes? {
  self.values[index]
}

///|
pub fn Row::get_text(
  self : Row,
  index : Int,
) -> String? raise @proto.ProtocolError {
  match self.values[index] {
    None => None
    Some(value) => Some(decode_utf8(value[:]))
  }
}

///|
pub fn Row::index_of(self : Row, name : String) -> Int? {
  for index, column in self.columns {
    if column.name == name {
      return Some(index)
    }
  }
  None
}

///|
pub fn Row::get_named(self : Row, name : String) -> Bytes?? {
  match self.index_of(name) {
    None => None
    Some(index) => Some(self.values[index])
  }
}

///|
pub fn Row::get_named_text(
  self : Row,
  name : String,
) -> String?? raise @proto.ProtocolError {
  match self.index_of(name) {
    None => None
    Some(index) => Some(self.get_text(index))
  }
}

///|
pub struct QueryResult {
  columns : Array[Column]
  rows : Array[Row]
  command_tag : String
} derive(Show, Eq)

///|
pub fn QueryResult::columns(self : QueryResult) -> Array[Column] {
  self.columns
}

///|
pub fn QueryResult::rows(self : QueryResult) -> Array[Row] {
  self.rows
}

///|
pub fn QueryResult::command_tag(self : QueryResult) -> String {
  self.command_tag
}

///|
pub fn QueryResult::column_count(self : QueryResult) -> Int {
  self.columns.length()
}

///|
pub fn QueryResult::row_count(self : QueryResult) -> Int {
  self.rows.length()
}

///|
fn decode_utf8(bytes : BytesView) -> String raise @proto.ProtocolError {
  @utf8.decode(bytes) catch {
    _ => raise @proto.ProtocolError::InvalidInput("invalid UTF-8")
  }
}
