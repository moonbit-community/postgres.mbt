// Query, prepare, bind, execute, and portal APIs.

///|
/// Execute a SQL string with PostgreSQL's simple query protocol.
///
/// Use this when you need PostgreSQL's statement batching semantics or when you
/// want to inspect raw text-format result frames through `SimpleQueryStream`.
///
/// Warning: if you stop consuming the returned stream early and want to discard
/// it, call `detach()` before dropping the handle. Otherwise later requests on
/// the same connection can remain blocked until the unfinished response is
/// drained.
pub async fn Client::simple_query(
  self : Client,
  sql : String,
) -> SimpleQueryStream {
  let (_context, permit) = self.begin_stream_operation()
  try {
    let responses = self.send_request(Messages, simple_query_bytes(sql))
    new_simple_query_stream(
      self.shared.background_group,
      responses,
      Some(permit),
    )
  } catch {
    err => {
      permit.release()
      raise err
    }
  }
}

///|
/// Execute one or more SQL commands and discard any returned rows.
///
/// This is the simplest helper for commands such as schema setup or session
/// configuration where only protocol completion matters.
pub async fn Client::batch_execute(self : Client, sql : String) -> Unit {
  self.run_operation(context => context.batch_execute(sql))
}

///|
async fn OpContext::batch_execute(self : OpContext, sql : String) -> Unit {
  let responses = self.client.send_request(Messages, simple_query_bytes(sql))
  drain_simple_query(responses)
}

///|
/// Prepare a statement and let PostgreSQL infer its parameter types.
pub async fn Client::prepare(self : Client, sql : String) -> Statement {
  self.prepare_typed(sql, [])
}

///|
/// Prepare a statement with explicit parameter types.
///
/// Explicit types are useful when PostgreSQL cannot infer parameter OIDs from
/// context or when the caller wants deterministic server-side coercion.
pub async fn Client::prepare_typed(
  self : Client,
  sql : String,
  types : Array[Type],
) -> Statement {
  self.run_operation(context => context.prepare_typed(sql, types))
}

///|
async fn OpContext::prepare_typed(
  self : OpContext,
  sql : String,
  types : Array[Type],
) -> Statement {
  let name = next_name(self.client.shared, "s")
  let bytes = prepare_bytes(name[:], sql, types)
  let responses = self.client.send_request(Messages, bytes)
  let (params, columns) = read_prepare_response(self, responses)
  { client: self.client, name, params, columns, closed: @ref.new(false) }
}

///|
/// Close the prepared statement on the server.
///
/// Closing is idempotent on the client side; repeated calls are ignored after
/// the first successful close.
pub async fn Statement::close(self : Statement) -> Unit {
  if self.closed.val {
    return
  }
  self.client.run_operation(context => context.close_statement(self))
}

///|
async fn OpContext::close_statement(
  self : OpContext,
  statement : Statement,
) -> Unit {
  if statement.closed.val {
    return
  }
  let responses = self.client.send_request(
    Messages,
    close_bytes(b'S', statement.name[:]),
  )
  drain_close_response(responses)
  statement.closed.val = true
}

///|
/// Prepare and execute a query, returning rows through an incremental stream.
///
/// This helper uses a temporary unnamed prepared statement under the hood so it
/// can fetch resolved parameter and column metadata before execution. The
/// temporary statement is closed automatically once the returned stream is fully
/// drained or `finish` is called.
///
/// Warning: if you stop consuming the returned stream early and want to discard
/// it, call `detach()` before dropping the handle. Otherwise later requests on
/// the same connection can remain blocked until the unfinished response is
/// drained.
pub async fn Client::query(
  self : Client,
  sql : String,
  params? : Array[&ToSql] = [],
) -> RowStream {
  let (context, permit) = self.begin_stream_operation()
  let completed : @ref.Ref[RowStream?] = @ref.new(None)
  @async.protect_from_cancel(
    () => {
      let stream = context.query(sql, params, permit~)
      completed.val = Some(stream)
      stream
    },
    resume_on_cancel=true,
  ) catch {
    err => {
      match completed.val {
        Some(stream) => stream.detach()
        None => permit.release()
      }
      raise err
    }
  }
}

///|
async fn OpContext::query(
  self : OpContext,
  sql : String,
  params : Array[&ToSql],
  permit? : OperationPermit,
) -> RowStream {
  let name = next_name(self.client.shared, "q")
  // Use a temporary named statement so the driver can learn PostgreSQL's
  // resolved parameter and result metadata before execution starts.
  let prepare_responses = self.client.send_request(
    Messages,
    prepare_bytes(name[:], sql, []),
  )
  let (param_types, columns) = read_prepare_response(self, prepare_responses)
  guard param_types.length() == params.length() else {
    // Preparation already created server-side state, so close it even though
    // execution never begins.
    let _ = close_temporary_statement(self, name) catch { _ => () }
    raise ClientError::Encode(
      "parameter count mismatch: expected \{param_types.length().to_string()}, got \{params.length().to_string()}",
    )
  }
  let responses = self.client.send_request(
    Messages,
    execute_statement_bytes(name[:], param_types, params),
  )
  // Cleanup is deferred onto the returned stream because closing the temporary
  // statement early would interleave a second request before this one finishes.
  new_row_stream(
    self.client.shared.background_group,
    responses,
    permit,
    initial_columns=columns,
    cleanup=Some(make_statement_cleanup(self, name)),
  )
}

///|
/// Execute a query and require exactly one row.
///
/// This helper fully drains the underlying stream so temporary resources are
/// always cleaned up, even when the row-count assertion fails.
pub async fn Client::query_one(
  self : Client,
  sql : String,
  params? : Array[&ToSql] = [],
) -> Row {
  self.query(sql, params~).one()
}

///|
/// Execute a query and require zero or one row.
pub async fn Client::query_opt(
  self : Client,
  sql : String,
  params? : Array[&ToSql] = [],
) -> Row? {
  self.query(sql, params~).opt()
}

///|
/// Execute a query with explicit parameter types.
///
/// This skips PostgreSQL's parameter-type inference path and is the most direct
/// way to run an extended query when the caller already knows the desired OIDs.
pub async fn Client::query_typed(
  self : Client,
  sql : String,
  param_types : Array[Type],
  params? : Array[&ToSql] = [],
) -> RowStream {
  let (context, permit) = self.begin_stream_operation()
  let completed : @ref.Ref[RowStream?] = @ref.new(None)
  @async.protect_from_cancel(
    () => {
      let stream = context.query_typed(sql, param_types, params, permit~)
      completed.val = Some(stream)
      stream
    },
    resume_on_cancel=true,
  ) catch {
    err => {
      match completed.val {
        Some(stream) => stream.detach()
        None => permit.release()
      }
      raise err
    }
  }
}

///|
async fn OpContext::query_typed(
  self : OpContext,
  sql : String,
  param_types : Array[Type],
  params : Array[&ToSql],
  permit? : OperationPermit,
) -> RowStream {
  guard param_types.length() == params.length() else {
    raise ClientError::Encode(
      "parameter count mismatch: expected \{param_types.length().to_string()}, got \{params.length().to_string()}",
    )
  }
  let name = next_name(self.client.shared, "q")
  let prepare_responses = self.client.send_request(
    Messages,
    prepare_bytes(name[:], sql, param_types),
  )
  let (_, columns) = read_prepare_response(self, prepare_responses)
  let responses = self.client.send_request(
    Messages,
    execute_statement_bytes(name[:], param_types, params),
  )
  new_row_stream(
    self.client.shared.background_group,
    responses,
    permit,
    initial_columns=columns,
    cleanup=Some(make_statement_cleanup(self, name)),
  )
}

///|
/// Execute a previously prepared statement and return a row stream.
///
/// Unlike `query`, this reuses a named prepared statement and therefore does
/// not attach deferred cleanup to the returned stream.
pub async fn Client::query_statement(
  self : Client,
  statement : Statement,
  params? : Array[&ToSql] = [],
) -> RowStream {
  let (context, permit) = self.begin_stream_operation()
  context.query_statement(statement, params, permit~) catch {
    err => {
      permit.release()
      raise err
    }
  }
}

///|
fn OpContext::query_statement(
  self : OpContext,
  statement : Statement,
  params : Array[&ToSql],
  permit? : OperationPermit,
) -> RowStream raise {
  guard !statement.closed.val else {
    raise ClientError::Closed("statement already closed")
  }
  guard statement.params.length() == params.length() else {
    raise ClientError::Encode(
      "parameter count mismatch: expected \{statement.params.length().to_string()}, got \{params.length().to_string()}",
    )
  }
  let responses = self.client.send_request(
    Messages,
    execute_statement_bytes(statement.name[:], statement.params, params),
  )
  new_row_stream(
    self.client.shared.background_group,
    responses,
    permit,
    initial_columns=statement.columns,
  )
}

///|
/// Execute SQL and return the affected row count.
///
/// This convenience helper prepares a temporary statement, executes it once,
/// waits for completion, and then closes the prepared statement.
pub async fn Client::execute(
  self : Client,
  sql : String,
  params? : Array[&ToSql] = [],
) -> Int {
  self.run_operation(context => context.execute(sql, params))
}

///|
async fn OpContext::execute(
  self : OpContext,
  sql : String,
  params : Array[&ToSql],
) -> Int {
  let statement = self.prepare_typed(sql, [])
  let rows = self.execute_raw(statement, params) catch {
    err => {
      let _ = self.close_statement(statement) catch { _ => () }
      raise err
    }
  }
  self.close_statement(statement)
  rows
}

///|
/// Execute a prepared statement and return the affected row count.
///
/// The result stream is drained internally so the command tag can be parsed and
/// converted into a numeric row count.
pub async fn Client::execute_raw(
  self : Client,
  statement : Statement,
  params? : Array[&ToSql] = [],
) -> Int {
  self.run_operation(context => context.execute_raw(statement, params))
}

///|
async fn OpContext::execute_raw(
  self : OpContext,
  statement : Statement,
  params : Array[&ToSql],
) -> Int {
  let stream = self.query_statement(statement, params)
  let summary = stream.finish()
  rows_affected(summary.command_tag)
}

///|
/// Bind parameters to a prepared statement and create a server-side portal.
///
/// Portals are primarily useful for chunked fetching with `query_portal` or for
/// separating parameter binding from later execution.
pub async fn Client::bind(
  self : Client,
  statement : Statement,
  params? : Array[&ToSql] = [],
) -> Portal {
  self.run_operation(context => context.bind(statement, params))
}

///|
async fn OpContext::bind(
  self : OpContext,
  statement : Statement,
  params : Array[&ToSql],
) -> Portal {
  guard !statement.closed.val else {
    raise ClientError::Closed("statement already closed")
  }
  guard statement.params.length() == params.length() else {
    raise ClientError::Encode(
      "parameter count mismatch: expected \{statement.params.length().to_string()}, got \{params.length().to_string()}",
    )
  }
  let name = next_name(self.client.shared, "p")
  let responses = self.client.send_request(
    Messages,
    bind_portal_bytes(name[:], statement.name[:], statement.params, params),
  )
  let mut columns = statement.columns
  // PostgreSQL may refine the visible row description at bind time, so start
  // from the prepared statement's shape and patch it if the server sends one.
  let mut database_error : DatabaseError? = None
  for res = responses.get() {
    match res {
      BindComplete => continue responses.get()
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
        match database_error {
          Some(err) => raise ClientError::Database(err)
          None => {
            let portal = Portal::{
              client: self.client,
              name,
              // Resolve column OIDs lazily here so callers still get enriched
              // type descriptors even when portals are bound later.
              columns: resolve_columns(self, columns),
              closed: @ref.new(false),
            }
            break portal
          }
        }
      _ =>
        fail_response_stream(
          responses,
          ClientError::UnexpectedMessage("unexpected bind response"),
        )
    }
  }
}

///|
/// Close the portal on the server.
pub async fn Portal::close(self : Portal) -> Unit {
  if self.closed.val {
    return
  }
  self.client.run_operation(context => context.close_portal(self))
}

///|
async fn OpContext::close_portal(self : OpContext, portal : Portal) -> Unit {
  if portal.closed.val {
    return
  }
  let responses = self.client.send_request(
    Messages,
    close_bytes(b'P', portal.name[:]),
  )
  drain_close_response(responses)
  portal.closed.val = true
}

///|
/// Execute a portal and stream up to `max_rows` rows.
///
/// When PostgreSQL suspends the portal because the limit was reached, the
/// returned `RowStream` reports that via `QuerySummary.suspended`.
pub async fn Client::query_portal(
  self : Client,
  portal : Portal,
  max_rows : Int,
) -> RowStream {
  let (context, permit) = self.begin_stream_operation()
  context.query_portal(portal, max_rows, permit~) catch {
    err => {
      permit.release()
      raise err
    }
  }
}

///|
fn OpContext::query_portal(
  self : OpContext,
  portal : Portal,
  max_rows : Int,
  permit? : OperationPermit,
) -> RowStream raise {
  guard !portal.closed.val else {
    raise ClientError::Closed("portal already closed")
  }
  let responses = self.client.send_request(
    Messages,
    execute_portal_bytes(portal.name[:], max_rows),
  )
  new_row_stream(
    self.client.shared.background_group,
    responses,
    permit,
    initial_columns=portal.columns,
  )
}
