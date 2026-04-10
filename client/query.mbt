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
pub fn Client::simple_query(
  self : Client,
  sql : String,
) -> SimpleQueryStream raise {
  ensure_open(self.shared)
  let responses = self.send_request(
    RequestKind::Messages,
    simple_query_bytes(sql),
  )
  new_simple_query_stream(self.shared.background_group, responses)
}

///|
/// Execute one or more SQL commands and discard any returned rows.
///
/// This is the simplest helper for commands such as schema setup or session
/// configuration where only protocol completion matters.
pub async fn Client::batch_execute(self : Client, sql : String) -> Unit {
  ensure_open(self.shared)
  let responses = self.send_request(
    RequestKind::Messages,
    simple_query_bytes(sql),
  )
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
  ensure_open(self.shared)
  let name = next_name(self.shared, "s")
  let bytes = prepare_bytes(name[:], sql, types)
  let responses = self.send_request(RequestKind::Messages, bytes)
  let (params, columns) = read_prepare_response(self.shared, responses)
  { client: self, name, params, columns, closed: @ref.new(false) }
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
  let responses = self.client.send_request(
    RequestKind::Messages,
    close_bytes(b'S', self.name[:]),
  )
  drain_close_response(responses)
  self.closed.val = true
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
  ensure_open(self.shared)
  let name = next_name(self.shared, "q")
  // Use a temporary named statement so the driver can learn PostgreSQL's
  // resolved parameter and result metadata before execution starts.
  let prepare_responses = self.send_request(
    RequestKind::Messages,
    prepare_bytes(name[:], sql, []),
  )
  let (param_types, columns) = read_prepare_response(
    self.shared,
    prepare_responses,
  )
  guard param_types.length() == params.length() else {
    // Preparation already created server-side state, so close it even though
    // execution never begins.
    let _ = close_temporary_statement(self, name) catch { _ => () }
    raise ClientError::Encode(
      "parameter count mismatch: expected \{param_types.length().to_string()}, got \{params.length().to_string()}",
    )
  }
  let responses = self.send_request(
    RequestKind::Messages,
    execute_statement_bytes(name[:], param_types, params),
  )
  // Cleanup is deferred onto the returned stream because closing the temporary
  // statement early would interleave a second request before this one finishes.
  new_row_stream(
    self.shared.background_group,
    responses,
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
  let stream = self.query(sql, params~)
  let first = stream.next()
  // Always drain to the terminal ready state so temporary statement cleanup and
  // row-count validation see the full server outcome.
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
/// Execute a query and require zero or one row.
pub async fn Client::query_opt(
  self : Client,
  sql : String,
  params? : Array[&ToSql] = [],
) -> Row? {
  let stream = self.query(sql, params~)
  let first = stream.next()
  // `query_opt` shares the same full-drain requirement as `query_one`; without
  // it, the temporary statement and final row count would remain unresolved.
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
///
/// This skips PostgreSQL's parameter-type inference path and is the most direct
/// way to run an extended query when the caller already knows the desired OIDs.
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
    self.shared.background_group,
    responses,
    initial_columns=columns,
    cleanup=Some(make_statement_cleanup(self, name)),
  )
}

///|
/// Backward-compatible alias for `query_typed`.
pub async fn Client::query_typed_raw(
  self : Client,
  sql : String,
  param_types : Array[Type],
  params? : Array[&ToSql] = [],
) -> RowStream {
  self.query_typed(sql, param_types, params~)
}

///|
/// Execute a previously prepared statement and return a row stream.
///
/// Unlike `query`, this reuses a named prepared statement and therefore does
/// not attach deferred cleanup to the returned stream.
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
  new_row_stream(
    self.shared.background_group,
    responses,
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
  let statement = self.prepare(sql)
  // Route through the named-statement path so success and failure share one
  // close policy and one row-count extraction path.
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
///
/// The result stream is drained internally so the command tag can be parsed and
/// converted into a numeric row count.
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
/// Bind parameters to a prepared statement and create a server-side portal.
///
/// Portals are primarily useful for chunked fetching with `query_portal` or for
/// separating parameter binding from later execution.
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
  // PostgreSQL may refine the visible row description at bind time, so start
  // from the prepared statement's shape and patch it if the server sends one.
  let mut database_error : DatabaseError? = None
  for res = responses.get() {
    match res {
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
          None => {
            let portal = Portal::{
              client: self,
              name,
              // Resolve column OIDs lazily here so callers still get enriched
              // type descriptors even when portals are bound later.
              columns: resolve_columns(self.shared, columns),
              closed: @ref.new(false),
            }
            break portal
          }
        }
      _ => raise ClientError::UnexpectedMessage("unexpected bind response")
    }
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
///
/// When PostgreSQL suspends the portal because the limit was reached, the
/// returned `RowStream` reports that via `QuerySummary.suspended`.
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
  new_row_stream(
    self.shared.background_group,
    responses,
    initial_columns=portal.columns,
  )
}
