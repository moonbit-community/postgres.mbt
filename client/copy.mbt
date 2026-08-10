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
  let (_context, permit) = self.begin_stream_operation()
  let completed : @ref.Ref[CopyOutStream?] = @ref.new(None)
  @async.protect_from_cancel(
    () => {
      let responses = self.send_request(Messages, simple_query_bytes(sql))
      let stream = start_copy_out(
        self.shared.background_group,
        responses,
        Some(permit),
      )
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
/// Start a `COPY ... FROM STDIN` operation and return a sink for input chunks.
///
/// The returned `CopyInSink` can be fed from another task while the connection
/// loop relays backend progress and completion messages.
pub async fn Client::copy_in(self : Client, sql : String) -> CopyInSink {
  let (_context, permit) = self.begin_stream_operation()
  let input = @async.Queue(kind=Blocking(8))
  let responses = self.send_request_with_copy(simple_query_bytes(sql), input) catch {
    err => {
      permit.release()
      raise err
    }
  }
  let terminal = @ref.new(false)
  try {
    let mut database_error : DatabaseError? = None
    for res = responses.get() {
      match res {
        CopyInResponse(_) =>
          // The producer side queue is usable only after PostgreSQL explicitly
          // switches this request into COPY FROM STDIN mode.
          return {
            background_group: self.shared.background_group,
            input,
            responses,
            finished: @ref.new(false),
            permit,
          }
        ErrorResponse(body) => {
          // COPY startup failures still drain until `ReadyForQuery`, mirroring
          // the delayed-error behavior of the other streaming helpers.
          database_error = Some(parse_database_error(body.fields()))
          continue responses.get()
        }
        ReadyForQuery(_) => {
          terminal.val = true
          match database_error {
            Some(err) => raise ClientError::Database(err)
            None =>
              raise ClientError::UnexpectedMessage("expected CopyInResponse")
          }
        }
        _ =>
          fail_response_stream(
            responses,
            ClientError::UnexpectedMessage("unexpected copy-in response"),
          )
      }
    }
  } catch {
    err => {
      if terminal.val {
        permit.release()
      } else {
        start_abandoned_copy_in(
          self.shared.background_group,
          input,
          responses,
          permit,
        )
      }
      raise err
    }
  }
}

///|
/// Send one COPY data chunk to the server.
pub async fn CopyInSink::send(self : CopyInSink, data : BytesView) -> Unit {
  guard !self.finished.val else {
    raise ClientError::Closed("copy sink already finished")
  }
  self.enqueue_action(Data(data.to_owned()))
}

///|
/// Queue one producer action, converting an early server error into synchronous
/// sink cleanup before it is returned to the caller.
async fn CopyInSink::enqueue_action(
  self : CopyInSink,
  action : CopyInAction,
) -> Unit {
  self.input.put(action) catch {
    err => {
      guard err is ClientError::Database(database_error) else {
        self.finished.val = true
        start_abandoned_copy_in(
          self.background_group,
          self.input,
          self.responses,
          self.permit,
        )
        raise err
      }
      self.raise_early_database_error(database_error)
    }
  }
}

///|
/// Drain through `ReadyForQuery`, release the operation permit, and surface an
/// error that PostgreSQL sent while COPY input was still being produced.
async fn CopyInSink::raise_early_database_error(
  self : CopyInSink,
  database_error : DatabaseError,
) -> Unit {
  self.finished.val = true
  let _ = collect_copy_in_completion(self.responses) catch {
    err => {
      self.permit.release()
      raise err
    }
  }
  self.permit.release()
  raise ClientError::Database(database_error)
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
  try {
    self.enqueue_action(Finish)
    let rows = collect_copy_in_completion(self.responses)
    self.permit.release()
    rows
  } catch {
    err => {
      if err is ClientError::Database(_) {
        // Database errors are raised only after the terminal ReadyForQuery has
        // already been consumed.
        self.permit.release()
      } else {
        start_abandoned_copy_in(
          self.background_group,
          self.input,
          self.responses,
          self.permit,
        )
      }
      raise err
    }
  }
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
  try {
    self.input.put(Fail(message)) catch {
      err => {
        guard err is ClientError::Database(database_error) else { raise err }
        let _ = self.raise_early_database_error(database_error) catch {
          _ => ()
        }
        return
      }
    }
    // Abort is best-effort from the caller's perspective: once `CopyFail` is
    // queued, only protocol cleanup remains and its row count is irrelevant.
    let _ = collect_copy_in_completion(self.responses) catch {
      err => if err is ClientError::Database(_) { 0 } else { raise err }
    }
    self.permit.release()
  } catch {
    _ =>
      start_abandoned_copy_in(
        self.background_group,
        self.input,
        self.responses,
        self.permit,
      )
  }
}

///|
/// Complete a COPY IN exchange that its caller abandoned or cancelled.
///
/// Queueing `CopyFail` also covers cancellation during startup: if PostgreSQL
/// has already entered COPY mode, the driver can immediately unwind it.
fn start_abandoned_copy_in(
  background_group : @ref.Ref[@async.TaskGroup[Unit]?],
  input : @async.Queue[CopyInAction],
  responses : @async.Queue[@backend.Message],
  permit : OperationPermit,
) -> Unit {
  let task = spawn_detached_drain(background_group, () => {
    defer permit.release()
    ignore(input.put(Fail("COPY abandoned"))) catch {
      _ => ()
    }
    for response = responses.get() {
      match response {
        ReadyForQuery(_) => return
        _ => continue responses.get()
      }
    }
  })
  if task is None {
    permit.release()
  }
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
/// These messages are emitted by the private driver and can be consumed through
/// `Client::next_message`.
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
  priv permit : OperationPermit?
  /// Column wire formats reported by PostgreSQL's `CopyOutResponse`.
  formats : Array[WireFormat]
  priv mut database_error : DatabaseError?
  priv mut detached : Bool
  priv mut detached_task : @async.Task[Unit]?
  priv mut finished : Bool
}

///|
/// Read the next COPY OUT payload chunk.
pub async fn CopyOutStream::next(self : CopyOutStream) -> Bytes? {
  self.next_inner() catch {
    err => {
      self.abandon_after_error()
      raise err
    }
  }
}

///|
async fn CopyOutStream::next_inner(self : CopyOutStream) -> Bytes? {
  self.assert_attached()
  if self.finished {
    return self.raise_terminal_error_or_none()
  }
  for response = self.responses.get() {
    match response {
      CopyData(body) => return Some(body.storage)
      CopyDone | CommandComplete(_) =>
        // Completion frames are internal to COPY bookkeeping; the public API
        // only exposes raw data chunks and the final success/error outcome.
        continue self.responses.get()
      ErrorResponse(body) => {
        self.database_error = Some(parse_database_error(body.fields()))
        continue self.responses.get()
      }
      ReadyForQuery(_) => {
        // `ReadyForQuery` is the point where COPY mode has fully unwound and
        // the connection can safely accept ordinary requests again.
        self.finished = true
        self.release_permit()
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
  if self.detached {
    match self.detached_task {
      Some(task) => task.wait()
      None => ()
    }
    ignore(self.raise_terminal_error_or_none())
    return
  }
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
  self.start_detached_drain()
}

///|
fn CopyOutStream::start_detached_drain(self : CopyOutStream) -> Unit {
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
fn CopyOutStream::abandon_after_error(self : CopyOutStream) -> Unit {
  if self.finished {
    self.release_permit()
  } else if !self.detached {
    self.start_detached_drain()
  }
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
      CopyDone | CommandComplete(_) => continue self.responses.get()
      CopyData(_) =>
        // Detached drains intentionally throw away raw COPY payloads while
        // keeping the request moving toward its terminal ready state.
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
          ClientError::UnexpectedMessage("unexpected copy out response"),
        )
    }
  }
}

///|
fn CopyOutStream::release_permit(self : CopyOutStream) -> Unit {
  match self.permit {
    Some(permit) => permit.release()
    None => ()
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
