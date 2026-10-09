// Helpers that turn backend message queues into higher-level client results.

///|
/// Construct a `RowStream` over one backend response queue.
fn RowStream::new(
  control : DrainControl,
  responses : @async.Queue[@backend.Message],
  permit : OperationPermit?,
  initial_columns? : Array[Column] = [],
  cleanup? : StreamCleanup? = None,
) -> RowStream {
  {
    control,
    columns: initial_columns,
    responses,
    cleanup,
    permit,
    command_tag: "",
    row_count: 0,
    suspended: false,
    database_error: None,
    detached: false,
    detached_done: None,
    summary: None,
  }
}

///|
/// Construct a `SimpleQueryStream` over one backend response queue.
fn SimpleQueryStream::new(
  control : DrainControl,
  responses : @async.Queue[@backend.Message],
  permit : OperationPermit?,
) -> SimpleQueryStream {
  {
    control,
    responses,
    permit,
    columns: [],
    database_error: None,
    detached: false,
    detached_done: None,
    finished: false,
  }
}

///|
/// Build the deferred cleanup object for a temporary prepared statement.
fn StreamCleanup::new(context : OpContext, name : Bytes) -> StreamCleanup raise {
  { context, bytes: close_bytes(b'S', name[:]), done: false, }
}

///|
/// Close a temporary prepared statement immediately.
///
/// This is used on early failures that happen before a `RowStream` can be
/// returned to the caller and therefore before deferred cleanup is available.
async fn close_temporary_statement(context : OpContext, name : Bytes) -> Unit {
  let responses = context.client.send_request(
    Messages,
    close_bytes(b'S', name[:]),
  )
  drain_close_response(responses)
}

///|
// Preserve the original query creation error. A failed Close that did not
// reach ReadyForQuery makes the connection timeline unsafe to reuse.
async fn close_temporary_statement_after_error(
  context : OpContext,
  name : Bytes,
) -> Unit {
  close_temporary_statement(context, name) catch {
    ClientError::Database(_) => ()
    _ => context.client.abort()
  }
}

///|
/// Wait for PostgreSQL to acknowledge `COPY OUT` mode and build the stream.
async fn start_copy_out(
  control : DrainControl,
  responses : @async.Queue[@backend.Message],
  permit : OperationPermit?,
) -> CopyOutStream {
  let mut database_error : DatabaseError? = None
  for res = responses.get() {
    match res {
      CopyOutResponse(body) =>
        // The stream is valid only after PostgreSQL explicitly enters COPY OUT
        // mode and advertises the per-column wire formats.
        return {
          control,
          responses,
          permit,
          formats: parse_copy_formats(body.column_formats()),
          database_error,
          detached: false,
          detached_done: None,
          finished: false,
        }
      ErrorResponse(body) => {
        database_error = Some(parse_database_error(body.fields()))
        continue responses.get()
      }
      ReadyForQuery(_) =>
        if database_error is Some(err) {
          raise ClientError::Database(err)
        } else {
          raise ClientError::UnexpectedMessage("expected CopyOutResponse")
        }
      _ =>
        fail_response_stream(
          responses,
          ClientError::UnexpectedMessage("unexpected copy out response"),
        )
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
  responses : @async.Queue[@backend.Message],
) -> (Array[@proto.Oid], Array[Column]) {
  let mut param_oids : Array[@proto.Oid] = []
  let mut columns : Array[Column] = []
  let mut database_error : DatabaseError? = None
  for res = responses.get() {
    match res {
      ParseComplete => continue responses.get()
      ParameterDescription(body) => {
        // Hold onto raw OIDs for now; the richer `Type` descriptors are loaded
        // only after PostgreSQL finishes the prepare exchange successfully.
        param_oids = parse_parameter_oids(body)
        continue responses.get()
      }
      RowDescription(body) => {
        columns = parse_columns(body)
        continue responses.get()
      }
      NoData => continue responses.get()
      ErrorResponse(body) => {
        database_error = Some(parse_database_error(body.fields()))
        continue responses.get()
      }
      ReadyForQuery(_) =>
        if database_error is Some(err) {
          raise ClientError::Database(err)
        } else {
          break (param_oids, columns)
        }
      _ =>
        fail_response_stream(
          responses,
          ClientError::UnexpectedMessage("unexpected prepare response"),
        )
    }
  }
}

///|
/// Drain the backend completion sequence for COPY IN and return its raw tag.
/// Parse affected rows only after the caller releases the operation permit.
async fn collect_copy_in_completion(
  responses : @async.Queue[@backend.Message],
) -> String {
  let mut command_tag = ""
  let mut database_error : DatabaseError? = None
  for res = responses.get() {
    match res {
      CommandComplete(body) => {
        // COPY IN reports affected rows only through the trailing command tag,
        // after all client input has already been sent.
        command_tag = body.tag_str()
        continue responses.get()
      }
      CopyDone => continue responses.get()
      ErrorResponse(body) => {
        database_error = Some(parse_database_error(body.fields()))
        continue responses.get()
      }
      ReadyForQuery(_) =>
        if database_error is Some(err) {
          raise ClientError::Database(err)
        } else {
          break command_tag
        }
      _ =>
        fail_response_stream(
          responses,
          ClientError::UnexpectedMessage("unexpected copy in completion"),
        )
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
      CloseComplete => continue responses.get()
      ErrorResponse(body) => {
        database_error = Some(parse_database_error(body.fields()))
        continue responses.get()
      }
      ReadyForQuery(_) =>
        if database_error is Some(err) {
          raise ClientError::Database(err)
        } else {
          break ()
        }
      _ =>
        fail_response_stream(
          responses,
          ClientError::UnexpectedMessage("unexpected close response"),
        )
    }
  }
}

///|
/// Drain the response to a standalone `Sync`.
async fn drain_sync_response(
  responses : @async.Queue[@backend.Message],
) -> Unit {
  match responses.get() {
    ReadyForQuery(_) => ()
    _ =>
      fail_response_stream(
        responses,
        ClientError::UnexpectedMessage("unexpected sync response"),
      )
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
      CommandComplete(_)
      | EmptyQueryResponse
      | RowDescription(_)
      | DataRow(_) => continue responses.get()
      ErrorResponse(body) => {
        database_error = Some(parse_database_error(body.fields()))
        continue responses.get()
      }
      ReadyForQuery(_) =>
        if database_error is Some(err) {
          raise ClientError::Database(err)
        } else {
          break ()
        }
      _ =>
        fail_response_stream(
          responses,
          ClientError::UnexpectedMessage("unexpected batch execute response"),
        )
    }
  }
}

///|
/// Parse the decimal row count of a PostgreSQL command tag.
/// Commands without a count return zero; malformed counted tags are errors.
fn rows_affected(command_tag : String) -> UInt64 raise {
  let fields = command_tag.split(" ").to_array()
  let count = match fields[:] {
    ["INSERT", oid, count] => {
      guard !oid.is_empty() && oid.iter().all(c => c >= '0' && c <= '9') else {
        raise ClientError::Protocol(
          "invalid INSERT command tag: \{command_tag}",
        )
      }
      count
    }
    [
      "DELETE"
      | "UPDATE"
      | "MERGE"
      | "SELECT"
      | "MOVE"
      | "FETCH"
      | "COPY",
      count,
    ] => count
    [
      "INSERT"
      | "DELETE"
      | "UPDATE"
      | "MERGE"
      | "SELECT"
      | "MOVE"
      | "FETCH"
      | "COPY",
      ..,
    ] =>
      raise ClientError::Protocol(
        "invalid row count in command tag: \{command_tag}",
      )
    _ => return 0
  }
  // The core parser also accepts separators, but protocol counts are digits only.
  guard !count.is_empty() && count.iter().all(c => c >= '0' && c <= '9') else {
    raise ClientError::Protocol(
      "invalid row count in command tag: \{command_tag}",
    )
  }
  @string.parse_uint64(count, base=10) catch {
    _ =>
      raise ClientError::Protocol(
        "invalid row count in command tag: \{command_tag}",
      )
  }
}

///|
/// Join transaction option clauses with spaces.
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
/// Once preparation has reached ReadyForQuery, own the statement before any
/// catalog lookup can fail. Close failures here abort even after ReadyForQuery.
async fn resolve_prepared_metadata(
  context : OpContext,
  name : Bytes,
  param_oids : Array[@proto.Oid],
  columns : Array[Column],
) -> (Array[Type], Array[Column]) {
  errdefer @async.protect_from_cancel(() => {
    close_unresolved_statement_after_error(context, name)
  })
  (
    resolve_parameter_types(context, param_oids),
    resolve_columns(context, columns),
  )
}

///|
async fn close_unresolved_statement_after_error(
  context : OpContext,
  name : Bytes,
) -> Unit {
  close_temporary_statement(context, name) catch {
    _ => context.client.abort()
  }
}
