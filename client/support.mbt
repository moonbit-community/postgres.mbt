// Shared helpers used by the higher-level client APIs.

///|
fn OperationGate::new() -> OperationGate {
  { mutex: Mutex() }
}

///|
async fn OperationGate::acquire(self : OperationGate) -> OperationPermit {
  self.mutex.acquire()
  { gate: self, released: @ref.new(false) }
}

///|
fn OperationPermit::release(self : OperationPermit) -> Unit {
  if self.released.val {
    return
  }
  self.released.val = true
  self.gate.mutex.release()
}

///|
fn Client::operation_context(self : Client) -> OpContext {
  { client: self }
}

///|
/// Run a fully consumed logical operation under the client's FIFO gate.
async fn[T] Client::run_operation(
  self : Client,
  f : async (OpContext) -> T,
) -> T {
  let permit = self.shared.operation_gate.acquire()
  defer permit.release()
  ensure_open(self.shared)
  @async.protect_from_cancel(
    () => f(self.operation_context()),
    resume_on_cancel=true,
  )
}

///|
/// Acquire the client for an operation whose returned handle owns the permit.
async fn Client::begin_stream_operation(
  self : Client,
) -> (OpContext, OperationPermit) {
  let permit = self.shared.operation_gate.acquire()
  try {
    ensure_open(self.shared)
    (self.operation_context(), permit)
  } catch {
    err => {
      permit.release()
      raise err
    }
  }
}

///|
/// Queue a request for the connection loop and return its response stream.
///
/// The caller chooses the response queue kind. Most requests use the bounded
/// per-request queue so unread streams eventually exert backpressure.
fn Client::send_request(
  self : Client,
  kind : RequestKind,
  bytes : Bytes,
  response_kind? : @aqueue.Kind = request_response_queue_kind,
) -> @async.Queue[@backend.Message] raise {
  let responses = @async.Queue(kind=response_kind)
  // `shared.requests` is created as `Unbounded`, so `try_put` cannot return
  // `false` for "queue full". The only failure mode here is a closed queue,
  // which still raises and propagates out of this helper.
  ignore(
    self.shared.requests.try_put({
      kind,
      bytes,
      responses,
      copy_input: None,
      copy_error: None,
    }),
  )
  responses
}

///|
/// Queue a COPY IN request that also carries a client-input queue.
fn Client::send_request_with_copy(
  self : Client,
  bytes : Bytes,
  input : @async.Queue[CopyInAction],
) -> @async.Queue[@backend.Message] raise {
  let responses = @async.Queue(kind=request_response_queue_kind)
  // Same reasoning as `send_request`: the shared request queue is unbounded,
  // so ignoring the `Bool` only discards an impossible "queue full" result.
  ignore(
    self.shared.requests.try_put({
      kind: CopyIn,
      bytes,
      responses,
      copy_input: Some(input),
      copy_error: Some(@ref.new(None)),
    }),
  )
  responses
}

///|
/// Fail if the shared runtime is already closed or shutting down.
fn ensure_open(shared : Shared) -> Unit raise {
  if shared.aborted.val {
    raise ClientError::Closed("connection aborted")
  }
  if shared.closed.val || shared.closing.val {
    // `closing` flips before the socket is fully torn down so new work stops
    // racing against a connection that is already converging toward shutdown.
    raise ClientError::Closed("connection is closed")
  }
}

///|
/// Spawn one detached stream drain on the client's task group.
///
/// Terminal database errors are intentionally swallowed for detached streams,
/// but any other failure still tears down the task group so protocol bugs or
/// runtime failures are not silently ignored.
fn spawn_detached_drain(
  background_group : @ref.Ref[@async.TaskGroup[Unit]?],
  drain : async () -> Unit,
) -> @async.Task[Unit]? {
  match background_group.val {
    Some(group) =>
      Some(
        group.spawn(no_wait=true, () => {
          try drain() catch {
            // Detached callers gave up synchronous handling of database failures,
            // but protocol bugs and runtime errors should still surface.
            err => if err is ClientError::Database(_) { () } else { raise err }
          } noraise {
            _ => ()
          }
        }),
      )
    None => None
  }
}

///|
/// Fail if the transaction or savepoint handle has already been finished.
fn Transaction::assert_open(self : Transaction) -> Unit raise {
  if self.finished.val {
    raise ClientError::Closed("transaction is already finished")
  }
  if self.client.shared.closed.val {
    self.finished.val = true
    self.release_owner_permit()
    if self.client.shared.aborted.val {
      raise ClientError::Closed("connection aborted")
    }
    raise ClientError::Closed("connection is closed")
  }
}

///|
/// Mark the shared runtime as closed and close its public queues.
///
/// This is the central place where shutdown semantics are normalized for both
/// graceful termination and error-driven teardown.
fn close_runtime(shared : Shared, error? : Error) -> Unit {
  if shared.closed.val {
    return
  }
  // Flip the visible shutdown flags first so concurrent submitters observe a
  // consistent "no new work" state even if queue closure races with them.
  shared.closed.val = true
  shared.closing.val = true
  match error {
    None => {
      shared.requests.close()
      shared.async_messages.close()
    }
    Some(err) => {
      shared.requests.close(error=err, clear=true)
      shared.async_messages.close()
    }
  }
}

///|
/// Return the next monotonically increasing runtime-local identifier.
fn next_id(shared : Shared) -> Int {
  shared.next_id.val += 1
  shared.next_id.val
}

///|
/// Build a protocol-safe identifier name for statements and portals.
fn next_name(shared : Shared, prefix : String) -> Bytes {
  @proto.utf8_encode("\{prefix}\{next_id(shared).to_string()}")
}

///|
/// Seed the shared type cache with built-in descriptors known without catalog I/O.
fn seed_builtin_types(types : Map[@proto.Oid, Type]) -> Unit {
  for
    type_ in [
      Type::bool(),
      Type::bytea(),
      Type::char(),
      Type::name_type(),
      Type::int8(),
      Type::int2(),
      Type::int4(),
      Type::text(),
      Type::oid_type(),
      Type::json(),
      Type::json_array(),
      Type::float4(),
      Type::float8(),
      Type::varchar(),
      Type::date(),
      Type::time(),
      Type::timestamp(),
      Type::timestamptz(),
      Type::uuid(),
      Type::jsonb(),
      Type::jsonb_array(),
      Type::bool_array(),
      Type::bytea_array(),
      Type::int2_array(),
      Type::int4_array(),
      Type::text_array(),
      Type::varchar_array(),
      Type::int8_array(),
      Type::float4_array(),
      Type::float8_array(),
      Type::timestamp_array(),
      Type::date_array(),
      Type::uuid_array(),
    ] {
    types[type_.oid] = type_
  }
}
