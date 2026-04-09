///|
pub enum SslMode {
  Disable
  Prefer
  Require
} derive(Debug, Eq)

///|
/// Return the `Disable` SSL mode.
pub fn SslMode::disable() -> SslMode {
  Disable
}

///|
/// Return the `Prefer` SSL mode.
pub fn SslMode::prefer() -> SslMode {
  Prefer
}

///|
/// Return the `Require` SSL mode.
pub fn SslMode::require() -> SslMode {
  Require
}

///|
pub struct Config {
  host : String
  port : Int
  user : String
  database : String
  password : String?
  ssl_mode : SslMode
  application_name : String
} derive(Debug, Eq)

///|
/// Create a client configuration.
pub fn Config::new(
  host : String,
  user~ : String,
  database? : String = user,
  password? : String,
  port? : Int = 5432,
  ssl_mode? : SslMode = Disable,
  application_name? : String = "moonbit-postgres",
) -> Config {
  { host, port, user, database, password, ssl_mode, application_name }
}

///|
pub struct DatabaseError {
  severity : String?
  code : String?
  message : String
  detail : String?
  hint : String?
} derive(Debug, Eq)

///|
pub struct WrongTypeError {
  moonbit_type : String
  postgres_type : Type
} derive(Debug, Eq)

///|
pub suberror ClientError {
  Database(DatabaseError)
  Authentication(String)
  Closed(String)
  Protocol(String)
  Ssl(String)
  Encode(String)
  Decode(String)
  WrongType(WrongTypeError)
  ColumnNotFound(String)
  RowCount(String)
  UnexpectedMessage(String)
} derive(Debug, Eq)

///|
pub enum Kind {
  Simple
  Array(@proto.Oid)
  Enum(Array[String])
  Composite(Array[Field])
  Domain(@proto.Oid)
  Range(@proto.Oid)
  Pseudo
  Unknown
} derive(Debug, Eq)

///|
pub struct Field {
  name : String
  type_oid : @proto.Oid
} derive(Debug, Eq)

///|
pub struct Type {
  oid : @proto.Oid
  name : String
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
/// Construct a placeholder descriptor for an unknown PostgreSQL type.
pub fn Type::unknown(oid : @proto.Oid, name? : String = "unknown") -> Type {
  { oid, name, kind: Kind::Unknown }
}

///|
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
fn resolve_type(oid : @proto.Oid) -> Type {
  builtin_type(oid).unwrap_or(Type::unknown(oid, name="oid_\{oid.to_string()}"))
}

///|
fn wrong_type_error(moonbit_type : String, postgres_type : Type) -> ClientError {
  ClientError::WrongType({ moonbit_type, postgres_type })
}

///|
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
fn is_bytes_type(type_ : Type) -> Bool {
  match type_.oid {
    17U | 2950U => true
    _ => false
  }
}

///|
pub(open) trait ToSql {
  format(Self, Type) -> Int = _
  accepts(Self, Type) -> Bool
  moonbit_type_name(Self) -> String
  to_sql(Self, Type, @buffer.Buffer) -> @proto.IsNull raise Error
}

///|
impl ToSql with format(_, _) {
  1
}

///|
pub(open) trait FromSql {
  from_sql(Type, Int, BytesView) -> Self raise Error
  accepts(Type) -> Bool
  moonbit_type_name() -> String
  from_sql_null(Type, Int) -> Self raise Error = _
}

///|
impl FromSql with from_sql_null(type_, _) {
  raise ClientError::Decode("unexpected NULL for type \{type_.name}")
}

///|
pub impl[T : ToSql] ToSql for T? with format(self, type_) {
  match self {
    None => 1
    Some(value) => value.format(type_)
  }
}

///|
pub impl[T : ToSql] ToSql for T? with accepts(self, type_) {
  match self {
    None => true
    Some(value) => value.accepts(type_)
  }
}

///|
pub impl[T : ToSql] ToSql for T? with moonbit_type_name(self) {
  match self {
    None => "Option"
    Some(value) => "\{value.moonbit_type_name()}?"
  }
}

///|
pub impl[T : ToSql] ToSql for T? with to_sql(self, type_, buf) {
  match self {
    None => @proto.IsNull::Yes
    Some(value) => value.to_sql(type_, buf)
  }
}

///|
pub impl[T : FromSql] FromSql for T? with from_sql(type_, format, raw) {
  let value : T = FromSql::from_sql(type_, format, raw)
  Some(value)
}

///|
pub impl[T : FromSql] FromSql for T? with accepts(type_) {
  T::accepts(type_)
}

///|
pub impl[T : FromSql] FromSql for T? with moonbit_type_name() {
  "\{T::moonbit_type_name()}?"
}

///|
pub impl[T : FromSql] FromSql for T? with from_sql_null(_, _) {
  None
}

///|
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

///|
pub struct Column {
  name : String
  table_oid : @proto.Oid
  column_id : Int
  type_ : Type
  type_size : Int
  type_modifier : Int
  format : Int
} derive(Debug, Eq)

///|
pub struct Row {
  columns : Array[Column]
  values : Array[Bytes?]
} derive(Debug, Eq)

///|
/// Return the number of values in this row.
pub fn Row::len(self : Row) -> Int {
  self.values.length()
}

///|
/// Return the index of the named column, if present.
pub fn Row::index_of(self : Row, name : String) -> Int? {
  for index, column in self.columns {
    if column.name == name {
      return Some(index)
    }
  }
  None
}

///|
/// Return the raw value bytes at `index`.
pub fn Row::get_raw(self : Row, index : Int) -> Bytes? {
  self.values[index]
}

///|
/// Return the raw value bytes for the named column.
pub fn Row::get_raw_name(self : Row, name : String) -> Bytes? raise {
  match self.index_of(name) {
    None => raise ClientError::ColumnNotFound(name)
    Some(index) => self.get_raw(index)
  }
}

///|
/// Decode the value at `index` as `T`.
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
/// Decode the value at `index` as `T`, or return `None` if out of range.
pub fn[T : FromSql] Row::try_get(self : Row, index : Int) -> T? raise {
  if index < 0 || index >= self.len() {
    return None
  }
  Some(self.get(index))
}

///|
/// Decode the named column as `T`, or return `None` if it does not exist.
pub fn[T : FromSql] Row::try_get_name(self : Row, name : String) -> T? raise {
  match self.index_of(name) {
    None => None
    Some(index) => Some(self.get(index))
  }
}

///|
/// Decode the value at `index` as text.
pub fn Row::get_text(self : Row, index : Int) -> String? raise {
  self.get(index)
}

///|
/// Decode the named column as text.
pub fn Row::get_text_name(self : Row, name : String) -> String? raise {
  self.get_name(name)
}

///|
pub struct QuerySummary {
  command_tag : String
  row_count : Int
  suspended : Bool
} derive(Debug, Eq)

///|
pub struct RowStream {
  mut columns : Array[Column]
  priv responses : @async.Queue[@backend.Message]
  priv cleanup : StreamCleanup?
  priv mut command_tag : String
  priv mut row_count : Int
  priv mut suspended : Bool
  priv mut database_error : DatabaseError?
  priv mut summary : QuerySummary?
}

///|
/// Read the next row from the stream.
pub async fn RowStream::next(self : RowStream) -> Row? {
  match self.summary {
    Some(_) => return self.raise_terminal_error_or_none()
    None => ()
  }
  for res = self.responses.get() {
    match res {
      @backend.Message::ParseComplete
      | @backend.Message::BindComplete
      | @backend.Message::CloseComplete
      | @backend.Message::ParameterDescription(_) =>
        continue self.responses.get()
      @backend.Message::NoData => continue self.responses.get()
      @backend.Message::RowDescription(body) => {
        self.columns = merge_stream_columns(self.columns, body)
        continue self.responses.get()
      }
      @backend.Message::DataRow(body) => {
        self.row_count += 1
        return Some({ columns: self.columns, values: parse_binary_values(body) })
      }
      @backend.Message::CommandComplete(body) => {
        self.command_tag = body.tag_str()
        continue self.responses.get()
      }
      @backend.Message::PortalSuspended => {
        self.suspended = true
        continue self.responses.get()
      }
      @backend.Message::ErrorResponse(body) => {
        self.database_error = Some(parse_database_error(body.fields()))
        continue self.responses.get()
      }
      @backend.Message::ReadyForQuery(_) => {
        self.summary = Some({
          command_tag: self.command_tag,
          row_count: self.row_count,
          suspended: self.suspended,
        })
        self.run_cleanup()
        return self.raise_terminal_error_or_none()
      }
      _ =>
        fail_response_stream(
          self.responses,
          ClientError::UnexpectedMessage("unexpected query response"),
        )
    }
  }
}

///|
/// Collect all remaining rows into an array.
pub async fn RowStream::collect(self : RowStream) -> Array[Row] {
  let rows : Array[Row] = []
  for row = self.next() {
    match row {
      None => break rows
      Some(row) => {
        rows.push(row)
        continue self.next()
      }
    }
  }
}

///|
/// Drain the stream and return its final query summary.
pub async fn RowStream::finish(self : RowStream) -> QuerySummary {
  for row = self.next() {
    match row {
      Some(_) => continue self.next()
      None => break self.summary.unwrap()
    }
  }
}

///|
pub struct SimpleQueryRow {
  columns : Array[String]
  values : Array[String?]
} derive(Debug, Eq)

///|
/// Return the number of values in this row.
pub fn SimpleQueryRow::len(self : SimpleQueryRow) -> Int {
  self.values.length()
}

///|
/// Return the index of the named column, if present.
pub fn SimpleQueryRow::index_of(self : SimpleQueryRow, name : String) -> Int? {
  for index, column in self.columns {
    if column == name {
      return Some(index)
    }
  }
  None
}

///|
/// Return the text value at `index`.
pub fn SimpleQueryRow::get(self : SimpleQueryRow, index : Int) -> String? {
  self.values[index]
}

///|
/// Return the text value for the named column.
pub fn SimpleQueryRow::get_name(
  self : SimpleQueryRow,
  name : String,
) -> String? raise {
  match self.index_of(name) {
    None => raise ClientError::ColumnNotFound(name)
    Some(index) => self.values[index]
  }
}

///|
pub enum SimpleQueryMessage {
  RowDescription(Array[String])
  Row(SimpleQueryRow)
  CommandComplete(String)
} derive(Debug, Eq)

///|
struct SimpleQueryStream {
  responses : @async.Queue[@backend.Message]
  mut columns : Array[String]
  mut database_error : DatabaseError?
  mut finished : Bool
}

///|
/// Read the next message from a simple-query stream.
pub async fn SimpleQueryStream::next(
  self : SimpleQueryStream,
) -> SimpleQueryMessage? {
  if self.finished {
    return self.raise_terminal_error_or_none()
  }
  for response = self.responses.get() {
    match response {
      @backend.Message::RowDescription(body) => {
        self.columns = parse_column_names(body)
        return Some(SimpleQueryMessage::RowDescription(self.columns))
      }
      @backend.Message::DataRow(body) =>
        return Some(SimpleQueryMessage::Row(parse_text_row(body, self.columns)))
      @backend.Message::CommandComplete(body) => {
        self.columns = []
        return Some(SimpleQueryMessage::CommandComplete(body.tag_str()))
      }
      @backend.Message::EmptyQueryResponse => {
        self.columns = []
        return Some(SimpleQueryMessage::CommandComplete(""))
      }
      @backend.Message::ErrorResponse(body) => {
        self.database_error = Some(parse_database_error(body.fields()))
        continue self.responses.get()
      }
      @backend.Message::ReadyForQuery(_) => {
        self.finished = true
        return self.raise_terminal_error_or_none()
      }
      _ =>
        fail_response_stream(
          self.responses,
          ClientError::UnexpectedMessage("unexpected simple query response"),
        )
    }
  }
}

///|
/// Collect all remaining simple-query messages.
pub async fn SimpleQueryStream::collect(
  self : SimpleQueryStream,
) -> Array[SimpleQueryMessage] {
  let messages : Array[SimpleQueryMessage] = []
  for msg = self.next() {
    match msg {
      None => break messages
      Some(message) => {
        messages.push(message)
        continue self.next()
      }
    }
  }
}

///|
/// Drain the simple-query stream.
pub async fn SimpleQueryStream::finish(self : SimpleQueryStream) -> Unit {
  for msg = self.next() {
    match msg {
      Some(_) => continue self.next()
      None => break ()
    }
  }
}

///|
pub struct Notification {
  process_id : Int
  channel : String
  payload : String
} derive(Debug, Eq)

///|
pub enum AsyncMessage {
  Notice(DatabaseError)
  Notification(Notification)
  ParameterStatus(String, String)
} derive(Debug, Eq)

///|
pub struct CopyOutStream {
  priv responses : @async.Queue[@backend.Message]
  formats : Array[Int]
  priv mut database_error : DatabaseError?
  priv mut finished : Bool
}

///|
/// Read the next COPY OUT data chunk.
pub async fn CopyOutStream::next(self : CopyOutStream) -> Bytes? {
  if self.finished {
    return self.raise_terminal_error_or_none()
  }
  for response = self.responses.get() {
    match response {
      @backend.Message::CopyData(body) => return Some(body.storage)
      @backend.Message::CopyDone | @backend.Message::CommandComplete(_) =>
        continue self.responses.get()
      @backend.Message::ErrorResponse(body) => {
        self.database_error = Some(parse_database_error(body.fields()))
        continue self.responses.get()
      }
      @backend.Message::ReadyForQuery(_) => {
        self.finished = true
        return self.raise_terminal_error_or_none()
      }
      _ =>
        fail_response_stream(
          self.responses,
          ClientError::UnexpectedMessage("unexpected copy out response"),
        )
    }
  }
}

///|
/// Collect all remaining COPY OUT data chunks.
pub async fn CopyOutStream::collect(self : CopyOutStream) -> Array[Bytes] {
  let chunks : Array[Bytes] = []
  for chunk = self.next() {
    match chunk {
      None => break chunks
      Some(chunk) => {
        chunks.push(chunk)
        continue self.next()
      }
    }
  }
}

///|
/// Drain the COPY OUT stream.
pub async fn CopyOutStream::finish(self : CopyOutStream) -> Unit {
  for bytes = self.next() {
    if bytes is Some(_) {
      continue self.next()
    } else {
      break ()
    }
  }
}

///|
fn parse_columns(body : @backend.RowDescriptionBody) -> Array[Column] raise {
  let columns : Array[Column] = []
  let fields = body.fields()
  for field = fields.next() {
    match field {
      None => break columns
      Some(field) => {
        columns.push({
          name: field.name_str(),
          table_oid: field.table_oid,
          column_id: field.column_id,
          type_: resolve_type(field.type_oid),
          type_size: field.type_size,
          type_modifier: field.type_modifier,
          format: field.format,
        })
        continue fields.next()
      }
    }
  }
}

///|
fn parse_binary_values(
  body : @backend.DataRowBody,
) -> Array[Bytes?] raise @proto.ProtocolError {
  let values : Array[Bytes?] = []
  let ranges = body.ranges()
  let buffer = body.buffer()
  for range = ranges.next() {
    match range {
      None => break values
      Some(None) => {
        values.push(None)
        continue ranges.next()
      }
      Some(Some(range)) => {
        values.push(Some(buffer[range.start:range.end].to_bytes()))
        continue ranges.next()
      }
    }
  }
}

///|
fn parse_text_row(
  body : @backend.DataRowBody,
  columns : Array[String],
) -> SimpleQueryRow raise @proto.ProtocolError {
  let values : Array[String?] = []
  let ranges = body.ranges()
  let buffer = body.buffer()
  for range = ranges.next() {
    match range {
      None => break { columns, values }
      Some(None) => {
        values.push(None)
        continue ranges.next()
      }
      Some(Some(range)) => {
        values.push(Some(decode_utf8(buffer[range.start:range.end])))
        continue ranges.next()
      }
    }
  }
}

///|
fn parse_column_names(
  body : @backend.RowDescriptionBody,
) -> Array[String] raise {
  let columns : Array[String] = []
  let fields = body.fields()
  for field = fields.next() {
    match field {
      None => break columns
      Some(field) => {
        columns.push(field.name_str())
        continue fields.next()
      }
    }
  }
}

///|
fn parse_copy_formats(formats : @backend.ColumnFormats) -> Array[Int] raise {
  let out : Array[Int] = []
  for format = formats.next() {
    match format {
      None => break out
      Some(format) => {
        out.push(format)
        continue formats.next()
      }
    }
  }
}

///|
fn parse_database_error(
  fields : @backend.ErrorFields,
) -> DatabaseError raise @proto.ProtocolError {
  let mut severity = None
  let mut code = None
  let mut message = None
  let mut detail = None
  let mut hint = None
  for field = fields.next() {
    match field {
      None =>
        break {
          severity,
          code,
          message: message.unwrap_or("database error"),
          detail,
          hint,
        }
      Some(field) => {
        let value = decode_utf8(field.value_bytes())
        match field.type_ {
          b'S' | b'V' => severity = Some(value)
          b'C' => code = Some(value)
          b'M' => message = Some(value)
          b'D' => detail = Some(value)
          b'H' => hint = Some(value)
          _ => ()
        }
        continue fields.next()
      }
    }
  }
}

///|
fn decode_utf8(bytes : BytesView) -> String raise @proto.ProtocolError {
  @utf8.decode(bytes) catch {
    _ => raise @proto.ProtocolError::InvalidInput("invalid UTF-8")
  }
}

///|
fn merge_stream_columns(
  current : Array[Column],
  body : @backend.RowDescriptionBody,
) -> Array[Column] raise {
  let described = parse_columns(body)
  if current.is_empty() {
    return described
  }
  guard current.length() == described.length() else {
    raise ClientError::Protocol(
      "row description column count mismatch: expected \{current.length().to_string()}, got \{described.length().to_string()}",
    )
  }
  let merged : Array[Column] = []
  for index, column in described {
    let resolved = current[index]
    guard resolved.type_.oid == column.type_.oid else {
      raise ClientError::Protocol(
        "row description type mismatch at column \{index.to_string()}: expected oid \{resolved.type_.oid.to_string()}, got \{column.type_.oid.to_string()}",
      )
    }
    merged.push({ ..column, type_: resolved.type_ })
  }
  merged
}

///|
fn[X, Y] fail_response_stream(
  responses : @async.Queue[X],
  err : Error,
) -> Y raise {
  responses.close(error=err, clear=true)
  raise err
}

///|
fn RowStream::raise_terminal_error_or_none(self : RowStream) -> Row? raise {
  match self.database_error {
    Some(err) => raise ClientError::Database(err)
    None => None
  }
}

///|
fn SimpleQueryStream::raise_terminal_error_or_none(
  self : SimpleQueryStream,
) -> SimpleQueryMessage? raise {
  match self.database_error {
    Some(err) => raise ClientError::Database(err)
    None => None
  }
}

///|
fn CopyOutStream::raise_terminal_error_or_none(
  self : CopyOutStream,
) -> Bytes? raise {
  match self.database_error {
    Some(err) => raise ClientError::Database(err)
    None => None
  }
}
