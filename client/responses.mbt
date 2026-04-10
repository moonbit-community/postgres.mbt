// Helpers that turn backend message queues into higher-level client results.

///|
/// Construct a `RowStream` over one backend response queue.
fn new_row_stream(
  background_group : @ref.Ref[@async.TaskGroup[Unit]?],
  responses : @async.Queue[@backend.Message],
  initial_columns? : Array[Column] = [],
  cleanup? : StreamCleanup? = None,
) -> RowStream {
  {
    background_group,
    columns: initial_columns,
    responses,
    cleanup,
    command_tag: "",
    row_count: 0,
    suspended: false,
    database_error: None,
    detached: false,
    summary: None,
  }
}

///|
/// Construct a `SimpleQueryStream` over one backend response queue.
fn new_simple_query_stream(
  background_group : @ref.Ref[@async.TaskGroup[Unit]?],
  responses : @async.Queue[@backend.Message],
) -> SimpleQueryStream {
  {
    background_group,
    responses,
    columns: [],
    database_error: None,
    detached: false,
    finished: false,
  }
}

///|
/// Build the deferred cleanup object for a temporary prepared statement.
fn make_statement_cleanup(client : Client, name : Bytes) -> StreamCleanup raise {
  { client, bytes: close_bytes(b'S', name[:]), done: false }
}

///|
/// Close a temporary prepared statement immediately.
///
/// This is used on early failures that happen before a `RowStream` can be
/// returned to the caller and therefore before deferred cleanup is available.
async fn close_temporary_statement(client : Client, name : Bytes) -> Unit {
  let responses = client.send_request(
    RequestKind::Messages,
    close_bytes(b'S', name[:]),
  )
  drain_close_response(responses)
}

///|
/// Wait for PostgreSQL to acknowledge `COPY OUT` mode and build the stream.
async fn start_copy_out(
  background_group : @ref.Ref[@async.TaskGroup[Unit]?],
  responses : @async.Queue[@backend.Message],
) -> CopyOutStream {
  let mut database_error : DatabaseError? = None
  for res = responses.get() {
    match res {
      @backend.Message::CopyOutResponse(body) =>
        // The stream is valid only after PostgreSQL explicitly enters COPY OUT
        // mode and advertises the per-column format codes.
        return {
          background_group,
          responses,
          formats: parse_copy_formats(body.column_formats()),
          database_error,
          detached: false,
          finished: false,
        }
      @backend.Message::ErrorResponse(body) => {
        database_error = Some(parse_database_error(body.fields()))
        continue responses.get()
      }
      @backend.Message::ReadyForQuery(_) =>
        match database_error {
          Some(err) => raise ClientError::Database(err)
          None =>
            raise ClientError::UnexpectedMessage("expected CopyOutResponse")
        }
      _ => raise ClientError::UnexpectedMessage("unexpected copy out response")
    }
  }
}

///|
/// Parse the server's response to a statement preparation request.
///
/// The server may send parameter descriptions, row descriptions, both, or
/// neither depending on the statement. Database errors are deferred until the
/// terminal `ReadyForQuery` just like the public stream helpers do.
async fn read_prepare_response(
  shared : Shared,
  responses : @async.Queue[@backend.Message],
) -> (Array[Type], Array[Column]) {
  let mut param_oids : Array[@proto.Oid] = []
  let mut columns : Array[Column] = []
  let mut database_error : DatabaseError? = None
  for res = responses.get() {
    match res {
      @backend.Message::ParseComplete => continue responses.get()
      @backend.Message::ParameterDescription(body) => {
        // Hold onto raw OIDs for now; the richer `Type` descriptors are loaded
        // only after PostgreSQL finishes the prepare exchange successfully.
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
          None => {
            // Resolve cached type metadata once, at the end, so callers see a
            // fully enriched result without partial-success bookkeeping.
            let result = (
              resolve_parameter_types(shared, param_oids),
              resolve_columns(shared, columns),
            )
            break result
          }
        }
      _ => raise ClientError::UnexpectedMessage("unexpected prepare response")
    }
  }
}

///|
/// Drain the backend completion sequence for COPY IN and return affected rows.
async fn collect_copy_in_completion(
  responses : @async.Queue[@backend.Message],
) -> Int {
  let mut command_tag = ""
  let mut database_error : DatabaseError? = None
  for res = responses.get() {
    match res {
      @backend.Message::CommandComplete(body) => {
        // COPY IN reports affected rows only through the trailing command tag,
        // after all client input has already been sent.
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
          None => break rows_affected(command_tag)
        }
      _ => raise ClientError::UnexpectedMessage("unexpected copy in completion")
    }
  }
}

///|
/// Drain the backend completion sequence for `Close`.
async fn drain_close_response(
  responses : @async.Queue[@backend.Message],
) -> Unit {
  let mut database_error : DatabaseError? = None
  for res = responses.get() {
    match res {
      @backend.Message::CloseComplete => continue responses.get()
      @backend.Message::ErrorResponse(body) => {
        database_error = Some(parse_database_error(body.fields()))
        continue responses.get()
      }
      @backend.Message::ReadyForQuery(_) =>
        match database_error {
          Some(err) => raise ClientError::Database(err)
          None => break ()
        }
      _ => raise ClientError::UnexpectedMessage("unexpected close response")
    }
  }
}

///|
/// Drain the response to a standalone `Sync`.
async fn drain_sync_response(
  responses : @async.Queue[@backend.Message],
) -> Unit {
  match responses.get() {
    @backend.Message::ReadyForQuery(_) => ()
    _ => raise ClientError::UnexpectedMessage("unexpected sync response")
  }
}

///|
/// Drain all responses produced by `batch_execute`.
async fn drain_simple_query(responses : @async.Queue[@backend.Message]) -> Unit {
  let mut database_error : DatabaseError? = None
  for res = responses.get() {
    match res {
      // `batch_execute` intentionally ignores per-statement rows and metadata;
      // only terminal success or database failure matters here.
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
          None => break ()
        }
      _ =>
        raise ClientError::UnexpectedMessage(
          "unexpected batch execute response",
        )
    }
  }
}

///|
/// Extract the trailing numeric row count from a PostgreSQL command tag.
fn rows_affected(command_tag : String) -> Int {
  match command_tag.split(" ").last() {
    None => 0
    Some(last) => (try? @string.parse_int(last)).unwrap_or(0)
  }
}

///|
/// Join transaction builder clauses with spaces.
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
