// The socket-owning driver and its single-request state machine.

///|
/// Drive one PostgreSQL connection until graceful shutdown or failure.
///
/// Exactly one request is written and drained through `ReadyForQuery` before
/// the next request is taken from the submission queue. Logical operations may
/// still issue several requests, but the client operation gate keeps all of
/// those stages under one exclusive capability.
async fn Driver::run(self : Driver) -> Unit {
  let mut active : Request? = None
  defer {
    self.stream.close()
    self.shared.driver_task.val = None
    ignore(self.shared.driver_done.try_put(())) catch {
      _ => ()
    }
    self.shared.driver_done.close()
  }
  try {
    while true {
      let request = self.shared.requests.get()
      active = Some(request)
      match request.kind {
        Terminate => {
          self.stream.write(request.bytes)
          self.close_request(request, None)
          active = None
          self.drain_queued_requests(None)
          close_runtime(self.shared)
          return
        }
        Messages | CopyIn => {
          self.stream.write(request.bytes)
          self.drain_request(request)
          self.close_request(request, None)
          active = None
        }
      }
    }
  } catch {
    err => {
      let driver_error : Error = if self.shared.aborted.val {
        ClientError::Closed("connection aborted")
      } else {
        err
      }
      match active {
        Some(request) => self.close_request(request, Some(driver_error))
        None => ()
      }
      self.drain_queued_requests(Some(driver_error))
      close_runtime(self.shared, error=driver_error)
    }
  }
}

///|
/// Receive the next asynchronous message buffered by the private driver.
///
/// Returns `None` after the connection closes.
pub async fn Client::next_message(self : Client) -> AsyncMessage? {
  Some(self.shared.async_messages.get()) catch {
    _ => None
  }
}

///|
/// Drain all backend messages belonging to one request.
async fn Driver::drain_request(self : Driver, request : Request) -> Unit {
  if request.kind is CopyIn {
    self.drain_copy_in_request(request)
    return
  }
  while true {
    let message = self.read_message()
    if self.handle_async_message(message) {
      continue
    }
    match request.kind {
      Messages => self.forward_message_to_request(request, message)
      CopyIn => abort("COPY IN requests use drain_copy_in_request")
      Terminate =>
        raise ClientError::UnexpectedMessage("unexpected terminate request")
    }
    if message is ReadyForQuery(_) {
      return
    }
  }
}

///|
/// Forward a regular request message to its response queue.
async fn Driver::forward_message_to_request(
  self : Driver,
  request : Request,
  message : @backend.Message,
) -> Unit {
  match message {
    ReadyForQuery(body) => {
      self.shared.transaction_status.val = body.status
      request.responses.put(message)
    }
    _ => request.responses.put(message)
  }
}

///|
/// Read COPY IN responses while one dedicated task writes producer frames.
///
/// Keeping the driver as the sole reader lets PostgreSQL report malformed COPY
/// data before the producer calls `finish`. The writer is always joined before
/// `ReadyForQuery` becomes visible or the next request can start.
async fn Driver::drain_copy_in_request(
  self : Driver,
  request : Request,
) -> Unit {
  let copy_input = request.copy_input.unwrap()
  let copy_error = request.copy_error.unwrap()
  let writer_stopped = @ref.new(false)
  let mut writer : @async.Task[Unit]? = None
  while true {
    let message = self.read_message()
    if self.handle_async_message(message) {
      continue
    }
    match message {
      CopyInResponse(_) => {
        guard writer is None else {
          raise ClientError::UnexpectedMessage("duplicate CopyInResponse")
        }
        request.responses.put(message)
        writer = Some(self.spawn_copy_writer(copy_input, writer_stopped))
      }
      ErrorResponse(body) => {
        let database_error = parse_database_error(body.fields())
        copy_error.val = Some(database_error)
        request.responses.put(message)
        if !writer_stopped.val {
          writer_stopped.val = true
          copy_input.close(
            error=ClientError::Database(database_error),
            clear=true,
          )
        }
      }
      ReadyForQuery(body) => {
        match writer {
          Some(writer) => writer.wait()
          None => ()
        }
        self.shared.transaction_status.val = body.status
        request.responses.put(message)
        return
      }
      _ => request.responses.put(message)
    }
  }
}

///|
/// Start the unique writer paired with one COPY IN request.
fn Driver::spawn_copy_writer(
  self : Driver,
  input : @async.Queue[CopyInAction],
  stopped : @ref.Ref[Bool],
) -> @async.Task[Unit] raise {
  match self.shared.background_group.val {
    Some(group) =>
      group.spawn(no_wait=true, allow_failure=true, () => {
        self.drain_copy_input(input, stopped)
      })
    None => raise ClientError::Closed("connection driver is unavailable")
  }
}

///|
/// Drain one COPY IN sink until it finishes, aborts, or the reader stops it.
async fn Driver::drain_copy_input(
  self : Driver,
  input : @async.Queue[CopyInAction],
  stopped : @ref.Ref[Bool],
) -> Unit {
  while true {
    let act = input.get() catch {
      err => if stopped.val { return } else { raise err }
    }
    match act {
      Data(data) => {
        let payload = Buffer()
        @frontend.CopyData::new(data[:]).write(payload)
        self.stream.write(payload.to_bytes())
        // Small socket writes may complete without suspending. Yield after one
        // complete frame so the sole reader can observe an early ErrorResponse
        // instead of being starved by the producer/writer handoff.
        @async.pause()
        continue
      }
      Finish => {
        let payload = Buffer()
        @frontend.copy_done(payload)
        self.stream.write(payload.to_bytes())
        return
      }
      Fail(message) => {
        let payload = Buffer()
        @frontend.copy_fail(@proto.utf8_encode(message)[:], payload)
        self.stream.write(payload.to_bytes())
        return
      }
    }
  }
}

///|
/// Close one request's queues, optionally propagating an error.
fn Driver::close_request(
  self : Driver,
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
        None =>
          match request.copy_error {
            Some(copy_error) =>
              match copy_error.val {
                Some(database_error) =>
                  input.close(
                    error=ClientError::Database(database_error),
                    clear=true,
                  )
                None => input.close()
              }
            None => input.close()
          }
        Some(err) => input.close(error=err, clear=true)
      }
    None => ()
  }
}

///|
/// Drain and close requests that were queued but never written to the wire.
fn Driver::drain_queued_requests(self : Driver, error : Error?) -> Unit {
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
/// Handle backend messages that are not tied to the active request.
fn Driver::handle_async_message(
  self : Driver,
  message : @backend.Message,
) -> Bool raise {
  match message {
    ParameterStatus(body) => {
      let name = body.name_str()
      let value = body.value_str()
      self.shared.parameters[name] = value
      self.push_async_message(ParameterStatus(name, value))
      true
    }
    NoticeResponse(body) => {
      self.push_async_message(Notice(parse_database_error(body.fields())))
      true
    }
    NotificationResponse(body) => {
      self.push_async_message(
        Notification({
          process_id: body.process_id,
          channel: body.channel_str(),
          payload: body.message_str(),
        }),
      )
      true
    }
    _ => false
  }
}

///|
/// Publish one asynchronous backend message.
fn Driver::push_async_message(self : Driver, message : AsyncMessage) -> Unit {
  ignore(self.shared.async_messages.try_put(message)) catch {
    _ => ()
  }
}

///|
/// Read and parse one backend message from the connection stream.
async fn Driver::read_message(self : Driver) -> @backend.Message {
  let header = self.stream.read_exactly(5)
  let body_len = @proto.ByteReader::new(header[1:]).read_i32_be()
  let body = self.stream.read_exactly(body_len - 4)
  let packet = Buffer(size_hint=header.length() + body.length())
  packet.write_bytes(header)
  packet.write_bytes(body)
  match @backend.Message::parse(packet.to_bytes()[:]) {
    Some(parsed) => parsed.message
    None => raise ClientError::UnexpectedMessage("incomplete backend message")
  }
}
