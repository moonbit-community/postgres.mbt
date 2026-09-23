// Checked-out client lease lifecycle helpers.

///|
/// Start one client operation or reject work after release begins.
async fn ClientLeaseState::begin_operation(
  self : ClientLeaseState,
) -> @client.Client {
  if self.releasing.val || self.released.val {
    raise PoolError::ScopeExpired
  }
  self.gate.acquire()
  if self.releasing.val || self.released.val {
    self.gate.release()
    raise PoolError::ScopeExpired
  }
  match self.connection.client.val {
    Some(client) => {
      self.active_ops.val += 1
      client
    }
    None => {
      self.gate.release()
      raise PoolError::ScopeExpired
    }
  }
}

///|
/// Finish one client operation and finalize delayed release if needed.
fn ClientLeaseState::finish_operation(self : ClientLeaseState) -> Unit {
  if self.active_ops.val > 0 {
    self.active_ops.val -= 1
  }
  self.gate.release()
  if self.releasing.val && !self.released.val && self.active_ops.val == 0 {
    self.finalize_release()
  }
}

///|
/// Keep the physical connection leased across a prepared callback without
/// owning the FIFO gate. Individual requests acquire that gate separately.
fn ClientLeaseState::begin_prepared_lease(
  self : ClientLeaseState,
) -> Unit raise {
  if self.releasing.val ||
    self.released.val ||
    self.connection.client.val is None {
    raise PoolError::ScopeExpired
  }
  self.active_ops.val += 1
}

///|
fn ClientLeaseState::finish_prepared_lease(self : ClientLeaseState) -> Unit {
  self.active_ops.val -= 1
  if self.releasing.val && !self.released.val && self.active_ops.val == 0 {
    self.finalize_release()
  }
}

///|
/// Acquire the session gate for preparation. The resulting handle is delivered
/// to its owner before pending cancellation is observed by that owner.
async fn[T] ClientLeaseState::prepare_step(
  self : ClientLeaseState,
  op : async (@client.Client) -> T,
) -> T {
  let client = self.begin_operation()
  defer self.finish_operation()
  @async.protect_from_cancel(() => op(client))
}

///|
/// Cleanup must still acquire the gate after the outer Session has begun
/// releasing; the prepared lease keeps the physical connection alive.
async fn[T] ClientLeaseState::prepared_cleanup_step(
  self : ClientLeaseState,
  op : async (@client.Client) -> T,
) -> T {
  self.gate.acquire()
  defer self.gate.release()
  op(self.scoped_client())
}

///|
/// Start one exclusive cancellable scope on this lease.
async fn ClientLeaseState::begin_cancellable_scope(
  self : ClientLeaseState,
) -> ConnectionState {
  if self.releasing.val || self.released.val {
    raise PoolError::ScopeExpired
  }
  self.gate.acquire()
  if self.releasing.val || self.released.val {
    self.gate.release()
    raise PoolError::ScopeExpired
  }
  match self.connection.client.val {
    Some(_) => {
      self.active_ops.val += 1
      self.connection
    }
    None => {
      self.gate.release()
      raise PoolError::ScopeExpired
    }
  }
}

///|
/// Finish one exclusive cancellable scope on this lease.
fn ClientLeaseState::finish_cancellable_scope(self : ClientLeaseState) -> Unit {
  self.finish_operation()
}

///|
/// Start one exclusive transaction scope on this lease.
async fn ClientLeaseState::begin_transaction_scope(
  self : ClientLeaseState,
) -> (@client.Client, ConnectionState) {
  if self.releasing.val || self.released.val {
    raise PoolError::ScopeExpired
  }
  self.gate.acquire()
  if self.releasing.val || self.released.val {
    self.gate.release()
    raise PoolError::ScopeExpired
  }
  match self.connection.client.val {
    Some(client) => {
      self.active_ops.val += 1
      (client, self.connection)
    }
    None => {
      self.gate.release()
      raise PoolError::ScopeExpired
    }
  }
}

///|
/// Finish one exclusive transaction scope on this lease.
fn ClientLeaseState::finish_transaction_scope(self : ClientLeaseState) -> Unit {
  self.finish_operation()
}

///|
/// Return the client to the pool once no active operations remain.
fn ClientLeaseState::finalize_release(self : ClientLeaseState) -> Unit {
  if self.released.val {
    return
  }
  self.released.val = true
  return_client(self.pool, self.connection)
}

///|
/// Run one async operation against the checked-out client.
async fn[T] Session::run_operation(
  self : Session,
  op : async (@client.Client) -> T,
) -> T {
  let client = self.state.begin_operation()
  defer self.state.finish_operation()
  check_pending_cancellation()
  defer check_pending_cancellation()
  @async.protect_from_cancel(() => op(client))
}

///|
/// Keep an exclusive session gate for a protocol stream while allowing its
/// callback to observe task cancellation. The client scope owns protocol
/// startup and finalization.
async fn[T] Session::run_scoped_operation(
  self : Session,
  op : async (@client.Client) -> T,
) -> T {
  let client = self.state.begin_operation()
  defer self.state.finish_operation()
  check_pending_cancellation()
  defer check_pending_cancellation()
  op(client)
}

///|
/// Mark this pooled client lease for release.
///
/// Side effects: new scoped operations start failing with `PoolError::ScopeExpired`.
/// Existing in-flight operations are allowed to finish first, and the physical
/// connection is returned to the pool only after the active-operation count
/// reaches zero. Repeated calls are idempotent.
fn Session::release(self : Session) -> Unit {
  if self.state.releasing.val || self.state.released.val {
    return
  }
  self.state.releasing.val = true
  if self.state.active_ops.val == 0 {
    self.state.finalize_release()
  }
}

///|
/// Access the raw client while an outer callback owns this session's gate.
fn ClientLeaseState::scoped_client(
  self : ClientLeaseState,
) -> @client.Client raise {
  if self.released.val {
    raise PoolError::ScopeExpired
  }
  match self.connection.client.val {
    Some(client) => client
    None => raise PoolError::ScopeExpired
  }
}
