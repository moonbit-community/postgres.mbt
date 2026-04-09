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
  responses : @async.Queue[@backend.Message]
  mut columns : Array[String]
  mut database_error : DatabaseError?
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
  if self.finished {
    return self.raise_terminal_error_or_none()
  }
  for response = self.responses.get() {
    match response {
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
  for msg = self.next() {
    match msg {
      Some(_) => continue self.next()
      None => break ()
    }
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
