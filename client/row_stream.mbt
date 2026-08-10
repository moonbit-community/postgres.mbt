// Streaming results for the extended query protocol.

///|
/// Final summary reported after an extended query stream is fully drained.
pub struct QuerySummary {
  /// Raw PostgreSQL command tag, for example `"INSERT 0 3"` or `"SELECT 1"`.
  command_tag : String
  /// Number of `DataRow` messages observed by the stream.
  row_count : Int
  /// Whether the server suspended a portal because of a row limit.
  suspended : Bool
} derive(Debug, Eq)

///|
/// Incremental stream of rows produced by the extended query protocol.
///
/// The stream owns the queue of backend messages for one request. Temporary
/// statements created by helper APIs are cleaned up only after the stream
/// reaches its terminal `ReadyForQuery`, so callers should either consume the
/// stream to exhaustion, call `finish`, or call `detach`.
pub struct RowStream {
  /// The latest resolved column metadata. This becomes available after the
  /// driver sees a `RowDescription`.
  mut columns : Array[Column]
  priv background_group : @ref.Ref[@async.TaskGroup[Unit]?]
  priv responses : @async.Queue[@backend.Message]
  priv cleanup : StreamCleanup?
  priv permit : OperationPermit?
  priv mut command_tag : String
  priv mut row_count : Int
  priv mut suspended : Bool
  priv mut database_error : DatabaseError?
  priv mut detached : Bool
  priv mut detached_task : @async.Task[Unit]?
  priv mut summary : QuerySummary?
}

///|
/// Read the next row from the stream.
///
/// On the terminal `ReadyForQuery`, the stream records its summary, runs any
/// deferred cleanup, and then either raises the captured database error or
/// returns `None`.
pub async fn RowStream::next(self : RowStream) -> Row? {
  self.next_inner() catch {
    err => {
      self.abandon_after_error()
      raise err
    }
  }
}

///|
async fn RowStream::next_inner(self : RowStream) -> Row? {
  self.assert_attached()
  match self.summary {
    Some(_) => return self.raise_terminal_error_or_none()
    None => ()
  }
  for res = self.responses.get() {
    match res {
      ParseComplete | BindComplete | CloseComplete | ParameterDescription(_) =>
        // Setup/bookkeeping frames do not carry row payloads once the stream is
        // active, so readers can skip them transparently.
        continue self.responses.get()
      NoData => continue self.responses.get()
      RowDescription(body) => {
        // Execution may repeat column metadata. Merge it so previously resolved
        // rich types survive while protocol consistency is still checked.
        self.columns = merge_stream_columns(self.columns, body)
        continue self.responses.get()
      }
      DataRow(body) => {
        self.row_count += 1
        // Rows must copy their field bytes now because the backend message
        // buffer does not outlive this iteration step.
        return Some({ columns: self.columns, values: parse_binary_values(body) })
      }
      CommandComplete(body) => {
        self.command_tag = body.tag_str()
        continue self.responses.get()
      }
      PortalSuspended => {
        self.suspended = true
        continue self.responses.get()
      }
      ErrorResponse(body) => {
        // PostgreSQL may still send the terminal ready message after an error,
        // so remember the failure but keep draining until the request ends.
        self.database_error = Some(parse_database_error(body.fields()))
        continue self.responses.get()
      }
      ReadyForQuery(_) => {
        self.summary = Some({
          command_tag: self.command_tag,
          row_count: self.row_count,
          suspended: self.suspended,
        })
        // Temporary statements are only safe to close once this request has
        // fully relinquished ownership of the connection timeline.
        defer self.release_permit()
        @async.protect_from_cancel(
          () => self.run_cleanup(),
          resume_on_cancel=true,
        )
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
///
/// This is a convenience wrapper over repeated `next` calls. It still drains
/// the underlying protocol stream and therefore runs the same cleanup logic as
/// manual iteration.
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
/// Require exactly one row and fully drain the stream.
pub async fn RowStream::one(self : RowStream) -> Row {
  let first = self.next()
  let summary = self.finish()
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
/// Require zero or one row and fully drain the stream.
pub async fn RowStream::opt(self : RowStream) -> Row? {
  let first = self.next()
  let summary = self.finish()
  guard summary.row_count <= 1 else {
    raise ClientError::RowCount(
      "expected zero or one row, got \{summary.row_count.to_string()}",
    )
  }
  first
}

///|
/// Drain the stream and return the final query summary.
///
/// Use this when you only need a prefix of the rows but still want the driver
/// to observe the terminal `ReadyForQuery`, release backpressure, and execute
/// deferred cleanup such as closing temporary statements.
pub async fn RowStream::finish(self : RowStream) -> QuerySummary {
  if self.detached {
    match self.detached_task {
      Some(task) => task.wait()
      None => ()
    }
    ignore(self.raise_terminal_error_or_none())
    return self.summary.unwrap()
  }
  for row = self.next() {
    match row {
      Some(_) => continue self.next()
      None => break self.summary.unwrap()
    }
  }
}

///|
/// Explicitly abandon the remaining rows and drain in the background.
///
/// Unlike `finish`, this returns immediately and does not decode discarded row
/// payloads. Use it when later requests should be allowed to make progress
/// without waiting for synchronous completion of the current stream.
pub fn RowStream::detach(self : RowStream) -> Unit {
  if self.summary is Some(_) || self.detached {
    return
  }
  self.start_detached_drain()
}

///|
fn RowStream::start_detached_drain(self : RowStream) -> Unit {
  self.detached = true
  self.detached_task = spawn_detached_drain(self.background_group, () => {
    defer self.release_permit()
    self.drain_discard()
  })
  if self.detached_task is None {
    self.release_permit()
  }
}

///|
fn RowStream::abandon_after_error(self : RowStream) -> Unit {
  if self.summary is Some(_) {
    self.release_permit()
  } else if !self.detached {
    self.start_detached_drain()
  }
}

///|
/// Run deferred cleanup once the stream reaches its terminal state.
///
/// Temporary statements created by helper APIs are closed lazily here so the
/// driver never interrupts the active request while rows are still in flight.
async fn RowStream::run_cleanup(self : RowStream) -> Unit {
  match self.cleanup {
    Some(cleanup) =>
      if !cleanup.done {
        cleanup.done = true
        // Deferred cleanup is modeled as another request inside the same
        // logical-operation permit.
        let responses = cleanup.context.client.send_request(
          Messages,
          cleanup.bytes,
        )
        drain_close_response(responses)
      }
    None => ()
  }
}

///|
/// Drain the remaining protocol messages while discarding row payloads.
///
/// This path keeps only the minimum terminal-state bookkeeping needed for
/// command tags, portal suspension, deferred cleanup, and delayed database
/// errors. It intentionally skips `DataRow` decoding and row allocation.
async fn RowStream::drain_discard(self : RowStream) -> Unit {
  match self.summary {
    Some(_) => ()
    None =>
      for res = self.responses.get() {
        match res {
          ParseComplete
          | BindComplete
          | CloseComplete
          | ParameterDescription(_)
          | NoData
          | RowDescription(_) => continue self.responses.get()
          DataRow(_) => {
            // Detached drains intentionally skip row decoding because the
            // caller can no longer observe individual payloads. They still
            // contribute to the final summary's observed row count.
            self.row_count += 1
            continue self.responses.get()
          }
          CommandComplete(body) => {
            self.command_tag = body.tag_str()
            continue self.responses.get()
          }
          PortalSuspended => {
            self.suspended = true
            continue self.responses.get()
          }
          ErrorResponse(body) => {
            self.database_error = Some(parse_database_error(body.fields()))
            continue self.responses.get()
          }
          ReadyForQuery(_) => {
            self.summary = Some({
              command_tag: self.command_tag,
              row_count: self.row_count,
              suspended: self.suspended,
            })
            // Detached drains still run cleanup so temporary statements do not
            // leak on the server after the caller stops waiting.
            defer self.release_permit()
            @async.protect_from_cancel(
              () => self.run_cleanup(),
              resume_on_cancel=true,
            )
            match self.database_error {
              Some(err) => raise ClientError::Database(err)
              None => return
            }
          }
          _ =>
            fail_response_stream(
              self.responses,
              ClientError::UnexpectedMessage("unexpected query response"),
            )
        }
      }
  }
}

///|
fn RowStream::release_permit(self : RowStream) -> Unit {
  match self.permit {
    Some(permit) => permit.release()
    None => ()
  }
}

///|
/// Fail if the stream was already detached into a background drain.
fn RowStream::assert_attached(self : RowStream) -> Unit raise {
  if self.detached {
    raise ClientError::Closed("row stream already detached")
  }
}

///|
/// Return the captured database error, or `None` once the stream is finished.
fn RowStream::raise_terminal_error_or_none(self : RowStream) -> Row? raise {
  match self.database_error {
    Some(err) => raise ClientError::Database(err)
    None => None
  }
}
