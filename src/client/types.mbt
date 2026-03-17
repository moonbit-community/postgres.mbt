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
pub struct Config {
  host : String
  port : Int
  user : String
  database : String
  password : String?
  ssl_mode : SslMode
  application_name : String
} derive(Show, Eq)

///|
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
pub fn Config::host(self : Config) -> String {
  self.host
}

///|
pub fn Config::port(self : Config) -> Int {
  self.port
}

///|
pub fn Config::user(self : Config) -> String {
  self.user
}

///|
pub fn Config::database(self : Config) -> String {
  self.database
}

///|
pub fn Config::password(self : Config) -> String? {
  self.password
}

///|
pub fn Config::ssl_mode(self : Config) -> SslMode {
  self.ssl_mode
}

///|
pub fn Config::application_name(self : Config) -> String {
  self.application_name
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
  Closed(String)
  Protocol(String)
  Ssl(String)
  Encode(String)
  Decode(String)
  WrongType(String)
  ColumnNotFound(String)
  RowCount(String)
  UnexpectedMessage(String)
} derive(Show, Eq)

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
} derive(Show, Eq)

///|
pub struct Field {
  name : String
  type_oid : @proto.Oid
} derive(Show, Eq)

///|
pub fn Field::name(self : Field) -> String {
  self.name
}

///|
pub fn Field::type_oid(self : Field) -> @proto.Oid {
  self.type_oid
}

///|
pub struct Type {
  oid : @proto.Oid
  name : String
  kind : Kind
} derive(Show, Eq)

///|
pub fn Type::oid(self : Type) -> @proto.Oid {
  self.oid
}

///|
pub fn Type::name(self : Type) -> String {
  self.name
}

///|
pub fn Type::kind(self : Type) -> Kind {
  self.kind
}

///|
pub fn Type::bool() -> Type {
  { oid: 16U, name: "bool", kind: Kind::Simple }
}

///|
pub fn Type::bytea() -> Type {
  { oid: 17U, name: "bytea", kind: Kind::Simple }
}

///|
pub fn Type::char() -> Type {
  { oid: 18U, name: "char", kind: Kind::Simple }
}

///|
pub fn Type::name_type() -> Type {
  { oid: 19U, name: "name", kind: Kind::Simple }
}

///|
pub fn Type::int8() -> Type {
  { oid: 20U, name: "int8", kind: Kind::Simple }
}

///|
pub fn Type::int2() -> Type {
  { oid: 21U, name: "int2", kind: Kind::Simple }
}

///|
pub fn Type::int4() -> Type {
  { oid: 23U, name: "int4", kind: Kind::Simple }
}

///|
pub fn Type::text() -> Type {
  { oid: 25U, name: "text", kind: Kind::Simple }
}

///|
pub fn Type::oid_type() -> Type {
  { oid: 26U, name: "oid", kind: Kind::Simple }
}

///|
pub fn Type::float4() -> Type {
  { oid: 700U, name: "float4", kind: Kind::Simple }
}

///|
pub fn Type::float8() -> Type {
  { oid: 701U, name: "float8", kind: Kind::Simple }
}

///|
pub fn Type::varchar() -> Type {
  { oid: 1043U, name: "varchar", kind: Kind::Simple }
}

///|
pub fn Type::date() -> Type {
  { oid: 1082U, name: "date", kind: Kind::Simple }
}

///|
pub fn Type::time() -> Type {
  { oid: 1083U, name: "time", kind: Kind::Simple }
}

///|
pub fn Type::timestamp() -> Type {
  { oid: 1114U, name: "timestamp", kind: Kind::Simple }
}

///|
pub fn Type::timestamptz() -> Type {
  { oid: 1184U, name: "timestamptz", kind: Kind::Simple }
}

///|
pub fn Type::uuid() -> Type {
  { oid: 2950U, name: "uuid", kind: Kind::Simple }
}

///|
pub fn Type::json() -> Type {
  { oid: 114U, name: "json", kind: Kind::Simple }
}

///|
pub fn Type::jsonb() -> Type {
  { oid: 3802U, name: "jsonb", kind: Kind::Simple }
}

///|
pub fn Type::bool_array() -> Type {
  { oid: 1000U, name: "_bool", kind: Kind::Array(16U) }
}

///|
pub fn Type::bytea_array() -> Type {
  { oid: 1001U, name: "_bytea", kind: Kind::Array(17U) }
}

///|
pub fn Type::int2_array() -> Type {
  { oid: 1005U, name: "_int2", kind: Kind::Array(21U) }
}

///|
pub fn Type::int4_array() -> Type {
  { oid: 1007U, name: "_int4", kind: Kind::Array(23U) }
}

///|
pub fn Type::text_array() -> Type {
  { oid: 1009U, name: "_text", kind: Kind::Array(25U) }
}

///|
pub fn Type::varchar_array() -> Type {
  { oid: 1015U, name: "_varchar", kind: Kind::Array(1043U) }
}

///|
pub fn Type::int8_array() -> Type {
  { oid: 1016U, name: "_int8", kind: Kind::Array(20U) }
}

///|
pub fn Type::float4_array() -> Type {
  { oid: 1021U, name: "_float4", kind: Kind::Array(700U) }
}

///|
pub fn Type::float8_array() -> Type {
  { oid: 1022U, name: "_float8", kind: Kind::Array(701U) }
}

///|
pub fn Type::timestamp_array() -> Type {
  { oid: 1115U, name: "_timestamp", kind: Kind::Array(1114U) }
}

///|
pub fn Type::date_array() -> Type {
  { oid: 1182U, name: "_date", kind: Kind::Array(1082U) }
}

///|
pub fn Type::uuid_array() -> Type {
  { oid: 2951U, name: "_uuid", kind: Kind::Array(2950U) }
}

///|
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
pub(open) trait ToSql {
  format(Self, Type) -> Int = _
  to_sql(Self, Type, @buffer.Buffer) -> @proto.IsNull raise Error
}

///|
impl ToSql with format(_, _) {
  1
}

///|
pub(open) trait FromSql {
  from_sql(Type, Int, BytesView) -> Self raise Error
  from_sql_null(Type, Int) -> Self raise Error = _
}

///|
impl FromSql with from_sql_null(type_, _) {
  raise ClientError::Decode("unexpected NULL for type \{type_.name()}")
}

///|
pub impl[T : ToSql] ToSql for T? with format(self, type_) {
  match self {
    None => 1
    Some(value) => value.format(type_)
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
pub impl[T : FromSql] FromSql for T? with from_sql_null(_, _) {
  None
}

///|
pub impl ToSql for Bool with to_sql(self, _, buf) {
  @types.bool_to_sql(self, buf)
  @proto.IsNull::No
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
  match type_.oid() {
    21U => @types.int2_to_sql(self, buf)
    23U => @types.int4_to_sql(self, buf)
    _ => raise ClientError::Encode("cannot encode Int for type \{type_.name()}")
  }
  @proto.IsNull::No
}

///|
pub impl FromSql for Int with from_sql(type_, format, raw) {
  match format {
    0 => @strconv.parse_int(decode_utf8(raw))
    1 =>
      match type_.oid() {
        21U => @types.int2_from_sql(raw)
        23U => @types.int4_from_sql(raw)
        _ => raise ClientError::Decode("cannot decode Int from \{type_.name()}")
      }
    _ => raise ClientError::Decode("unsupported format code for int")
  }
}

///|
pub impl ToSql for Int64 with to_sql(self, _, buf) {
  @types.int8_to_sql(self, buf)
  @proto.IsNull::No
}

///|
pub impl FromSql for Int64 with from_sql(_, format, raw) {
  match format {
    0 => @strconv.parse_int64(decode_utf8(raw))
    1 => @types.int8_from_sql(raw)
    _ => raise ClientError::Decode("unsupported format code for int8")
  }
}

///|
pub impl ToSql for Float with to_sql(self, _, buf) {
  @types.float4_to_sql(self, buf)
  @proto.IsNull::No
}

///|
pub impl FromSql for Float with from_sql(_, format, raw) {
  match format {
    0 => Float::from_double(@strconv.parse_double(decode_utf8(raw)))
    1 => @types.float4_from_sql(raw)
    _ => raise ClientError::Decode("unsupported format code for float4")
  }
}

///|
pub impl ToSql for Double with to_sql(self, _, buf) {
  @types.float8_to_sql(self, buf)
  @proto.IsNull::No
}

///|
pub impl FromSql for Double with from_sql(_, format, raw) {
  match format {
    0 => @strconv.parse_double(decode_utf8(raw))
    1 => @types.float8_from_sql(raw)
    _ => raise ClientError::Decode("unsupported format code for float8")
  }
}

///|
pub impl ToSql for UInt with to_sql(self, _, buf) {
  @types.oid_to_sql(self, buf)
  @proto.IsNull::No
}

///|
pub impl FromSql for UInt with from_sql(_, format, raw) {
  match format {
    0 => @strconv.parse_uint(decode_utf8(raw))
    1 => @types.oid_from_sql(raw)
    _ => raise ClientError::Decode("unsupported format code for oid")
  }
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
pub impl FromSql for String with from_sql(_, _, raw) {
  decode_utf8(raw)
}

///|
pub impl ToSql for Bytes with to_sql(self, type_, buf) {
  match type_.oid() {
    17U => @types.bytea_to_sql(self[:], buf)
    2950U => @types.uuid_to_sql(self[:], buf)
    _ =>
      raise ClientError::Encode("cannot encode bytes for type \{type_.name()}")
  }
  @proto.IsNull::No
}

///|
pub impl FromSql for Bytes with from_sql(type_, format, raw) {
  match format {
    0 =>
      if type_.oid() == 17U {
        raw.to_bytes()
      } else {
        @proto.utf8_encode(decode_utf8(raw))
      }
    1 =>
      match type_.oid() {
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
pub fn Column::type_(self : Column) -> Type {
  self.type_
}

///|
pub fn Column::type_oid(self : Column) -> @proto.Oid {
  self.type_.oid()
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
pub fn Row::len(self : Row) -> Int {
  self.values.length()
}

///|
pub fn Row::index_of(self : Row, name : String) -> Int? {
  for index, column in self.columns {
    if column.name() == name {
      return Some(index)
    }
  }
  None
}

///|
pub fn Row::get_raw(self : Row, index : Int) -> Bytes? {
  self.values[index]
}

///|
pub fn Row::get_raw_name(self : Row, name : String) -> Bytes? raise {
  match self.index_of(name) {
    None => raise ClientError::ColumnNotFound(name)
    Some(index) => self.get_raw(index)
  }
}

///|
pub fn[T : FromSql] Row::get(self : Row, index : Int) -> T raise {
  let column = self.columns[index]
  match self.values[index] {
    None => FromSql::from_sql_null(column.type_(), column.format())
    Some(value) => FromSql::from_sql(column.type_(), column.format(), value[:])
  }
}

///|
pub fn[T : FromSql] Row::get_name(self : Row, name : String) -> T raise {
  match self.index_of(name) {
    None => raise ClientError::ColumnNotFound(name)
    Some(index) => self.get(index)
  }
}

///|
pub fn[T : FromSql] Row::try_get(self : Row, index : Int) -> T? raise {
  if index < 0 || index >= self.len() {
    return None
  }
  Some(self.get(index))
}

///|
pub fn[T : FromSql] Row::try_get_name(self : Row, name : String) -> T? raise {
  match self.index_of(name) {
    None => None
    Some(index) => Some(self.get(index))
  }
}

///|
pub fn Row::get_text(self : Row, index : Int) -> String? raise {
  self.get(index)
}

///|
pub fn Row::get_text_name(self : Row, name : String) -> String? raise {
  self.get_name(name)
}

///|
struct QuerySummary {
  command_tag : String
  row_count : Int
  suspended : Bool
} derive(Show, Eq)

///|
pub fn QuerySummary::command_tag(self : QuerySummary) -> String {
  self.command_tag
}

///|
pub fn QuerySummary::row_count(self : QuerySummary) -> Int {
  self.row_count
}

///|
pub fn QuerySummary::suspended(self : QuerySummary) -> Bool {
  self.suspended
}

///|
struct RowStream {
  mut columns : Array[Column]
  responses : @async.Queue[@backend.Message]
  cleanup : StreamCleanup?
  mut command_tag : String
  mut row_count : Int
  mut suspended : Bool
  mut database_error : DatabaseError?
  mut summary : QuerySummary?
}

///|
pub fn RowStream::columns(self : RowStream) -> Array[Column] {
  self.columns
}

///|
pub async fn RowStream::next(self : RowStream) -> Row? {
  match self.summary {
    Some(_) => return self.raise_terminal_error_or_none()
    None => ()
  }
  loop self.responses.get() {
    @backend.Message::ParseComplete
    | @backend.Message::BindComplete
    | @backend.Message::CloseComplete
    | @backend.Message::ParameterDescription(_) => continue self.responses.get()
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

///|
pub async fn RowStream::collect(self : RowStream) -> Array[Row] {
  let rows : Array[Row] = []
  loop self.next() {
    None => rows
    Some(row) => {
      rows.push(row)
      continue self.next()
    }
  }
}

///|
pub async fn RowStream::finish(self : RowStream) -> QuerySummary {
  loop self.next() {
    Some(_) => continue self.next()
    None => self.summary.unwrap()
  }
}

///|
pub struct SimpleQueryRow {
  columns : Array[String]
  values : Array[String?]
} derive(Show, Eq)

///|
pub fn SimpleQueryRow::columns(self : SimpleQueryRow) -> Array[String] {
  self.columns
}

///|
pub fn SimpleQueryRow::len(self : SimpleQueryRow) -> Int {
  self.values.length()
}

///|
pub fn SimpleQueryRow::index_of(self : SimpleQueryRow, name : String) -> Int? {
  for index, column in self.columns {
    if column == name {
      return Some(index)
    }
  }
  None
}

///|
pub fn SimpleQueryRow::get(self : SimpleQueryRow, index : Int) -> String? {
  self.values[index]
}

///|
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
} derive(Show, Eq)

///|
struct SimpleQueryStream {
  responses : @async.Queue[@backend.Message]
  mut columns : Array[String]
  mut database_error : DatabaseError?
  mut finished : Bool
}

///|
pub async fn SimpleQueryStream::next(
  self : SimpleQueryStream,
) -> SimpleQueryMessage? {
  if self.finished {
    return self.raise_terminal_error_or_none()
  }
  loop self.responses.get() {
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

///|
pub async fn SimpleQueryStream::collect(
  self : SimpleQueryStream,
) -> Array[SimpleQueryMessage] {
  let messages : Array[SimpleQueryMessage] = []
  loop self.next() {
    None => messages
    Some(message) => {
      messages.push(message)
      continue self.next()
    }
  }
}

///|
pub async fn SimpleQueryStream::finish(self : SimpleQueryStream) -> Unit {
  loop self.next() {
    Some(_) => continue self.next()
    None => ()
  }
}

///|
pub struct Notification {
  process_id : Int
  channel : String
  payload : String
} derive(Show, Eq)

///|
pub fn Notification::process_id(self : Notification) -> Int {
  self.process_id
}

///|
pub fn Notification::channel(self : Notification) -> String {
  self.channel
}

///|
pub fn Notification::payload(self : Notification) -> String {
  self.payload
}

///|
pub enum AsyncMessage {
  Notice(DatabaseError)
  Notification(Notification)
  ParameterStatus(String, String)
} derive(Show, Eq)

///|
struct CopyOutStream {
  responses : @async.Queue[@backend.Message]
  formats : Array[Int]
  mut database_error : DatabaseError?
  mut finished : Bool
}

///|
pub fn CopyOutStream::column_formats(self : CopyOutStream) -> Array[Int] {
  self.formats
}

///|
pub async fn CopyOutStream::next(self : CopyOutStream) -> Bytes? {
  if self.finished {
    return self.raise_terminal_error_or_none()
  }
  loop self.responses.get() {
    @backend.Message::CopyData(body) => return Some(body.into_bytes())
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

///|
pub async fn CopyOutStream::collect(self : CopyOutStream) -> Array[Bytes] {
  let chunks : Array[Bytes] = []
  loop self.next() {
    None => chunks
    Some(chunk) => {
      chunks.push(chunk)
      continue self.next()
    }
  }
}

///|
pub async fn CopyOutStream::finish(self : CopyOutStream) -> Unit {
  loop self.next() {
    Some(_) => continue self.next()
    None => ()
  }
}

///|
fn parse_columns(body : @backend.RowDescriptionBody) -> Array[Column] raise {
  let columns : Array[Column] = []
  let fields = body.fields()
  loop fields.next() {
    None => columns
    Some(field) => {
      columns.push({
        name: field.name_str(),
        table_oid: field.table_oid(),
        column_id: field.column_id(),
        type_: resolve_type(field.type_oid()),
        type_size: field.type_size(),
        type_modifier: field.type_modifier(),
        format: field.format(),
      })
      continue fields.next()
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
  loop ranges.next() {
    None => values
    Some(None) => {
      values.push(None)
      continue ranges.next()
    }
    Some(Some(range)) => {
      values.push(Some(buffer[range.start():range.end()].to_bytes()))
      continue ranges.next()
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
  loop ranges.next() {
    None => { columns, values }
    Some(None) => {
      values.push(None)
      continue ranges.next()
    }
    Some(Some(range)) => {
      values.push(Some(decode_utf8(buffer[range.start():range.end()])))
      continue ranges.next()
    }
  }
}

///|
fn parse_column_names(
  body : @backend.RowDescriptionBody,
) -> Array[String] raise {
  let columns : Array[String] = []
  let fields = body.fields()
  loop fields.next() {
    None => columns
    Some(field) => {
      columns.push(field.name_str())
      continue fields.next()
    }
  }
}

///|
fn parse_copy_formats(formats : @backend.ColumnFormats) -> Array[Int] raise {
  let out : Array[Int] = []
  loop formats.next() {
    None => out
    Some(format) => {
      out.push(format)
      continue formats.next()
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
  loop fields.next() {
    None =>
      {
        severity,
        code,
        message: message.unwrap_or("database error"),
        detail,
        hint,
      }
    Some(field) => {
      let value = decode_utf8(field.value_bytes())
      match field.type_() {
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
    guard resolved.type_oid() == column.type_oid() else {
      raise ClientError::Protocol(
        "row description type mismatch at column \{index.to_string()}: expected oid \{resolved.type_oid().to_string()}, got \{column.type_oid().to_string()}",
      )
    }
    merged.push({ ..column, type_: resolved.type_() })
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
