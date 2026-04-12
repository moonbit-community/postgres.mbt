// COPY IN / COPY OUT helpers.

///|
/// Start a `COPY ... TO STDOUT` operation and return a raw chunk stream.
///
/// The SQL string is executed with the simple query protocol because PostgreSQL
/// starts COPY mode directly from the statement text.
///
/// Warning: if you stop consuming the returned stream early and want to discard
/// it, call `detach()` before dropping the handle. Otherwise later requests on
/// the same connection can remain blocked until the unfinished response is
/// drained.
pub async fn Client::copy_out(self : Client, sql : String) -> CopyOutStream {
  ensure_open(self.shared)
  let responses = self.send_request(
    RequestKind::Messages,
    simple_query_bytes(sql),
  )
  start_copy_out(self.shared.background_group, responses)
}

///|
/// Start a `COPY ... FROM STDIN` operation and return a sink for input chunks.
///
/// The returned `CopyInSink` can be fed from another task while the connection
/// loop relays backend progress and completion messages.
pub async fn Client::copy_in(self : Client, sql : String) -> CopyInSink {
  ensure_open(self.shared)
  let input = @async.Queue::new(kind=Unbounded)
  let responses = self.send_request_with_copy(simple_query_bytes(sql), input)
  let mut database_error : DatabaseError? = None
  for res = responses.get() {
    match res {
      @backend.Message::CopyInResponse(_) =>
        // The producer side queue is usable only after PostgreSQL explicitly
        // switches this request into COPY FROM STDIN mode.
        return { input, responses, finished: @ref.new(false) }
      @backend.Message::ErrorResponse(body) => {
        // COPY startup failures still drain until `ReadyForQuery`, mirroring
        // the delayed-error behavior of the other streaming helpers.
        database_error = Some(parse_database_error(body.fields()))
        continue responses.get()
      }
      @backend.Message::ReadyForQuery(_) =>
        match database_error {
          Some(err) => raise ClientError::Database(err)
          None =>
            raise ClientError::UnexpectedMessage("expected CopyInResponse")
        }
      _ => raise ClientError::UnexpectedMessage("unexpected copy-in response")
    }
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
///
/// After calling `finish`, the sink cannot be reused. The method waits for the
/// backend's command-complete sequence and converts its command tag to an
/// integer row count.
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
///
/// PostgreSQL still sends a completion sequence after an abort. The driver
/// drains it internally and suppresses the returned row count because the COPY
/// did not complete successfully.
pub async fn CopyInSink::abort(
  self : CopyInSink,
  message? : String = "COPY aborted",
) -> Unit {
  guard !self.finished.val else { return }
  self.finished.val = true
  self.input.put(CopyInAction::Fail(message))
  // Abort is best-effort from the caller's perspective: once `CopyFail` is
  // queued, only protocol cleanup remains and its row count is irrelevant.
  let _ = collect_copy_in_completion(self.responses) catch { _ => 0 }
}

///|
/// Payload of PostgreSQL `NotificationResponse`.
pub struct Notification {
  /// Backend process ID that sent the notification.
  process_id : Int
  /// Channel name from `LISTEN` / `NOTIFY`.
  channel : String
  /// Optional payload string attached to the notification.
  payload : String
} derive(Debug, Eq)

///|
/// Message delivered out-of-band from the main request/response flow.
///
/// These messages are emitted by the connection loop through the optional
/// callback passed to `Connection::run` and can also be consumed later via
/// `Connection::next_message`. In practice, pick one primary consumption style:
/// pass `on_async` when you want push-style handling during `run`, or dedicate
/// one reader task to `next_message` when you want pull-style handling.
pub enum AsyncMessage {
  /// Server notice that did not fail the active request.
  Notice(DatabaseError)
  /// `NOTIFY` payload from PostgreSQL.
  Notification(Notification)
  /// Session parameter update such as `server_version`.
  ParameterStatus(String, String)
} derive(Debug, Eq)

///|
/// Stream of raw chunks produced by `COPY ... TO STDOUT`.
///
/// The client does not attempt to decode the copy format. It simply surfaces
/// each `CopyData` payload exactly as received so higher-level code can parse
/// CSV, text, or binary COPY output as needed.
pub struct CopyOutStream {
  priv background_group : @ref.Ref[@async.TaskGroup[Unit]?]
  priv responses : @async.Queue[@backend.Message]
  /// Column wire formats reported by PostgreSQL's `CopyOutResponse`.
  formats : Array[WireFormat]
  priv mut database_error : DatabaseError?
  priv mut detached : Bool
  priv mut finished : Bool
}

///|
/// Read the next COPY OUT payload chunk.
pub async fn CopyOutStream::next(self : CopyOutStream) -> Bytes? {
  self.assert_attached()
  if self.finished {
    return self.raise_terminal_error_or_none()
  }
  for response = self.responses.get() {
    match response {
      @backend.Message::CopyData(body) => return Some(body.storage)
      @backend.Message::CopyDone | @backend.Message::CommandComplete(_) =>
        // Completion frames are internal to COPY bookkeeping; the public API
        // only exposes raw data chunks and the final success/error outcome.
        continue self.responses.get()
      @backend.Message::ErrorResponse(body) => {
        self.database_error = Some(parse_database_error(body.fields()))
        continue self.responses.get()
      }
      @backend.Message::ReadyForQuery(_) => {
        // `ReadyForQuery` is the point where COPY mode has fully unwound and
        // the connection can safely accept ordinary requests again.
        self.finished = true
        return self.raise_terminal_error_or_none()
      }
      _ =>
        fail_response_stream(
          self.responses,
          ClientError::UnexpectedMessage("unexpected copy out response"),
        )
    }
  }
}

///|
/// Collect all remaining COPY OUT chunks into memory.
pub async fn CopyOutStream::collect(self : CopyOutStream) -> Array[Bytes] {
  let chunks : Array[Bytes] = []
  for chunk = self.next() {
    match chunk {
      None => break chunks
      Some(chunk) => {
        chunks.push(chunk)
        continue self.next()
      }
    }
  }
}

///|
/// Drain the COPY OUT stream to its terminal `ReadyForQuery`.
pub async fn CopyOutStream::finish(self : CopyOutStream) -> Unit {
  for bytes = self.next() {
    if bytes is Some(_) {
      continue self.next()
    } else {
      break ()
    }
  }
}

///|
/// Explicitly abandon the remaining COPY OUT payloads.
///
/// This starts a background drain that discards `CopyData` frames so later
/// requests can continue without waiting for synchronous completion.
pub fn CopyOutStream::detach(self : CopyOutStream) -> Unit {
  if self.finished || self.detached {
    return
  }
  self.detached = true
  spawn_detached_drain(self.background_group, () => self.drain_discard())
}

///|
/// Drain the remaining COPY OUT protocol messages without buffering payloads.
async fn CopyOutStream::drain_discard(self : CopyOutStream) -> Unit {
  if self.finished {
    match self.database_error {
      Some(err) => raise ClientError::Database(err)
      None => return
    }
  }
  for response = self.responses.get() {
    match response {
      @backend.Message::CopyDone | @backend.Message::CommandComplete(_) =>
        continue self.responses.get()
      @backend.Message::CopyData(_) =>
        // Detached drains intentionally throw away raw COPY payloads while
        // keeping the request moving toward its terminal ready state.
        continue self.responses.get()
      @backend.Message::ErrorResponse(body) => {
        self.database_error = Some(parse_database_error(body.fields()))
        continue self.responses.get()
      }
      @backend.Message::ReadyForQuery(_) => {
        self.finished = true
        match self.database_error {
          Some(err) => raise ClientError::Database(err)
          None => return
        }
      }
      _ =>
        fail_response_stream(
          self.responses,
          ClientError::UnexpectedMessage("unexpected copy out response"),
        )
    }
  }
}

///|
/// Fail if the stream was already detached into a background drain.
fn CopyOutStream::assert_attached(self : CopyOutStream) -> Unit raise {
  if self.detached {
    raise ClientError::Closed("copy out stream already detached")
  }
}

///|
/// Return the captured database error, or `None` once the stream is finished.
fn CopyOutStream::raise_terminal_error_or_none(
  self : CopyOutStream,
) -> Bytes? raise {
  match self.database_error {
    Some(err) => raise ClientError::Database(err)
    None => None
  }
}
