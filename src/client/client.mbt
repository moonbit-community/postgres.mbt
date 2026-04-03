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
priv enum RequestKind {
  Messages
  CopyIn
  Terminate
}

///|
priv enum CopyInAction {
  Data(Bytes)
  Finish
  Fail(String)
}

///|
/// A small bounded per-request buffer keeps lightweight pipelining working
/// while preventing unread streams from accumulating responses without bound.
let request_response_queue_kind : @aqueue.Kind = Blocking(8)

///|
priv struct Request {
  kind : RequestKind
  bytes : Bytes
  responses : @async.Queue[@backend.Message]
  copy_input : @async.Queue[CopyInAction]?
}

///|
priv struct Shared {
  config : Config
  requests : @async.Queue[Request]
  async_messages : @async.Queue[AsyncMessage]
  parameters : Map[String, String]
  types : Map[@proto.Oid, Type]
  process_id : @ref.Ref[Int]
  secret_key : @ref.Ref[Int]
  transaction_status : @ref.Ref[Byte]
  closed : @ref.Ref[Bool]
  closing : @ref.Ref[Bool]
  next_id : @ref.Ref[Int]
}

///|
struct Client {
  shared : Shared
}

///|
priv struct StreamCleanup {
  client : Client
  bytes : Bytes
  mut done : Bool
}

///|
struct Connection {
  shared : Shared
  stream : Stream
}

///|
pub struct Statement {
  priv client : Client
  priv name : Bytes
  params : Array[Type]
  columns : Array[Column]
  priv closed : @ref.Ref[Bool]
}

///|
pub struct Portal {
  priv client : Client
  priv name : Bytes
  columns : Array[Column]
  priv closed : @ref.Ref[Bool]
}

///|
struct CancelToken {
  config : Config
  process_id : @ref.Ref[Int]
  secret_key : @ref.Ref[Int]
  closed : @ref.Ref[Bool]
}

///|
struct CopyInSink {
  input : @async.Queue[CopyInAction]
  responses : @async.Queue[@backend.Message]
  finished : @ref.Ref[Bool]
}

///|
struct Transaction {
  client : Client
  savepoint : String?
  finished : @ref.Ref[Bool]
}

///|
struct TransactionBuilder {
  client : Client
  isolation_level : String?
  read_only : Bool?
  deferrable : Bool?
}

///|
/// Open a PostgreSQL connection and return the client handle plus its connection task.
pub async fn connect(config : Config) -> (Client, Connection) {
  let stream = connect_stream(config)
  let startup = startup(stream, config)
  let types : Map[@proto.Oid, Type] = {}
  seed_builtin_types(types)
  let shared = {
    config,
    requests: @async.Queue::new(kind=Unbounded),
    async_messages: @async.Queue::new(kind=Unbounded),
    parameters: startup.parameters,
    types,
    process_id: @ref.new(startup.process_id),
    secret_key: @ref.new(startup.secret_key),
    transaction_status: @ref.new(startup.transaction_status),
    closed: @ref.new(false),
    closing: @ref.new(false),
    next_id: @ref.new(0),
  }
  ({ shared, }, { shared, stream })
}

///|
/// Return whether the client runtime has already closed.
pub fn Client::is_closed(self : Client) -> Bool {
  self.shared.closed.val
}

///|
/// Request a graceful shutdown of the client and connection loop.
pub fn Client::close(self : Client) -> Unit {
  if self.shared.closed.val || self.shared.closing.val {
    return
  }
  self.shared.closing.val = true
  let responses = @async.Queue::new(kind=Unbounded)
  try
    self.shared.requests.try_put({
      kind: RequestKind::Terminate,
      bytes: terminate_bytes(),
      responses,
      copy_input: None,
    })
  catch {
    _ => {
      self.shared.closed.val = true
      responses.close()
    }
  } noraise {
    _ => ()
  }
}

///|
/// Create a token that can cancel the current backend operation.
pub fn Client::cancel_token(self : Client) -> CancelToken {
  {
    config: self.shared.config,
    process_id: self.shared.process_id,
    secret_key: self.shared.secret_key,
    closed: self.shared.closed,
  }
}

///|
/// Return the backend process ID used for cancellation.
pub fn CancelToken::process_id(self : CancelToken) -> Int {
  self.process_id.val
}

///|
/// Return the backend secret key used for cancellation.
pub fn CancelToken::secret_key(self : CancelToken) -> Int {
  self.secret_key.val
}

///|
/// Reset the cached type metadata to the built-in PostgreSQL types.
pub fn Client::clear_type_cache(self : Client) -> Unit {
  self.shared.types.clear()
  seed_builtin_types(self.shared.types)
}

///|
/// Look up a server parameter by name.
pub fn Client::parameter(self : Client, name : String) -> String? {
  self.shared.parameters.get(name)
}

///|
/// Perform a round trip to verify that the connection is still usable.
pub async fn Client::check_connection(self : Client) -> Unit {
  ensure_open(self.shared)
  let responses = self.send_request(RequestKind::Messages, sync_bytes())
  drain_sync_response(responses)
}

///|
/// Execute a SQL string with the simple query protocol.
pub fn Client::simple_query(
  self : Client,
  sql : String,
) -> SimpleQueryStream raise {
  ensure_open(self.shared)
  let responses = self.send_request(
    RequestKind::Messages,
    simple_query_bytes(sql),
  )
  new_simple_query_stream(responses)
}

///|
/// Execute one or more SQL commands and discard any returned rows.
pub async fn Client::batch_execute(self : Client, sql : String) -> Unit {
  ensure_open(self.shared)
  let responses = self.send_request(
    RequestKind::Messages,
    simple_query_bytes(sql),
  )
  drain_simple_query(responses)
}

///|
/// Prepare a statement and let the server infer its parameter types.
pub async fn Client::prepare(self : Client, sql : String) -> Statement {
  self.prepare_typed(sql, [])
}

///|
/// Prepare a statement with explicit parameter types.
pub async fn Client::prepare_typed(
  self : Client,
  sql : String,
  types : Array[Type],
) -> Statement {
  ensure_open(self.shared)
  let name = next_name(self.shared, "s")
  let bytes = prepare_bytes(name[:], sql, types)
  let responses = self.send_request(RequestKind::Messages, bytes)
  let (params, columns) = read_prepare_response(self.shared, responses)
  { client: self, name, params, columns, closed: @ref.new(false) }
}

///|
/// Close the prepared statement on the server.
pub async fn Statement::close(self : Statement) -> Unit {
  if self.closed.val {
    return
  }
  let responses = self.client.send_request(
    RequestKind::Messages,
    close_bytes(b'S', self.name[:]),
  )
  drain_close_response(responses)
  self.closed.val = true
}

///|
/// Prepare and execute a query, returning its rows as a stream.
pub async fn Client::query(
  self : Client,
  sql : String,
  params? : Array[&ToSql] = [],
) -> RowStream {
  ensure_open(self.shared)
  let name = next_name(self.shared, "q")
  let prepare_responses = self.send_request(
    RequestKind::Messages,
    prepare_bytes(name[:], sql, []),
  )
  let (param_types, columns) = read_prepare_response(
    self.shared,
    prepare_responses,
  )
  guard param_types.length() == params.length() else {
    let _ = close_temporary_statement(self, name) catch { _ => () }
    raise ClientError::Encode(
      "parameter count mismatch: expected \{param_types.length().to_string()}, got \{params.length().to_string()}",
    )
  }
  let responses = self.send_request(
    RequestKind::Messages,
    execute_statement_bytes(name[:], param_types, params),
  )
  new_row_stream(
    responses,
    initial_columns=columns,
    cleanup=Some(make_statement_cleanup(self, name)),
  )
}

///|
/// Execute a query and require exactly one row.
pub async fn Client::query_one(
  self : Client,
  sql : String,
  params? : Array[&ToSql] = [],
) -> Row {
  let stream = self.query(sql, params~)
  let first = stream.next()
  let summary = stream.finish()
  match first {
    Some(row) =>
      if summary.row_count == 1 {
        row
      } else {
        raise ClientError::RowCount(
          "expected exactly one row, got \{summary.row_count.to_string()}",
        )
      }
    None =>
      raise ClientError::RowCount(
        "expected exactly one row, got \{summary.row_count.to_string()}",
      )
  }
}

///|
/// Execute a query and require at most one row.
pub async fn Client::query_opt(
  self : Client,
  sql : String,
  params? : Array[&ToSql] = [],
) -> Row? {
  let stream = self.query(sql, params~)
  let first = stream.next()
  let summary = stream.finish()
  guard summary.row_count <= 1 else {
    raise ClientError::RowCount(
      "expected zero or one row, got \{summary.row_count.to_string()}",
    )
  }
  first
}

///|
/// Execute a query with explicit parameter types.
pub async fn Client::query_typed(
  self : Client,
  sql : String,
  param_types : Array[Type],
  params? : Array[&ToSql] = [],
) -> RowStream {
  ensure_open(self.shared)
  guard param_types.length() == params.length() else {
    raise ClientError::Encode(
      "parameter count mismatch: expected \{param_types.length().to_string()}, got \{params.length().to_string()}",
    )
  }
  let name = next_name(self.shared, "q")
  let prepare_responses = self.send_request(
    RequestKind::Messages,
    prepare_bytes(name[:], sql, param_types),
  )
  let (_, columns) = read_prepare_response(self.shared, prepare_responses)
  let responses = self.send_request(
    RequestKind::Messages,
    execute_statement_bytes(name[:], param_types, params),
  )
  new_row_stream(
    responses,
    initial_columns=columns,
    cleanup=Some(make_statement_cleanup(self, name)),
  )
}

///|
/// Execute a typed query and return its raw row stream.
pub async fn Client::query_typed_raw(
  self : Client,
  sql : String,
  param_types : Array[Type],
  params? : Array[&ToSql] = [],
) -> RowStream {
  self.query_typed(sql, param_types, params~)
}

///|
/// Execute a previously prepared statement and stream its rows.
pub fn Client::query_statement(
  self : Client,
  statement : Statement,
  params? : Array[&ToSql] = [],
) -> RowStream raise {
  ensure_open(self.shared)
  guard !statement.closed.val else {
    raise ClientError::Closed("statement already closed")
  }
  guard statement.params.length() == params.length() else {
    raise ClientError::Encode(
      "parameter count mismatch: expected \{statement.params.length().to_string()}, got \{params.length().to_string()}",
    )
  }
  let responses = self.send_request(
    RequestKind::Messages,
    execute_statement_bytes(statement.name[:], statement.params, params),
  )
  new_row_stream(responses, initial_columns=statement.columns)
}

///|
/// Execute SQL and return the affected row count.
pub async fn Client::execute(
  self : Client,
  sql : String,
  params? : Array[&ToSql] = [],
) -> Int {
  let statement = self.prepare(sql)
  let rows = self.execute_raw(statement, params~) catch {
    err => {
      let _ = statement.close() catch { _ => () }
      raise err
    }
  }
  statement.close()
  rows
}

///|
/// Execute a prepared statement and return the affected row count.
pub async fn Client::execute_raw(
  self : Client,
  statement : Statement,
  params? : Array[&ToSql] = [],
) -> Int {
  let stream = self.query_statement(statement, params~)
  let summary = stream.finish()
  rows_affected(summary.command_tag)
}

///|
/// Bind parameters to a prepared statement and create a portal.
pub async fn Client::bind(
  self : Client,
  statement : Statement,
  params? : Array[&ToSql] = [],
) -> Portal {
  ensure_open(self.shared)
  guard !statement.closed.val else {
    raise ClientError::Closed("statement already closed")
  }
  guard statement.params.length() == params.length() else {
    raise ClientError::Encode(
      "parameter count mismatch: expected \{statement.params.length().to_string()}, got \{params.length().to_string()}",
    )
  }
  let name = next_name(self.shared, "p")
  let responses = self.send_request(
    RequestKind::Messages,
    bind_portal_bytes(name[:], statement.name[:], statement.params, params),
  )
  let mut columns = statement.columns
  let mut database_error : DatabaseError? = None
  loop responses.get() {
    @backend.Message::BindComplete => continue responses.get()
    @backend.Message::RowDescription(body) => {
      columns = parse_columns(body)
      continue responses.get()
    }
    @backend.Message::NoData => continue responses.get()
    @backend.Message::ErrorResponse(body) => {
      database_error = Some(parse_database_error(body.fields()))
      continue responses.get()
    }
    @backend.Message::ReadyForQuery(_) =>
      match database_error {
        Some(err) => raise ClientError::Database(err)
        None =>
          {
            client: self,
            name,
            columns: resolve_columns(self.shared, columns),
            closed: @ref.new(false),
          }
      }
    _ => raise ClientError::UnexpectedMessage("unexpected bind response")
  }
}

///|
/// Close the portal on the server.
pub async fn Portal::close(self : Portal) -> Unit {
  if self.closed.val {
    return
  }
  let responses = self.client.send_request(
    RequestKind::Messages,
    close_bytes(b'P', self.name[:]),
  )
  drain_close_response(responses)
  self.closed.val = true
}

///|
/// Execute a portal and stream up to `max_rows` rows.
pub fn Client::query_portal(
  self : Client,
  portal : Portal,
  max_rows : Int,
) -> RowStream raise {
  ensure_open(self.shared)
  guard !portal.closed.val else {
    raise ClientError::Closed("portal already closed")
  }
  let responses = self.send_request(
    RequestKind::Messages,
    execute_portal_bytes(portal.name[:], max_rows),
  )
  new_row_stream(responses, initial_columns=portal.columns)
}

///|
/// Start a `COPY ... TO STDOUT` operation.
pub async fn Client::copy_out(self : Client, sql : String) -> CopyOutStream {
  ensure_open(self.shared)
  let responses = self.send_request(
    RequestKind::Messages,
    simple_query_bytes(sql),
  )
  start_copy_out(responses)
}

///|
/// Start a `COPY ... FROM STDIN` operation.
pub async fn Client::copy_in(self : Client, sql : String) -> CopyInSink {
  ensure_open(self.shared)
  let input = @async.Queue::new(kind=Unbounded)
  let responses = self.send_request_with_copy(simple_query_bytes(sql), input)
  let mut database_error : DatabaseError? = None
  loop responses.get() {
    @backend.Message::CopyInResponse(_) =>
      return { input, responses, finished: @ref.new(false) }
    @backend.Message::ErrorResponse(body) => {
      database_error = Some(parse_database_error(body.fields()))
      continue responses.get()
    }
    @backend.Message::ReadyForQuery(_) =>
      match database_error {
        Some(err) => raise ClientError::Database(err)
        None => raise ClientError::UnexpectedMessage("expected CopyInResponse")
      }
    _ => raise ClientError::UnexpectedMessage("unexpected copy-in response")
  }
}

///|
/// Send one COPY data chunk to the server.
pub async fn CopyInSink::send(self : CopyInSink, data : BytesView) -> Unit {
  guard !self.finished.val else {
    raise ClientError::Closed("copy sink already finished")
  }
  self.input.put(CopyInAction::Data(data.to_bytes()))
}

///|
/// Finish the COPY IN operation and return the affected row count.
pub async fn CopyInSink::finish(self : CopyInSink) -> Int {
  guard !self.finished.val else {
    raise ClientError::Closed("copy sink already finished")
  }
  self.finished.val = true
  self.input.put(CopyInAction::Finish)
  collect_copy_in_completion(self.responses)
}

///|
/// Abort the COPY IN operation with an error message.
pub async fn CopyInSink::abort(
  self : CopyInSink,
  message? : String = "COPY aborted",
) -> Unit {
  guard !self.finished.val else { return }
  self.finished.val = true
  self.input.put(CopyInAction::Fail(message))
  let _ = collect_copy_in_completion(self.responses) catch { _ => 0 }
}

///|
/// Begin a transaction with default options.
pub async fn Client::transaction(self : Client) -> Transaction {
  self.batch_execute("BEGIN")
  { client: self, savepoint: None, finished: @ref.new(false) }
}

///|
/// Build a transaction with custom `BEGIN` clauses.
pub fn Client::build_transaction(self : Client) -> TransactionBuilder {
  { client: self, isolation_level: None, read_only: None, deferrable: None }
}

///|
/// Set the transaction isolation level clause.
pub fn TransactionBuilder::isolation_level(
  self : TransactionBuilder,
  level : String,
) -> TransactionBuilder {
  { ..self, isolation_level: Some(level) }
}

///|
/// Set whether the transaction should be read only.
pub fn TransactionBuilder::read_only(
  self : TransactionBuilder,
  enabled? : Bool = true,
) -> TransactionBuilder {
  { ..self, read_only: Some(enabled) }
}

///|
/// Set whether the transaction should be deferrable.
pub fn TransactionBuilder::deferrable(
  self : TransactionBuilder,
  enabled? : Bool = true,
) -> TransactionBuilder {
  { ..self, deferrable: Some(enabled) }
}

///|
/// Start the transaction configured by this builder.
pub async fn TransactionBuilder::start(
  self : TransactionBuilder,
) -> Transaction {
  let clauses : Array[String] = []
  match self.isolation_level {
    Some(level) => clauses.push("ISOLATION LEVEL \{level}")
    None => ()
  }
  match self.read_only {
    Some(true) => clauses.push("READ ONLY")
    Some(false) => clauses.push("READ WRITE")
    None => ()
  }
  match self.deferrable {
    Some(true) => clauses.push("DEFERRABLE")
    Some(false) => clauses.push("NOT DEFERRABLE")
    None => ()
  }
  let sql = if clauses.is_empty() {
    "BEGIN"
  } else {
    "BEGIN " + join_clauses(clauses)
  }
  self.client.batch_execute(sql)
  { client: self.client, savepoint: None, finished: @ref.new(false) }
}

///|
/// Start a nested transaction backed by a savepoint.
pub async fn Transaction::transaction(self : Transaction) -> Transaction {
  self.assert_open()
  let name = "moon_tx_\{next_id(self.client.shared).to_string()}"
  self.client.batch_execute("SAVEPOINT \{name}")
  { client: self.client, savepoint: Some(name), finished: @ref.new(false) }
}

///|
/// Execute a query within this transaction.
pub async fn Transaction::query(
  self : Transaction,
  sql : String,
  params? : Array[&ToSql] = [],
) -> RowStream {
  self.assert_open()
  self.client.query(sql, params~)
}

///|
/// Execute SQL within this transaction and return the affected row count.
pub async fn Transaction::execute(
  self : Transaction,
  sql : String,
  params? : Array[&ToSql] = [],
) -> Int {
  self.assert_open()
  self.client.execute(sql, params~)
}

///|
/// Execute one or more SQL commands within this transaction.
pub async fn Transaction::batch_execute(
  self : Transaction,
  sql : String,
) -> Unit {
  self.assert_open()
  self.client.batch_execute(sql)
}

///|
/// Prepare a statement within this transaction.
pub async fn Transaction::prepare(
  self : Transaction,
  sql : String,
) -> Statement {
  self.assert_open()
  self.client.prepare(sql)
}

///|
/// Bind parameters to a statement within this transaction.
pub async fn Transaction::bind(
  self : Transaction,
  statement : Statement,
  params? : Array[&ToSql] = [],
) -> Portal {
  self.assert_open()
  self.client.bind(statement, params~)
}

///|
/// Execute a portal within this transaction.
pub fn Transaction::query_portal(
  self : Transaction,
  portal : Portal,
  max_rows : Int,
) -> RowStream raise {
  self.assert_open()
  self.client.query_portal(portal, max_rows)
}

///|
/// Commit this transaction or release its savepoint.
pub async fn Transaction::commit(self : Transaction) -> Unit {
  self.assert_open()
  match self.savepoint {
    None => self.client.batch_execute("COMMIT")
    Some(name) => self.client.batch_execute("RELEASE SAVEPOINT \{name}")
  }
  self.finished.val = true
}

///|
/// Roll back this transaction or roll back to its savepoint.
pub async fn Transaction::rollback(self : Transaction) -> Unit {
  self.assert_open()
  match self.savepoint {
    None => self.client.batch_execute("ROLLBACK")
    Some(name) =>
      self.client.batch_execute(
        "ROLLBACK TO SAVEPOINT \{name}; RELEASE SAVEPOINT \{name}",
      )
  }
  self.finished.val = true
}

///|
/// Send a PostgreSQL cancel request for this token.
pub async fn CancelToken::cancel(self : CancelToken) -> Unit {
  if self.closed.val {
    return
  }
  let conn = @socket.Tcp::connect_to_host(
    self.config.host,
    port=self.config.port,
  )
  defer conn.close()
  let buf = @buffer.new()
  @frontend.cancel_request(self.process_id.val, self.secret_key.val, buf)
  conn.write(buf.to_bytes())
}

///|
/// Drive the connection loop until shutdown or failure.
pub async fn Connection::run(
  self : Connection,
  on_async? : (AsyncMessage) -> Unit = _ => (),
) -> Unit {
  let pending : Array[Request] = []
  let mut sent_terminate = false
  try {
    while true {
      if pending.is_empty() && !sent_terminate {
        let request = self.shared.requests.get()
        sent_terminate = self.send_outbound_request(request, pending)
      }
      if self.can_pipeline_requests(pending) && !sent_terminate {
        sent_terminate = self.pipeline_pending_requests(pending)
      }
      if pending.is_empty() {
        if sent_terminate {
          self.drain_queued_requests(None)
          close_runtime(self.shared)
          self.stream.close()
          return
        }
        continue
      }
      let message = self.read_message()
      self.forward_pending_message(pending, message, on_async)
    }
  } catch {
    err => {
      self.close_pending_requests(pending, Some(err))
      self.drain_queued_requests(Some(err))
      close_runtime(self.shared, error=err)
      self.stream.close()
    }
  }
}

///|
/// Receive the next asynchronous message from the connection loop.
pub async fn Connection::next_message(self : Connection) -> AsyncMessage? {
  Some(self.shared.async_messages.get()) catch {
    _ => None
  }
}

///|
/// Look up the latest value of a server parameter.
pub fn Connection::parameter(self : Connection, name : String) -> String? {
  self.shared.parameters.get(name)
}

///|
async fn Connection::send_outbound_request(
  self : Connection,
  request : Request,
  pending : Array[Request],
) -> Bool {
  self.stream.write(request.bytes)
  match request.kind {
    RequestKind::Terminate => {
      request.responses.close()
      true
    }
    RequestKind::Messages | RequestKind::CopyIn => {
      pending.push(request)
      false
    }
  }
}

///|
fn Connection::can_pipeline_requests(
  self : Connection,
  pending : Array[Request],
) -> Bool {
  ignore(self)
  for request in pending {
    match request.kind {
      RequestKind::Messages => ()
      _ => return false
    }
  }
  true
}

///|
async fn Connection::pipeline_pending_requests(
  self : Connection,
  pending : Array[Request],
) -> Bool {
  while true {
    let request = self.shared.requests.try_get() catch { _ => None }
    match request {
      None => return false
      Some(request) => {
        let sent_terminate = self.send_outbound_request(request, pending)
        let is_barrier = match request.kind {
          RequestKind::Messages => false
          _ => true
        }
        if sent_terminate || is_barrier {
          return sent_terminate
        }
        continue
      }
    }
  }
  false
}

///|
async fn Connection::forward_pending_message(
  self : Connection,
  pending : Array[Request],
  message : @backend.Message,
  on_async : (AsyncMessage) -> Unit,
) -> Unit {
  if self.handle_async_message(message, on_async) {
    return
  }
  guard !pending.is_empty() else {
    raise ClientError::UnexpectedMessage("unexpected backend message")
  }
  let request = pending[0]
  match request.kind {
    RequestKind::Messages => {
      self.forward_message_to_request(request, message)
      if message is @backend.Message::ReadyForQuery(_) {
        ignore(pending.remove(0))
      }
    }
    RequestKind::CopyIn => {
      self.forward_copy_in_message(request, message)
      if message is @backend.Message::ReadyForQuery(_) {
        ignore(pending.remove(0))
      }
    }
    RequestKind::Terminate =>
      raise ClientError::UnexpectedMessage("unexpected terminate request")
  }
}

///|
async fn Connection::forward_message_to_request(
  self : Connection,
  request : Request,
  message : @backend.Message,
) -> Unit {
  match message {
    @backend.Message::ReadyForQuery(body) => {
      self.shared.transaction_status.val = body.status
      request.responses.put(message)
    }
    _ => request.responses.put(message)
  }
}

///|
async fn Connection::forward_copy_in_message(
  self : Connection,
  request : Request,
  message : @backend.Message,
) -> Unit {
  let copy_input = request.copy_input.unwrap()
  match message {
    @backend.Message::CopyInResponse(_) => {
      request.responses.put(message)
      self.drain_copy_input(copy_input)
    }
    @backend.Message::ReadyForQuery(body) => {
      self.shared.transaction_status.val = body.status
      request.responses.put(message)
    }
    _ => request.responses.put(message)
  }
}

///|
async fn Connection::drain_copy_input(
  self : Connection,
  input : @async.Queue[CopyInAction],
) -> Unit {
  loop input.get() {
    CopyInAction::Data(data) => {
      let payload = @buffer.new()
      @frontend.CopyData::new(data[:]).write(payload)
      self.stream.write(payload.to_bytes())
      continue input.get()
    }
    CopyInAction::Finish => {
      let payload = @buffer.new()
      @frontend.copy_done(payload)
      self.stream.write(payload.to_bytes())
      return
    }
    CopyInAction::Fail(message) => {
      let payload = @buffer.new()
      @frontend.copy_fail(@proto.utf8_encode(message)[:], payload)
      self.stream.write(payload.to_bytes())
      return
    }
  }
}

///|
fn Connection::close_request(
  self : Connection,
  request : Request,
  error : Error?,
) -> Unit {
  ignore(self)
  match error {
    None => request.responses.close()
    Some(err) => request.responses.close(error=err, clear=true)
  }
  match request.copy_input {
    Some(input) =>
      match error {
        None => input.close()
        Some(err) => input.close(error=err, clear=true)
      }
    None => ()
  }
}

///|
fn Connection::close_pending_requests(
  self : Connection,
  pending : Array[Request],
  error : Error?,
) -> Unit {
  for request in pending {
    self.close_request(request, error)
  }
}

///|
fn Connection::drain_queued_requests(self : Connection, error : Error?) -> Unit {
  let close_error = match error {
    Some(err) => Some(err)
    None => Some(ClientError::Closed("connection is closed"))
  }
  while true {
    let request = self.shared.requests.try_get() catch { _ => None }
    match request {
      None => return
      Some(request) => {
        self.close_request(request, close_error)
        continue
      }
    }
  }
}

///|
fn Connection::handle_async_message(
  self : Connection,
  message : @backend.Message,
  on_async : (AsyncMessage) -> Unit,
) -> Bool raise {
  match message {
    @backend.Message::ParameterStatus(body) => {
      let name = body.name_str()
      let value = body.value_str()
      self.shared.parameters[name] = value
      self.push_async_message(
        AsyncMessage::ParameterStatus(name, value),
        on_async,
      )
      true
    }
    @backend.Message::NoticeResponse(body) => {
      self.push_async_message(
        AsyncMessage::Notice(parse_database_error(body.fields())),
        on_async,
      )
      true
    }
    @backend.Message::NotificationResponse(body) => {
      self.push_async_message(
        AsyncMessage::Notification({
          process_id: body.process_id,
          channel: body.channel_str(),
          payload: body.message_str(),
        }),
        on_async,
      )
      true
    }
    _ => false
  }
}

///|
fn Connection::push_async_message(
  self : Connection,
  message : AsyncMessage,
  on_async : (AsyncMessage) -> Unit,
) -> Unit {
  on_async(message)
  ignore(self.shared.async_messages.try_put(message)) catch {
    _ => ()
  }
}

///|
async fn Connection::read_message(self : Connection) -> @backend.Message {
  let header = self.stream.read_exactly(5)
  let body_len = @proto.ByteReader::new(header[1:]).read_i32_be()
  let body = self.stream.read_exactly(body_len - 4)
  let packet = @buffer.new(size_hint=header.length() + body.length())
  packet.write_bytes(header)
  packet.write_bytes(body)
  match @backend.Message::parse(packet.to_bytes()[:]) {
    Some(parsed) => parsed.message
    None => raise ClientError::UnexpectedMessage("incomplete backend message")
  }
}

///|
fn Client::send_request(
  self : Client,
  kind : RequestKind,
  bytes : Bytes,
  response_kind? : @aqueue.Kind = request_response_queue_kind,
) -> @async.Queue[@backend.Message] raise {
  let responses = @async.Queue::new(kind=response_kind)
  ignore(
    self.shared.requests.try_put({ kind, bytes, responses, copy_input: None }),
  )
  responses
}

///|
fn Client::send_request_with_copy(
  self : Client,
  bytes : Bytes,
  input : @async.Queue[CopyInAction],
) -> @async.Queue[@backend.Message] raise {
  let responses = @async.Queue::new(kind=request_response_queue_kind)
  ignore(
    self.shared.requests.try_put({
      kind: RequestKind::CopyIn,
      bytes,
      responses,
      copy_input: Some(input),
    }),
  )
  responses
}

///|
fn ensure_open(shared : Shared) -> Unit raise {
  if shared.closed.val || shared.closing.val {
    raise ClientError::Closed("connection is closed")
  }
}

///|
fn Transaction::assert_open(self : Transaction) -> Unit raise {
  if self.finished.val {
    raise ClientError::Closed("transaction is already finished")
  }
}

///|
fn close_runtime(shared : Shared, error? : Error) -> Unit {
  if shared.closed.val {
    return
  }
  shared.closed.val = true
  shared.closing.val = true
  match error {
    None => {
      shared.requests.close()
      shared.async_messages.close()
    }
    Some(err) => {
      shared.requests.close(error=err, clear=true)
      shared.async_messages.close()
    }
  }
}

///|
fn next_id(shared : Shared) -> Int {
  shared.next_id.val += 1
  shared.next_id.val
}

///|
fn next_name(shared : Shared, prefix : String) -> Bytes {
  @proto.utf8_encode("\{prefix}\{next_id(shared).to_string()}")
}

///|
fn seed_builtin_types(types : Map[@proto.Oid, Type]) -> Unit {
  for
    type_ in [
      Type::bool(),
      Type::bytea(),
      Type::char(),
      Type::name_type(),
      Type::int8(),
      Type::int2(),
      Type::int4(),
      Type::text(),
      Type::oid_type(),
      Type::json(),
      Type::float4(),
      Type::float8(),
      Type::varchar(),
      Type::date(),
      Type::time(),
      Type::timestamp(),
      Type::timestamptz(),
      Type::uuid(),
      Type::jsonb(),
      Type::bool_array(),
      Type::bytea_array(),
      Type::int2_array(),
      Type::int4_array(),
      Type::text_array(),
      Type::varchar_array(),
      Type::int8_array(),
      Type::float4_array(),
      Type::float8_array(),
      Type::timestamp_array(),
      Type::date_array(),
      Type::uuid_array(),
    ] {
    types[type_.oid] = type_
  }
}

///|
let typeinfo_query = "select t.typname::text, t.typtype::text, t.typelem::oid, r.rngsubtype::oid, t.typbasetype::oid, n.nspname::text, t.typrelid::oid from pg_catalog.pg_type t left join pg_catalog.pg_range r on r.rngtypid = t.oid inner join pg_catalog.pg_namespace n on t.typnamespace = n.oid where t.oid = $1"

///|
let typeinfo_enum_query = "select enumlabel::text from pg_catalog.pg_enum where enumtypid = $1 order by enumsortorder"

///|
let typeinfo_composite_query = "select attname::text, atttypid::oid from pg_catalog.pg_attribute where attrelid = $1 and not attisdropped and attnum > 0 order by attnum"

///|
async fn cached_type(shared : Shared, oid : @proto.Oid) -> Type {
  match shared.types.get(oid) {
    Some(type_) => type_
    None => {
      let type_ = lookup_type(shared, oid)
      shared.types[oid] = type_
      type_
    }
  }
}

///|
async fn lookup_type(shared : Shared, oid : @proto.Oid) -> Type {
  match builtin_type(oid) {
    Some(type_) => type_
    None => {
      let rows = query_oid_catalog(shared, typeinfo_query, oid) catch {
        _ => []
      }
      if rows.is_empty() {
        return Type::unknown(oid, name="oid_\{oid.to_string()}")
      }
      let row = rows[0]
      let name : String = row.get(0)
      let typtype : String = row.get(1)
      let elem_oid : @proto.Oid = row.get(2)
      let range_subtype : @proto.Oid? = row.get(3)
      let base_oid : @proto.Oid = row.get(4)
      let relid : @proto.Oid = row.get(6)
      let kind = if typtype == "e" {
        Kind::Enum(query_enum_labels(shared, oid))
      } else if typtype == "p" {
        Kind::Pseudo
      } else if base_oid != 0U {
        Kind::Domain(base_oid)
      } else if elem_oid != 0U {
        Kind::Array(elem_oid)
      } else if relid != 0U {
        Kind::Composite(query_composite_fields(shared, relid))
      } else {
        match range_subtype {
          Some(subtype) => Kind::Range(subtype)
          None => Kind::Simple
        }
      }
      { oid, name, kind }
    }
  }
}

///|
async fn query_oid_catalog(
  shared : Shared,
  sql : String,
  oid : @proto.Oid,
) -> Array[Row] {
  let client : Client = { shared, }
  let params : Array[&ToSql] = [oid as &ToSql]
  let stream = client.query_typed(sql, [Type::oid_type()], params~)
  stream.collect()
}

///|
async fn query_enum_labels(shared : Shared, oid : @proto.Oid) -> Array[String] {
  let rows = query_oid_catalog(shared, typeinfo_enum_query, oid) catch {
    _ => []
  }
  rows.map(row => row.get(0))
}

///|
async fn query_composite_fields(
  shared : Shared,
  oid : @proto.Oid,
) -> Array[Field] {
  let rows = query_oid_catalog(shared, typeinfo_composite_query, oid) catch {
    _ => []
  }
  rows.map(row => { name: row.get(0), type_oid: row.get(1) })
}

///|
fn parse_parameter_oids(
  body : @backend.ParameterDescriptionBody,
) -> Array[@proto.Oid] raise {
  let types : Array[@proto.Oid] = []
  let params = body.parameters()
  loop params.next() {
    None => types
    Some(oid) => {
      types.push(oid)
      continue params.next()
    }
  }
}

///|
async fn resolve_parameter_types(
  shared : Shared,
  oids : Array[@proto.Oid],
) -> Array[Type] {
  let out : Array[Type] = []
  for oid in oids {
    out.push(cached_type(shared, oid))
  }
  out
}

///|
async fn resolve_columns(
  shared : Shared,
  columns : Array[Column],
) -> Array[Column] {
  let out : Array[Column] = []
  for column in columns {
    out.push({ ..column, type_: cached_type(shared, column.type_.oid) })
  }
  out
}

///|
fn simple_query_bytes(sql : String) -> Bytes raise {
  let buf = @buffer.new()
  @frontend.query(@proto.utf8_encode(sql)[:], buf)
  buf.to_bytes()
}

///|
fn sync_bytes() -> Bytes {
  let buf = @buffer.new()
  @frontend.sync(buf)
  buf.to_bytes()
}

///|
fn terminate_bytes() -> Bytes {
  let buf = @buffer.new()
  @frontend.terminate(buf)
  buf.to_bytes()
}

///|
fn close_bytes(kind : Byte, name : BytesView) -> Bytes raise {
  let buf = @buffer.new()
  @frontend.close(kind, name, buf)
  @frontend.sync(buf)
  buf.to_bytes()
}

///|
fn prepare_bytes(
  name : BytesView,
  sql : String,
  types : Array[Type],
) -> Bytes raise {
  let buf = @buffer.new()
  @frontend.parse(
    name,
    @proto.utf8_encode(sql)[:],
    types.map(t => t.oid).iter(),
    buf,
  )
  @frontend.describe(b'S', name, buf)
  @frontend.sync(buf)
  buf.to_bytes()
}

///|
fn execute_statement_bytes(
  statement_name : BytesView,
  param_types : Array[Type],
  params : Array[&ToSql],
) -> Bytes raise {
  let buf = @buffer.new()
  write_bind(buf, b""[:], statement_name, param_types, params, true)
  @frontend.execute(b""[:], 0, buf)
  @frontend.sync(buf)
  buf.to_bytes()
}

///|
fn bind_portal_bytes(
  portal_name : BytesView,
  statement_name : BytesView,
  param_types : Array[Type],
  params : Array[&ToSql],
) -> Bytes raise {
  let buf = @buffer.new()
  write_bind(buf, portal_name, statement_name, param_types, params, true)
  @frontend.sync(buf)
  buf.to_bytes()
}

///|
fn execute_portal_bytes(portal_name : BytesView, max_rows : Int) -> Bytes raise {
  let buf = @buffer.new()
  @frontend.execute(portal_name, max_rows, buf)
  @frontend.sync(buf)
  buf.to_bytes()
}

///|
priv struct EncodedParam {
  format : Int
  value : Bytes?
}

///|
fn encode_param(param : &ToSql, type_ : Type) -> EncodedParam raise {
  guard param.accepts(type_) else {
    raise wrong_type_error(param.moonbit_type_name(), type_)
  }
  let payload = @buffer.new()
  let value = match param.to_sql(type_, payload) {
    @proto.IsNull::Yes => None
    @proto.IsNull::No => Some(payload.to_bytes())
  }
  { format: param.format(type_), value }
}

///|
fn write_encoded_param(
  param : EncodedParam,
  payload : @buffer.Buffer,
) -> @proto.IsNull {
  match param.value {
    None => @proto.IsNull::Yes
    Some(bytes) => {
      payload.write_bytes(bytes)
      @proto.IsNull::No
    }
  }
}

///|
fn write_bind(
  buf : @buffer.Buffer,
  portal : BytesView,
  statement : BytesView,
  param_types : Array[Type],
  params : Array[&ToSql],
  describe_portal : Bool,
) -> Unit raise {
  let encoded_params : Array[EncodedParam] = []
  for index, param in params {
    encoded_params.push(encode_param(param, param_types[index]))
  }
  let formats = encoded_params.map(param => param.format)
  @frontend.bind(
    portal,
    statement,
    formats.iter(),
    encoded_params.iter(),
    (param, payload) => write_encoded_param(param, payload),
    [1].iter(),
    buf,
  )
  if describe_portal {
    @frontend.describe(b'P', portal, buf)
  }
}

///|
fn new_row_stream(
  responses : @async.Queue[@backend.Message],
  initial_columns? : Array[Column] = [],
  cleanup? : StreamCleanup? = None,
) -> RowStream {
  {
    columns: initial_columns,
    responses,
    cleanup,
    command_tag: "",
    row_count: 0,
    suspended: false,
    database_error: None,
    summary: None,
  }
}

///|
fn new_simple_query_stream(
  responses : @async.Queue[@backend.Message],
) -> SimpleQueryStream {
  { responses, columns: [], database_error: None, finished: false }
}

///|
fn make_statement_cleanup(client : Client, name : Bytes) -> StreamCleanup raise {
  { client, bytes: close_bytes(b'S', name[:]), done: false }
}

///|
async fn close_temporary_statement(client : Client, name : Bytes) -> Unit {
  let responses = client.send_request(
    RequestKind::Messages,
    close_bytes(b'S', name[:]),
  )
  drain_close_response(responses)
}

///|
async fn RowStream::run_cleanup(self : RowStream) -> Unit {
  match self.cleanup {
    Some(cleanup) =>
      if !cleanup.done {
        cleanup.done = true
        let responses = cleanup.client.send_request(
          RequestKind::Messages,
          cleanup.bytes,
        )
        drain_close_response(responses)
      }
    None => ()
  }
}

///|
async fn start_copy_out(
  responses : @async.Queue[@backend.Message],
) -> CopyOutStream {
  let mut database_error : DatabaseError? = None
  loop responses.get() {
    @backend.Message::CopyOutResponse(body) =>
      return {
        responses,
        formats: parse_copy_formats(body.column_formats()),
        database_error,
        finished: false,
      }
    @backend.Message::ErrorResponse(body) => {
      database_error = Some(parse_database_error(body.fields()))
      continue responses.get()
    }
    @backend.Message::ReadyForQuery(_) =>
      match database_error {
        Some(err) => raise ClientError::Database(err)
        None => raise ClientError::UnexpectedMessage("expected CopyOutResponse")
      }
    _ => raise ClientError::UnexpectedMessage("unexpected copy out response")
  }
}

///|
async fn read_prepare_response(
  shared : Shared,
  responses : @async.Queue[@backend.Message],
) -> (Array[Type], Array[Column]) {
  let mut param_oids : Array[@proto.Oid] = []
  let mut columns : Array[Column] = []
  let mut database_error : DatabaseError? = None
  loop responses.get() {
    @backend.Message::ParseComplete => continue responses.get()
    @backend.Message::ParameterDescription(body) => {
      param_oids = parse_parameter_oids(body)
      continue responses.get()
    }
    @backend.Message::RowDescription(body) => {
      columns = parse_columns(body)
      continue responses.get()
    }
    @backend.Message::NoData => continue responses.get()
    @backend.Message::ErrorResponse(body) => {
      database_error = Some(parse_database_error(body.fields()))
      continue responses.get()
    }
    @backend.Message::ReadyForQuery(_) =>
      match database_error {
        Some(err) => raise ClientError::Database(err)
        None =>
          (
            resolve_parameter_types(shared, param_oids),
            resolve_columns(shared, columns),
          )
      }
    _ => raise ClientError::UnexpectedMessage("unexpected prepare response")
  }
}

///|
async fn collect_copy_in_completion(
  responses : @async.Queue[@backend.Message],
) -> Int {
  let mut command_tag = ""
  let mut database_error : DatabaseError? = None
  loop responses.get() {
    @backend.Message::CommandComplete(body) => {
      command_tag = body.tag_str()
      continue responses.get()
    }
    @backend.Message::CopyDone => continue responses.get()
    @backend.Message::ErrorResponse(body) => {
      database_error = Some(parse_database_error(body.fields()))
      continue responses.get()
    }
    @backend.Message::ReadyForQuery(_) =>
      match database_error {
        Some(err) => raise ClientError::Database(err)
        None => rows_affected(command_tag)
      }
    _ => raise ClientError::UnexpectedMessage("unexpected copy in completion")
  }
}

///|
async fn drain_close_response(
  responses : @async.Queue[@backend.Message],
) -> Unit {
  let mut database_error : DatabaseError? = None
  loop responses.get() {
    @backend.Message::CloseComplete => continue responses.get()
    @backend.Message::ErrorResponse(body) => {
      database_error = Some(parse_database_error(body.fields()))
      continue responses.get()
    }
    @backend.Message::ReadyForQuery(_) =>
      match database_error {
        Some(err) => raise ClientError::Database(err)
        None => ()
      }
    _ => raise ClientError::UnexpectedMessage("unexpected close response")
  }
}

///|
async fn drain_sync_response(
  responses : @async.Queue[@backend.Message],
) -> Unit {
  match responses.get() {
    @backend.Message::ReadyForQuery(_) => ()
    _ => raise ClientError::UnexpectedMessage("unexpected sync response")
  }
}

///|
async fn drain_simple_query(responses : @async.Queue[@backend.Message]) -> Unit {
  let mut database_error : DatabaseError? = None
  loop responses.get() {
    @backend.Message::CommandComplete(_)
    | @backend.Message::EmptyQueryResponse
    | @backend.Message::RowDescription(_)
    | @backend.Message::DataRow(_) => continue responses.get()
    @backend.Message::ErrorResponse(body) => {
      database_error = Some(parse_database_error(body.fields()))
      continue responses.get()
    }
    @backend.Message::ReadyForQuery(_) =>
      match database_error {
        Some(err) => raise ClientError::Database(err)
        None => ()
      }
    _ =>
      raise ClientError::UnexpectedMessage("unexpected batch execute response")
  }
}

///|
fn rows_affected(command_tag : String) -> Int {
  match command_tag.split(" ").last() {
    None => 0
    Some(last) => (try? @string.parse_int(last)).unwrap_or(0)
  }
}

///|
fn join_clauses(clauses : Array[String]) -> String {
  let mut out = ""
  for index, clause in clauses {
    if index != 0 {
      out += " "
    }
    out += clause
  }
  out
}

///|
async fn connect_stream(config : Config) -> Stream {
  let conn = @socket.Tcp::connect_to_host(config.host, port=config.port)
  match config.ssl_mode {
    Disable => Plain(conn)
    Prefer | Require => {
      let request = @buffer.new()
      @frontend.ssl_request(request)
      conn.write(request.to_bytes())
      let response = conn.read_exactly(1)
      match response[0] {
        b'S' => {
          let tls = @tls.Tls::client(conn, host=config.host) catch {
            err => {
              conn.close()
              raise ClientError::Ssl(err.to_string())
            }
          }
          Secure(tls)
        }
        b'N' =>
          if config.ssl_mode is Require {
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
priv struct StartupState {
  process_id : Int
  secret_key : Int
  parameters : Map[String, String]
  transaction_status : Byte
}

///|
async fn startup(stream : Stream, config : Config) -> StartupState {
  let parameters : Array[(BytesView, BytesView)] = [
    (b"user"[:], @proto.utf8_encode(config.user)[:]),
    (b"database"[:], @proto.utf8_encode(config.database)[:]),
    (b"client_encoding"[:], b"UTF8"[:]),
    (b"application_name"[:], @proto.utf8_encode(config.application_name)[:]),
  ]
  let buf = @buffer.new()
  @frontend.startup_message(parameters.iter(), buf)
  stream.write(buf.to_bytes())
  let status : Map[String, String] = {}
  let mut process_id = 0
  let mut secret_key = 0
  let mut transaction_status = b'I'
  let mut scram : @sasl.ScramSha256? = None
  loop read_message(stream) {
    @backend.Message::AuthenticationOk => continue read_message(stream)
    @backend.Message::AuthenticationCleartextPassword => {
      send_password_message(stream, config.password)
      continue read_message(stream)
    }
    @backend.Message::AuthenticationMd5Password(body) => {
      send_md5_password_message(stream, config.user, config.password, body.salt)
      continue read_message(stream)
    }
    @backend.Message::AuthenticationSasl(body) => {
      scram = Some(begin_scram(stream, body, config.password))
      continue read_message(stream)
    }
    @backend.Message::AuthenticationSaslContinue(body) => {
      continue_scram(stream, scram, body.data())
      continue read_message(stream)
    }
    @backend.Message::AuthenticationSaslFinal(body) => {
      finish_scram(scram, body.data())
      continue read_message(stream)
    }
    @backend.Message::ParameterStatus(body) => {
      status[body.name_str()] = body.value_str()
      continue read_message(stream)
    }
    @backend.Message::BackendKeyData(body) => {
      process_id = body.process_id
      secret_key = body.secret_key
      continue read_message(stream)
    }
    @backend.Message::NoticeResponse(_) => continue read_message(stream)
    @backend.Message::ReadyForQuery(body) => {
      transaction_status = body.status
      return { process_id, secret_key, parameters: status, transaction_status }
    }
    @backend.Message::ErrorResponse(body) =>
      raise ClientError::Database(parse_database_error(body.fields()))
    @backend.Message::AuthenticationKerberosV5
    | @backend.Message::AuthenticationScmCredential
    | @backend.Message::AuthenticationGss
    | @backend.Message::AuthenticationGssContinue(_)
    | @backend.Message::AuthenticationSspi =>
      raise ClientError::Authentication(
        "server requested an unsupported authentication method",
      )
    _ => raise ClientError::UnexpectedMessage("unexpected startup message")
  }
}

///|
async fn read_message(stream : Stream) -> @backend.Message {
  let header = stream.read_exactly(5)
  let body_len = @proto.ByteReader::new(header[1:]).read_i32_be()
  let body = stream.read_exactly(body_len - 4)
  let packet = @buffer.new(size_hint=header.length() + body.length())
  packet.write_bytes(header)
  packet.write_bytes(body)
  match @backend.Message::parse(packet.to_bytes()[:]) {
    Some(parsed) => parsed.message
    None => raise ClientError::UnexpectedMessage("incomplete backend message")
  }
}

///|
async fn send_password_message(stream : Stream, password : String?) -> Unit {
  let password = require_password(password)
  let buf = @buffer.new()
  @frontend.password_message(@proto.utf8_encode(password)[:], buf)
  stream.write(buf.to_bytes())
}

///|
async fn send_md5_password_message(
  stream : Stream,
  user : String,
  password : String?,
  salt : BytesView,
) -> Unit {
  let password = require_password(password)
  let digest = @auth.md5_hash(
    @proto.utf8_encode(user)[:],
    @proto.utf8_encode(password)[:],
    salt,
  )
  let buf = @buffer.new()
  @frontend.password_message(digest[:], buf)
  stream.write(buf.to_bytes())
}

///|
#warnings("-14")
async fn begin_scram(
  stream : Stream,
  body : @backend.AuthenticationSaslBody,
  password : String?,
) -> @sasl.ScramSha256 {
  guard supports_scram(body) else {
    raise ClientError::Authentication(
      "server does not offer SCRAM-SHA-256 authentication",
    )
  }
  let password = require_password(password)
  let nonce = @tls.rand_bytes(18)
  let scram = @sasl.ScramSha256::new(
    @proto.utf8_encode(password)[:],
    @sasl.ChannelBinding::unsupported(),
    nonce[:],
  )
  let buf = @buffer.new()
  @frontend.sasl_initial_response(@sasl.SCRAM_SHA_256[:], scram.message(), buf)
  stream.write(buf.to_bytes())
  scram
}

///|
async fn continue_scram(
  stream : Stream,
  scram : @sasl.ScramSha256?,
  data : BytesView,
) -> Unit {
  let scram = require_scram(scram)
  scram.update(data)
  let buf = @buffer.new()
  @frontend.sasl_response(scram.message(), buf)
  stream.write(buf.to_bytes())
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
