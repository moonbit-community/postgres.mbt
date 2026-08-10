// Result stream types for PostgreSQL's simple query protocol.

///|
/// One row emitted by `SimpleQueryStream`.
///
/// Simple-query rows always carry text-format values because PostgreSQL's
/// simple query protocol does not support selecting per-column binary formats.
pub struct SimpleQueryRow {
  /// Column labels from the most recent `RowDescription`.
  columns : Array[String]
  /// Text values for the row. `None` represents SQL `NULL`.
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
/// One frame emitted by the simple query protocol.
///
/// The protocol can interleave row descriptions, rows, and command-complete
/// messages when a SQL string contains multiple statements, so the stream
/// surfaces all three explicitly.
pub enum SimpleQueryMessage {
  /// Announces the column labels for subsequent `Row` messages.
  RowDescription(Array[String])
  /// One result row in text format.
  Row(SimpleQueryRow)
  /// Terminal message for one statement inside the simple-query batch.
  CommandComplete(String)
} derive(Debug, Eq)

///|
/// Incremental stream of `SimpleQueryMessage` values.
struct SimpleQueryStream {
  background_group : @ref.Ref[@async.TaskGroup[Unit]?]
  responses : @async.Queue[@backend.Message]
  permit : OperationPermit?
  mut columns : Array[String]
  mut database_error : DatabaseError?
  mut detached : Bool
  mut detached_task : @async.Task[Unit]?
  mut finished : Bool
}

///|
/// Read the next simple-query message.
///
/// The stream records database errors when it sees `ErrorResponse`, but delays
/// raising them until the terminal `ReadyForQuery` so the server and driver stay
/// in sync with the protocol.
pub async fn SimpleQueryStream::next(
  self : SimpleQueryStream,
) -> SimpleQueryMessage? {
  self.next_inner() catch {
    err => {
      self.abandon_after_error()
      raise err
    }
  }
}

///|
async fn SimpleQueryStream::next_inner(
  self : SimpleQueryStream,
) -> SimpleQueryMessage? {
  self.assert_attached()
  if self.finished {
    return self.raise_terminal_error_or_none()
  }
  for response = self.responses.get() {
    match response {
      RowDescription(body) => {
        // Each statement inside a simple-query batch can introduce a fresh row
        // shape, so later `DataRow` frames read from this updated column list.
        self.columns = parse_column_names(body)
        return Some(RowDescription(self.columns))
      }
      DataRow(body) => return Some(Row(parse_text_row(body, self.columns)))
      CommandComplete(body) => {
        // Command completion also ends the current row shape; a following
        // statement in the same batch may describe different columns.
        self.columns = []
        return Some(CommandComplete(body.tag_str()))
      }
      EmptyQueryResponse => {
        self.columns = []
        return Some(CommandComplete(""))
      }
      ErrorResponse(body) => {
        // Keep draining until the terminal ready state so the connection and
        // caller stay synchronized even when one statement fails mid-batch.
        self.database_error = Some(parse_database_error(body.fields()))
        continue self.responses.get()
      }
      ReadyForQuery(_) => {
        // The simple-query batch is complete only after the final ready frame.
        self.finished = true
        self.release_permit()
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
  if self.detached {
    match self.detached_task {
      Some(task) => task.wait()
      None => ()
    }
    ignore(self.raise_terminal_error_or_none())
    return
  }
  for msg = self.next() {
    match msg {
      Some(_) => continue self.next()
      None => break ()
    }
  }
}

///|
/// Explicitly abandon the remaining simple-query frames.
///
/// The driver drains to the terminal `ReadyForQuery` in a background coroutine
/// so later requests can continue without waiting for synchronous completion.
pub fn SimpleQueryStream::detach(self : SimpleQueryStream) -> Unit {
  if self.finished || self.detached {
    return
  }
  self.start_detached_drain()
}

///|
fn SimpleQueryStream::start_detached_drain(self : SimpleQueryStream) -> Unit {
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
fn SimpleQueryStream::abandon_after_error(self : SimpleQueryStream) -> Unit {
  if self.finished {
    self.release_permit()
  } else if !self.detached {
    self.start_detached_drain()
  }
}

///|
/// Drain the remaining protocol frames without constructing row values.
async fn SimpleQueryStream::drain_discard(self : SimpleQueryStream) -> Unit {
  if self.finished {
    match self.database_error {
      Some(err) => raise ClientError::Database(err)
      None => return
    }
  }
  for response = self.responses.get() {
    match response {
      RowDescription(_) | CommandComplete(_) | EmptyQueryResponse =>
        continue self.responses.get()
      DataRow(_) =>
        // Detached drains discard row payloads but still have to consume them
        // so later statements in the same batch can make progress.
        continue self.responses.get()
      ErrorResponse(body) => {
        self.database_error = Some(parse_database_error(body.fields()))
        continue self.responses.get()
      }
      ReadyForQuery(_) => {
        self.finished = true
        self.release_permit()
        match self.database_error {
          Some(err) => raise ClientError::Database(err)
          None => return
        }
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
fn SimpleQueryStream::release_permit(self : SimpleQueryStream) -> Unit {
  match self.permit {
    Some(permit) => permit.release()
    None => ()
  }
}

///|
/// Fail if the stream was already detached into a background drain.
fn SimpleQueryStream::assert_attached(self : SimpleQueryStream) -> Unit raise {
  if self.detached {
    raise ClientError::Closed("simple query stream already detached")
  }
}

///|
/// Return the captured database error, or `None` once the stream is finished.
fn SimpleQueryStream::raise_terminal_error_or_none(
  self : SimpleQueryStream,
) -> SimpleQueryMessage? raise {
  match self.database_error {
    Some(err) => raise ClientError::Database(err)
    None => None
  }
}
