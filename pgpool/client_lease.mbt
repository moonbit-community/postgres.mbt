// Pooled capabilities reject overlapping work before any suspension.

///|
fn ClientLeaseState::assert_active(self : ClientLeaseState) -> Unit raise {
  if self.releasing.val ||
    self.released.val ||
    self.connection.client.val is None {
    raise PoolError::ScopeExpired
  }
}

///|
fn ClientLeaseState::begin_operation(
  self : ClientLeaseState,
) -> @client.Client raise {
  self.assert_active()
  if !self.gate.try_acquire() {
    raise PoolError::OperationInProgress
  }
  self.active_ops.val += 1
  // A new accepted business operation starts a new episode after a caller has
  // recovered from an earlier error. Unwinding cleanup never enters here.
  if !self.cleanup_mode && !self.connection.client.val.unwrap().is_closed() {
    self.cleanup_deadline.val = None
  }
  self.connection.client.val.unwrap()
}

///|
fn ClientLeaseState::finish_operation(self : ClientLeaseState) -> Unit {
  self.active_ops.val -= 1
  self.gate.release()
}

///|
fn ClientLeaseState::scoped_client(
  self : ClientLeaseState,
) -> @client.Client raise {
  if self.connection.client.val is Some(client) {
    client
  } else {
    raise PoolError::ScopeExpired
  }
}

///|
/// One cleanup instant is shared by drains, nested rollback and final reset.
async fn[T] ClientLeaseState::cleanup(
  self : ClientLeaseState,
  f : async () -> T,
) -> T {
  if self.cleanup_deadline.val is None {
    self.cleanup_deadline.val = Some({
      at: @async.now() + self.pool.pool_config.val.cleanup_ms.to_int64(),
    })
  }
  let started = @async.now()
  @async.protect_from_cancel(() => {
    let client = self.scoped_client()
    errdefer client.abort()
    let outcome = try
      run_with_timeout(
        remaining_ms(self.cleanup_deadline.val, Cleanup),
        Cleanup,
        on_timeout=() => client.abort(),
        f,
      )
    catch {
      error => Err(error)
    } noraise {
      value => Ok(value)
    }
    match outcome {
      Err(error) => {
        // Late cleanup on an escaped scope can only observe the aborted
        // client. Keep the reason that retired it, including across deadlines.
        if !(self.connection.failure.val is Some(PoolError::OperationInProgress)) {
          self.connection.failure.val = Some(error)
        }
        emit_event(
          self.pool,
          CleanupCompleted,
          Cleanup,
          connection_id=self.connection.id,
          scope_id=self.id,
          started~,
          cause=error,
        )
        raise error
      }
      Ok(value) => {
        emit_event(
          self.pool,
          CleanupCompleted,
          Cleanup,
          connection_id=self.connection.id,
          scope_id=self.id,
          started~,
        )
        value
      }
    }
  })
}

///|
async fn ClientLeaseState::cleanup_best_effort(
  self : ClientLeaseState,
  f : async () -> Unit,
) -> Unit {
  self.cleanup(f) catch {
    _ => ()
  }
}

///|
/// Install one request control for the whole operation or resource scope.
async fn[T] ClientLeaseState::supervise(
  self : ClientLeaseState,
  client : @client.Client,
  f : async () -> T,
  deadline? : Deadline,
  protect~ : Bool = true,
) -> T {
  let deadline = earlier_deadline(self.deadline, deadline)
  ignore(remaining_ms(deadline, Query))
  check_pending_cancellation()
  let control = client.begin_request_control()
  self.active_control.val = Some(control)
  defer {
    // Worker completion is not sufficient evidence of protocol completion:
    // a parser or transport error may have returned before ReadyForQuery.
    if control.was_sent() && !control.protocol_complete() {
      client.abort()
    }
    self.active_control.val = None
    client.end_request_control()
  }
  self.supervise_worker(f, deadline?, protect~)
}

///|
/// Wait independently of protected I/O, reusing the owner's request control.
/// Cancellation and protocol drain share the lease's cleanup budget. Only
/// cancel_active's owner can release the fence, including nested supervisors.
async fn[T] ClientLeaseState::supervise_worker(
  self : ClientLeaseState,
  f : async () -> T,
  deadline? : Deadline,
  protect~ : Bool = true,
) -> T {
  let deadline = earlier_deadline(self.deadline, deadline)
  ignore(remaining_ms(deadline, Query))
  check_pending_cancellation()
  @async.with_task_group(group => {
    let done = Ref(false)
    let worker = group.spawn(allow_failure=true, () => {
      defer {
        done.val = true
      }
      if protect {
        @async.protect_from_cancel(f)
      } else {
        f()
      }
    })
    errdefer (if !done.val {
      @async.protect_from_cancel(() => {
        worker.cancel()
        self.cleanup_best_effort(() => {
          self.cancel_active()
          ignore(worker.wait()) catch {
            _ => ()
          }
        })
        // Cleanup aborts the client on expiry. Join the worker before releasing
        // any gate, even when the bounded wait ended before protected I/O did.
        ignore(worker.wait()) catch {
          _ => ()
        }
      })
    })
    with_deadline(deadline, Query, () => worker.wait())
  })
}

///|
async fn[T] Session::run_operation(
  self : Session,
  op : async (@client.Client) -> T,
  deadline? : Deadline,
) -> T {
  let client = self.state.begin_operation()
  defer self.state.finish_operation()
  self.state.supervise(client, () => op(client), deadline?)
}

///|
async fn[T] Session::run_scoped_operation(
  self : Session,
  op : async (@client.Client) -> T,
  deadline? : Deadline,
) -> T {
  let client = self.state.begin_operation()
  defer self.state.finish_operation()
  self.state.supervise(client, () => op(client), deadline?, protect=false)
}

///|
async fn[T] Transaction::run_operation(
  self : Transaction,
  op : async (@client.Client) -> T,
  deadline? : Deadline,
) -> T {
  let session : Session = { state: self.state, }
  session.run_operation(op, deadline?)
}

///|
async fn[T] Transaction::run_scoped_operation(
  self : Transaction,
  op : async (@client.Client) -> T,
  deadline? : Deadline,
) -> T {
  let session : Session = { state: self.state, }
  session.run_scoped_operation(op, deadline?)
}

///|
async fn Session::release(self : Session) -> Unit {
  if self.state.released.val {
    return
  }
  self.state.releasing.val = true
  // A callback may leave work in an outer task group. Never return its socket.
  if self.state.active_ops.val > 0 {
    self.state.scoped_client().abort() catch {
      _ => ()
    }
  }
  defer {
    self.state.released.val = true
    release_capacity(self.state.pool)
  }
  if !self.state.pool.closed.val {
    self.state.cleanup_best_effort(() => reset_session(self.state))
  }
  let connection = self.state.connection
  if connection.client.val is Some(client) &&
    !client.is_closed() &&
    !self.state.pool.closed.val &&
    self.state.pool.size.val <= self.state.pool.pool_config.val.max_size {
    self.state.pool.idle.push(connection)
  } else {
    retire_connection(self.state.pool, connection)
  }
}

///|
/// Multiple cancelling scopes join the same fence; only its owner sends a
/// packet. Joining cannot release the fence before the control socket closes.
async fn ClientLeaseState::cancel_active(self : ClientLeaseState) -> Unit {
  guard self.active_control.val is Some(control) else { return }
  if control.is_cancelled() {
    control.wait_cancel()
    return
  }
  let needed = control.cancel()
  defer control.finish_cancel()
  if !needed {
    return
  }
  let started = @async.now()
  let outcome = try self.scoped_client().cancel_token().cancel() catch {
    error => Err(error)
  } noraise {
    _ => Ok(())
  }
  match outcome {
    Err(error) => {
      emit_event(
        self.pool,
        CancelRequested,
        Query,
        connection_id=self.connection.id,
        scope_id=self.id,
        request_id?=control.request_id(),
        started~,
        cause=error,
      )
      raise error
    }
    Ok(_) =>
      emit_event(
        self.pool,
        CancelRequested,
        Query,
        connection_id=self.connection.id,
        scope_id=self.id,
        request_id?=control.request_id(),
        started~,
      )
  }
}
