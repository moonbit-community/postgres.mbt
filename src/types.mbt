///|
/// Protocol version constants
pub const PROTOCOL_VERSION_MAJOR : Int = 3

///|
pub const PROTOCOL_VERSION_MINOR : Int = 0

///|
/// Cancel request code
pub const CANCEL_REQUEST_CODE : Int = 80877102

///|
/// SSL request code  
pub const SSL_REQUEST_CODE : Int = 80877103

///|
/// GSSAPI request code
pub const GSSAPI_ENC_REQUEST_CODE : Int = 80877104

///|
/// Authentication types
pub enum AuthenticationType {
  Ok
  KerberosV5
  CleartextPassword
  MD5Password(Bytes) // 4-byte salt
  SCMCredential
  GSS
  GSSContinue(Bytes)
  SSPI
  SASL(Array[String]) // mechanisms
  SASLContinue(Bytes)
  SASLFinal(Bytes)
} derive(Show, Eq)

///|
/// Transaction status
pub enum TransactionStatus {
  Idle // 'I' - not in a transaction block
  InTransaction // 'T' - in a transaction block  
  InFailedTransaction // 'E' - in a failed transaction block
} derive(Show, Eq)

///|
/// Message format codes
pub enum FormatCode {
  Text // 0
  Binary // 1
} derive(Show, Eq)

///|
pub fn FormatCode::to_int(self : FormatCode) -> Int {
  match self {
    Text => 0
    Binary => 1
  }
}

///|
pub fn FormatCode::from_int(value : Int) -> FormatCode raise ProtocolError {
  match value {
    0 => Text
    1 => Binary
    _ => raise ProtocolError::InvalidParameter("Invalid format code: \{value}")
  }
}

///|
/// Column information from RowDescription
pub(all) struct ColumnInfo {
  name : String
  table_oid : Int
  column_attribute_number : Int
  data_type_oid : Int
  data_type_size : Int
  type_modifier : Int
  format_code : FormatCode
} derive(Show, Eq)

///|
/// Parameter information
pub(all) struct ParameterInfo {
  data_type_oid : Int
} derive(Show, Eq)

///|
/// Notification from PostgreSQL
pub(all) struct Notification {
  process_id : Int
  channel : String
  payload : String
} derive(Show, Eq)

///|
/// Backend key data for cancellation requests
pub(all) struct BackendKeyData {
  process_id : Int
  secret_key : Int
} derive(Show, Eq)

///|
/// Error/Notice field types
pub enum ErrorFieldType {
  Severity // 'S'
  Code // 'C' 
  Message // 'M'
  Detail // 'D'
  Hint // 'H'
  Position // 'P'
  InternalPosition // 'p'
  InternalQuery // 'q'
  Where // 'W'
  SchemaName // 's'
  TableName // 't'
  ColumnName // 'c'
  DataTypeName // 'd'
  ConstraintName // 'n'
  File // 'F'
  Line // 'L'
  Routine // 'R'
  Unknown(Char)
} derive(Show, Eq)

///|
pub fn ErrorFieldType::from_char(c : Char) -> ErrorFieldType {
  match c {
    'S' => Severity
    'C' => Code
    'M' => Message
    'D' => Detail
    'H' => Hint
    'P' => Position
    'p' => InternalPosition
    'q' => InternalQuery
    'W' => Where
    's' => SchemaName
    't' => TableName
    'c' => ColumnName
    'd' => DataTypeName
    'n' => ConstraintName
    'F' => File
    'L' => Line
    'R' => Routine
    _ => Unknown(c)
  }
}

///|
pub fn ErrorFieldType::to_char(self : ErrorFieldType) -> Char {
  match self {
    Severity => 'S'
    Code => 'C'
    Message => 'M'
    Detail => 'D'
    Hint => 'H'
    Position => 'P'
    InternalPosition => 'p'
    InternalQuery => 'q'
    Where => 'W'
    SchemaName => 's'
    TableName => 't'
    ColumnName => 'c'
    DataTypeName => 'd'
    ConstraintName => 'n'
    File => 'F'
    Line => 'L'
    Routine => 'R'
    Unknown(c) => c
  }
}
