// The socket-owning connection task and its request/response state machine.

///|
/// Drive the PostgreSQL connection until graceful shutdown or failure.
///
/// The loop alternates between:
/// 1. taking queued client requests,
/// 2. opportunistically pipelining additional non-barrier requests, and
/// 3. forwarding backend messages either to async listeners or to the oldest
///    pending request.
///
/// On any error, the loop closes all outstanding queues, marks the shared
/// runtime as closed, and then closes the socket.
pub async fn Connection::run(
  self : Connection,
  on_async? : (AsyncMessage) -> Unit = _ => (),
) -> Unit {
  @async.with_task_group(group => {
    self.shared.background_group.val = Some(group)
    defer {
      self.shared.background_group.val = None
    }

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
  })
}

///|
/// Receive the next asynchronous message buffered by the connection loop.
///
/// Returns `None` after the async-message queue is closed.
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
/// Write one queued request to the wire and decide whether it stops pipelining.
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
/// Return whether every currently pending request may be safely pipelined.
///
/// COPY IN and termination requests act as barriers because they require
/// request-specific coordination with subsequent protocol messages.
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
/// Opportunistically enqueue more non-barrier requests without blocking.
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
/// Route one backend message to either async listeners or the oldest request.
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
/// Forward a regular request message to its response queue.
///
/// `ReadyForQuery` also updates the shared transaction status snapshot.
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
/// Forward a COPY IN request message and start draining client input when ready.
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
/// Drain one COPY IN sink until it finishes or aborts.
///
/// The driver writes each client-produced action as a protocol message on the
/// shared connection stream. Once `Finish` or `Fail` is seen, the COPY request
/// returns to normal backend-response processing.
async fn Connection::drain_copy_input(
  self : Connection,
  input : @async.Queue[CopyInAction],
) -> Unit {
  for act = input.get() {
    match act {
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
}

///|
/// Close one request's queues, optionally propagating an error.
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
/// Close every currently pending request.
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
/// Drain and close requests that were queued but never written to the wire.
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
/// Handle backend messages that are not tied to the current request head.
///
/// PostgreSQL may send notices, notifications, and parameter updates while
/// ordinary requests are in flight. The connection loop peels those off first
/// so request-specific stream parsers only see messages that belong to them.
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
/// Publish one async message to both the callback and the queue buffer.
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
/// Read and parse one backend message from the shared connection stream.
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
