// Checked-out client lease lifecycle helpers.

///|
/// Start one client operation or reject work after release begins.
fn ClientLeaseState::begin_operation(
  self : ClientLeaseState,
) -> @client.Client raise {
  if self.releasing.val || self.released.val {
    raise PoolError::LeaseReleased
  }
  if self.scope_active.val {
    raise PoolError::OperationInProgress
  }
  match self.connection.client.val {
    Some(client) => {
      self.active_ops.val += 1
      client
    }
    None => raise PoolError::LeaseReleased
  }
}

///|
/// Finish one client operation and finalize delayed release if needed.
fn ClientLeaseState::finish_operation(self : ClientLeaseState) -> Unit {
  if self.active_ops.val > 0 {
    self.active_ops.val -= 1
  }
  if self.releasing.val && !self.released.val && self.active_ops.val == 0 {
    self.finalize_release()
  }
}

///|
/// Start one exclusive cancellable scope on this lease.
fn ClientLeaseState::begin_cancellable_scope(
  self : ClientLeaseState,
) -> ConnectionState raise {
  if self.releasing.val || self.released.val {
    raise PoolError::LeaseReleased
  }
  if self.scope_active.val || self.active_ops.val > 0 {
    raise PoolError::OperationInProgress
  }
  match self.connection.client.val {
    Some(_) => {
      self.scope_active.val = true
      self.active_ops.val += 1
      self.connection
    }
    None => raise PoolError::LeaseReleased
  }
}

///|
/// Finish one exclusive cancellable scope on this lease.
fn ClientLeaseState::finish_cancellable_scope(self : ClientLeaseState) -> Unit {
  self.scope_active.val = false
  self.finish_operation()
}

///|
/// Start one exclusive transaction scope on this lease.
fn ClientLeaseState::begin_transaction_scope(
  self : ClientLeaseState,
) -> (@client.Client, ConnectionState) raise {
  if self.releasing.val || self.released.val {
    raise PoolError::LeaseReleased
  }
  if self.scope_active.val || self.active_ops.val > 0 {
    raise PoolError::OperationInProgress
  }
  match self.connection.client.val {
    Some(client) => {
      self.scope_active.val = true
      self.active_ops.val += 1
      (client, self.connection)
    }
    None => raise PoolError::LeaseReleased
  }
}

///|
/// Finish one exclusive transaction scope on this lease.
fn ClientLeaseState::finish_transaction_scope(self : ClientLeaseState) -> Unit {
  self.scope_active.val = false
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
async fn[T] Client::run_operation(
  self : Client,
  op : async (@client.Client) -> T,
) -> T {
  let client = self.state.begin_operation()
  defer self.state.finish_operation()
  @async.protect_from_cancel(() => op(client), resume_on_cancel=true)
}

///|
/// Mark this pooled client lease for release.
///
/// Side effects: new scoped operations start failing with `PoolError::LeaseReleased`.
/// Existing in-flight operations are allowed to finish first, and the physical
/// connection is returned to the pool only after the active-operation count
/// reaches zero. Repeated calls are idempotent.
pub fn Client::release(self : Client) -> Unit {
  if self.state.releasing.val || self.state.released.val {
    return
  }
  self.state.releasing.val = true
  if self.state.active_ops.val == 0 {
    self.state.finalize_release()
  }
}

///|
/// Permanently detach the raw client from pool management.
///
/// Preconditions: the lease must still be active, and no operation,
/// transaction-building scope, or cancellable scope may be in progress.
/// Side effects: the pool forgets this physical connection, frees one capacity
/// slot, and stops recycling or closing the detached client for you. The caller
/// becomes responsible for closing the returned raw client. The returned
/// `@client.Client` keeps using the existing background connection driver, so it
/// can continue ordinary client operations immediately after detaching.
pub fn Client::detach_raw(self : Client) -> @client.Client raise {
  if self.state.releasing.val || self.state.released.val {
    raise PoolError::LeaseReleased
  }
  if self.state.scope_active.val || self.state.active_ops.val > 0 {
    raise PoolError::OperationInProgress
  }
  let client = match self.state.connection.client.val {
    Some(client) => client
    None => raise PoolError::LeaseReleased
  }
  self.state.releasing.val = true
  self.state.released.val = true
  retire_connection(self.state.pool, self.state.connection, close_client=false)
  restore_available_slot(self.state.pool)
  client
}
