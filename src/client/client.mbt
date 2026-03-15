///|
priv enum Stream {
  Plain(@socket.Tcp)
  Secure(@tls.Tls)
}

///|
fn Stream::close(self : Stream) -> Unit {
  match self {
    Plain(conn) => conn.close()
    Secure(conn) => conn.close()
  }
}

///|
impl @io.Reader for Stream with _direct_read(self, buf, offset~, max_len~) {
  match self {
    Plain(conn) => conn._direct_read(buf, offset~, max_len~)
    Secure(conn) => conn._direct_read(buf, offset~, max_len~)
  }
}

///|
impl @io.Reader for Stream with _get_internal_buffer(self) {
  match self {
    Plain(conn) => conn._get_internal_buffer()
    Secure(conn) => conn._get_internal_buffer()
  }
}

///|
impl @io.Writer for Stream with write_once(self, buf, offset~, len~) {
  match self {
    Plain(conn) => conn.write_once(buf, offset~, len~)
    Secure(conn) => conn.write_once(buf, offset~, len~)
  }
}

///|
struct Client {
  stream : Stream
  mut process_id : Int
  mut secret_key : Int
  parameters : Map[String, String]
  mut transaction_status : Byte
  lock : @async.Semaphore
}

///|
pub fn Client::close(self : Client) -> Unit {
  self.stream.close()
}

///|
pub fn Client::process_id(self : Client) -> Int {
  self.process_id
}

///|
pub fn Client::secret_key(self : Client) -> Int {
  self.secret_key
}

///|
pub fn Client::parameter_status(self : Client, name : String) -> String? {
  self.parameters.get(name)
}

///|
pub fn Client::transaction_status(self : Client) -> Byte {
  self.transaction_status
}

///|
pub async fn Client::connect(
  host : String,
  user~ : String,
  database? : String = user,
  password? : String,
  port? : Int = 5432,
  ssl_mode? : SslMode = Disable,
  application_name? : String = "moonbit-postgres",
) -> Client {
  let stream = connect_stream(host, port, ssl_mode)
  let client = {
    stream,
    process_id: 0,
    secret_key: 0,
    parameters: {},
    transaction_status: b'I',
    lock: @async.Semaphore::new(1),
  }
  client.startup(user, database, password, application_name)
  client
}

///|
pub async fn Client::simple_query(self : Client, sql : String) -> QueryResult {
  self.lock.acquire()
  defer self.lock.release()
  let sql_bytes = @proto.utf8_encode(sql)
  let buf = @buffer.new()
  @frontend.query(sql_bytes[:], buf)
  self.stream.write(buf.to_bytes())
  self.read_query_result(expect_parse_messages=false)
}

///|
pub async fn Client::query(
  self : Client,
  sql : String,
  params? : Array[QueryParam] = [],
) -> QueryResult {
  self.lock.acquire()
  defer self.lock.release()
  let sql_bytes = @proto.utf8_encode(sql)
  let param_types : Array[@proto.Oid] = []
  let formats : Array[Int] = []
  let result_formats : Array[Int] = []
  let buf = @buffer.new()
  @frontend.parse(b""[:], sql_bytes[:], param_types.iter(), buf)
  @frontend.bind(
    b""[:],
    b""[:],
    formats.iter(),
    params.iter(),
    (param, payload) => serialize_param(param, payload),
    result_formats.iter(),
    buf,
  )
  @frontend.describe(b'P', b""[:], buf)
  @frontend.execute(b""[:], 0, buf)
  @frontend.sync(buf)
  self.stream.write(buf.to_bytes())
  self.read_query_result(expect_parse_messages=true)
}

///|
async fn Client::startup(
  self : Client,
  user : String,
  database : String,
  password : String?,
  application_name : String,
) -> Unit {
  let user_bytes = @proto.utf8_encode(user)
  let database_bytes = @proto.utf8_encode(database)
  let application_name_bytes = @proto.utf8_encode(application_name)
  let parameters : Array[(BytesView, BytesView)] = [
    (b"user"[:], user_bytes[:]),
    (b"database"[:], database_bytes[:]),
    (b"client_encoding"[:], b"UTF8"[:]),
    (b"application_name"[:], application_name_bytes[:]),
  ]
  let buf = @buffer.new()
  @frontend.startup_message(parameters.iter(), buf)
  self.stream.write(buf.to_bytes())
  let mut scram : @sasl.ScramSha256? = None
  loop self.read_message() {
    @backend.Message::AuthenticationOk => continue self.read_message()
    @backend.Message::AuthenticationCleartextPassword => {
      send_password_message(self, password)
      continue self.read_message()
    }
    @backend.Message::AuthenticationMd5Password(body) => {
      send_md5_password_message(self, user, password, body.salt())
      continue self.read_message()
    }
    @backend.Message::AuthenticationSasl(body) => {
      scram = Some(begin_scram(self, body, password))
      continue self.read_message()
    }
    @backend.Message::AuthenticationSaslContinue(body) => {
      continue_scram(self, scram, body.data())
      continue self.read_message()
    }
    @backend.Message::AuthenticationSaslFinal(body) => {
      finish_scram(scram, body.data())
      continue self.read_message()
    }
    @backend.Message::ParameterStatus(body) => {
      let name = body.name_str()
      let value = body.value_str()
      self.parameters[name] = value
      continue self.read_message()
    }
    @backend.Message::BackendKeyData(body) => {
      self.process_id = body.process_id()
      self.secret_key = body.secret_key()
      continue self.read_message()
    }
    @backend.Message::NoticeResponse(_) => continue self.read_message()
    @backend.Message::ReadyForQuery(body) =>
      self.transaction_status = body.status()
    @backend.Message::ErrorResponse(body) =>
      raise ClientError::Database(parse_database_error(body.fields()))
    @backend.Message::AuthenticationKerberosV5
    | @backend.Message::AuthenticationScmCredential
    | @backend.Message::AuthenticationGss
    | @backend.Message::AuthenticationGssContinue(_)
    | @backend.Message::AuthenticationSspi =>
      raise ClientError::Unsupported(
        "server requested an unsupported authentication method",
      )
    _ => raise ClientError::UnexpectedMessage("unexpected startup message")
  }
}

///|
async fn Client::read_query_result(
  self : Client,
  expect_parse_messages~ : Bool,
) -> QueryResult {
  let mut columns : Array[Column] = []
  let rows : Array[Row] = []
  let mut command_tag = ""
  let mut row_description_seen = false
  let mut no_data_seen = false
  let mut empty_query_seen = false
  let mut command_complete_seen = false
  let mut database_error : DatabaseError? = None
  let mut client_error : ClientError? = None
  loop self.read_message() {
    message => {
      if client_error is Some(_) {
        match message {
          @backend.Message::ParameterStatus(body) => {
            let name = body.name_str()
            let value = body.value_str()
            self.parameters[name] = value
            continue self.read_message()
          }
          @backend.Message::NoticeResponse(_)
          | @backend.Message::NotificationResponse(_) =>
            continue self.read_message()
          @backend.Message::ErrorResponse(body) => {
            database_error = Some(parse_database_error(body.fields()))
            continue self.read_message()
          }
          @backend.Message::ReadyForQuery(body) => {
            self.transaction_status = body.status()
            match database_error {
              Some(err) => raise ClientError::Database(err)
              None =>
                match client_error {
                  Some(err) => raise err
                  None => panic()
                }
            }
          }
          _ => continue self.read_message()
        }
      }
      match message {
        @backend.Message::ParseComplete => {
          guard expect_parse_messages else {
            client_error = Some(
              ClientError::UnexpectedMessage("unexpected ParseComplete"),
            )
            continue self.read_message()
          }
          continue self.read_message()
        }
        @backend.Message::BindComplete => {
          guard expect_parse_messages else {
            client_error = Some(
              ClientError::UnexpectedMessage("unexpected BindComplete"),
            )
            continue self.read_message()
          }
          continue self.read_message()
        }
        @backend.Message::ParameterStatus(body) => {
          let name = body.name_str()
          let value = body.value_str()
          self.parameters[name] = value
          continue self.read_message()
        }
        @backend.Message::NoticeResponse(_)
        | @backend.Message::NotificationResponse(_) =>
          continue self.read_message()
        @backend.Message::NoData => {
          guard not(row_description_seen) &&
            not(no_data_seen) &&
            not(empty_query_seen) else {
            client_error = Some(
              ClientError::Unsupported(
                "multiple result sets are not supported yet",
              ),
            )
            continue self.read_message()
          }
          no_data_seen = true
          continue self.read_message()
        }
        @backend.Message::EmptyQueryResponse => {
          guard not(row_description_seen) &&
            not(no_data_seen) &&
            not(empty_query_seen) &&
            not(command_complete_seen) else {
            client_error = Some(
              ClientError::Unsupported(
                "multiple result sets are not supported yet",
              ),
            )
            continue self.read_message()
          }
          empty_query_seen = true
          continue self.read_message()
        }
        @backend.Message::RowDescription(body) => {
          guard not(row_description_seen) &&
            not(no_data_seen) &&
            not(empty_query_seen) else {
            client_error = Some(
              ClientError::Unsupported(
                "multiple result sets are not supported yet",
              ),
            )
            continue self.read_message()
          }
          row_description_seen = true
          columns = parse_columns(body)
          continue self.read_message()
        }
        @backend.Message::DataRow(body) => {
          guard row_description_seen else {
            client_error = Some(
              ClientError::UnexpectedMessage(
                "received DataRow before RowDescription",
              ),
            )
            continue self.read_message()
          }
          rows.push(parse_row(body, columns))
          continue self.read_message()
        }
        @backend.Message::CommandComplete(body) => {
          guard not(command_complete_seen) && not(empty_query_seen) else {
            client_error = Some(
              ClientError::Unsupported(
                "multiple result sets are not supported yet",
              ),
            )
            continue self.read_message()
          }
          command_complete_seen = true
          command_tag = body.tag_str()
          continue self.read_message()
        }
        @backend.Message::ErrorResponse(body) => {
          database_error = Some(parse_database_error(body.fields()))
          continue self.read_message()
        }
        @backend.Message::ReadyForQuery(body) => {
          self.transaction_status = body.status()
          match database_error {
            Some(err) => raise ClientError::Database(err)
            None => return { columns, rows, command_tag }
          }
        }
        @backend.Message::PortalSuspended => {
          client_error = Some(
            ClientError::Unsupported("portal suspension is not supported"),
          )
          continue self.read_message()
        }
        @backend.Message::CopyInResponse(_)
        | @backend.Message::CopyOutResponse(_)
        | @backend.Message::CopyData(_)
        | @backend.Message::CopyDone => {
          client_error = Some(ClientError::Unsupported("COPY is not supported"))
          continue self.read_message()
        }
        _ => {
          client_error = Some(
            ClientError::UnexpectedMessage("unexpected query message"),
          )
          continue self.read_message()
        }
      }
    }
  }
}

///|
async fn Client::read_message(self : Client) -> @backend.Message {
  let header = self.stream.read_exactly(5)
  let body_len = @proto.ByteReader::new(header[1:]).read_i32_be()
  let body = self.stream.read_exactly(body_len - 4)
  let packet = @buffer.new(size_hint=header.length() + body.length())
  packet.write_bytes(header)
  packet.write_bytes(body)
  match @backend.Message::parse(packet.to_bytes()[:]) {
    Some(parsed) => parsed.message()
    None => raise ClientError::UnexpectedMessage("incomplete backend message")
  }
}

///|
async fn connect_stream(
  host : String,
  port : Int,
  ssl_mode : SslMode,
) -> Stream {
  let conn = @socket.Tcp::connect_to_host(host, port~)
  match ssl_mode {
    Disable => Plain(conn)
    Prefer | Require => {
      let request = @buffer.new()
      @frontend.ssl_request(request)
      conn.write(request.to_bytes())
      let response = conn.read_exactly(1)
      match response[0] {
        b'S' => {
          let tls = @tls.Tls::client(conn, host~) catch {
            err => {
              conn.close()
              raise ClientError::Ssl(err.to_string())
            }
          }
          Secure(tls)
        }
        b'N' =>
          if ssl_mode is Require {
            conn.close()
            raise ClientError::Ssl("server does not support TLS")
          } else {
            Plain(conn)
          }
        _ => {
          conn.close()
          raise ClientError::Ssl("invalid SSL negotiation response")
        }
      }
    }
  }
}

///|
async fn send_password_message(client : Client, password : String?) -> Unit {
  let password = require_password(password)
  let password_bytes = @proto.utf8_encode(password)
  let buf = @buffer.new()
  @frontend.password_message(password_bytes[:], buf)
  client.stream.write(buf.to_bytes())
}

///|
async fn send_md5_password_message(
  client : Client,
  user : String,
  password : String?,
  salt : BytesView,
) -> Unit {
  let password = require_password(password)
  let user_bytes = @proto.utf8_encode(user)
  let password_bytes = @proto.utf8_encode(password)
  let digest = @auth.md5_hash(user_bytes[:], password_bytes[:], salt)
  let buf = @buffer.new()
  @frontend.password_message(digest[:], buf)
  client.stream.write(buf.to_bytes())
}

///|
async fn begin_scram(
  client : Client,
  body : @backend.AuthenticationSaslBody,
  password : String?,
) -> @sasl.ScramSha256 {
  guard supports_scram(body) else {
    raise ClientError::Unsupported(
      "server does not offer SCRAM-SHA-256 authentication",
    )
  }
  let password = require_password(password)
  let password_bytes = @proto.utf8_encode(password)
  let nonce = @tls.rand_bytes(18)
  let scram = @sasl.ScramSha256::new(
    password_bytes[:],
    @sasl.ChannelBinding::unsupported(),
    nonce[:],
  )
  let buf = @buffer.new()
  @frontend.sasl_initial_response(@sasl.SCRAM_SHA_256[:], scram.message(), buf)
  client.stream.write(buf.to_bytes())
  scram
}

///|
async fn continue_scram(
  client : Client,
  scram : @sasl.ScramSha256?,
  data : BytesView,
) -> Unit {
  let scram = require_scram(scram)
  scram.update(data)
  let buf = @buffer.new()
  @frontend.sasl_response(scram.message(), buf)
  client.stream.write(buf.to_bytes())
}

///|
fn finish_scram(scram : @sasl.ScramSha256?, data : BytesView) -> Unit raise {
  require_scram(scram).finish(data)
}

///|
fn require_password(password : String?) -> String raise {
  match password {
    Some(password) => password
    None => raise ClientError::Authentication("server requires a password")
  }
}

///|
fn require_scram(scram : @sasl.ScramSha256?) -> @sasl.ScramSha256 raise {
  match scram {
    Some(scram) => scram
    None =>
      raise ClientError::UnexpectedMessage(
        "received SCRAM continuation without an active SCRAM exchange",
      )
  }
}

///|
fn supports_scram(body : @backend.AuthenticationSaslBody) -> Bool raise {
  let mechanisms = body.mechanisms()
  loop mechanisms.next() {
    None => false
    Some(mechanism) =>
      if mechanism == @sasl.SCRAM_SHA_256 {
        true
      } else {
        continue mechanisms.next()
      }
  }
}

///|
fn serialize_param(param : QueryParam, buf : @buffer.Buffer) -> @proto.IsNull {
  match param.value() {
    None => @proto.IsNull::Yes
    Some(value) => {
      buf.write_bytes(value)
      @proto.IsNull::No
    }
  }
}

///|
fn parse_columns(
  body : @backend.RowDescriptionBody,
) -> Array[Column] raise @proto.ProtocolError {
  let columns : Array[Column] = []
  let fields = body.fields()
  loop fields.next() {
    None => columns
    Some(field) => {
      columns.push({
        name: field.name_str(),
        table_oid: field.table_oid(),
        column_id: field.column_id(),
        type_oid: field.type_oid(),
        type_size: field.type_size(),
        type_modifier: field.type_modifier(),
        format: field.format(),
      })
      continue fields.next()
    }
  }
}

///|
fn parse_row(
  body : @backend.DataRowBody,
  columns : Array[Column],
) -> Row raise @proto.ProtocolError {
  let values : Array[Bytes?] = []
  let ranges = body.ranges()
  let buffer = body.buffer()
  loop ranges.next() {
    None => { columns, values }
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
