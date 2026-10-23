// Transaction intent and independently observable completion.

///|
fn begin_sql(options : TransactionOptions) -> String {
  let clauses = ["BEGIN"]
  if options.isolation_level is Some(level) {
    let level = match level {
      ReadUncommitted => "READ UNCOMMITTED"
      ReadCommitted => "READ COMMITTED"
      RepeatableRead => "REPEATABLE READ"
      Serializable => "SERIALIZABLE"
    }
    clauses.push("ISOLATION LEVEL " + level)
  }
  if options.read_only is Some(value) {
    clauses.push(if value { "READ ONLY" } else { "READ WRITE" })
  }
  if options.deferrable is Some(value) {
    clauses.push(if value { "DEFERRABLE" } else { "NOT DEFERRABLE" })
  }
  clauses.join(" ")
}

///|
fn quote_savepoint(name : String) -> String raise {
  if name.is_empty() || name.contains("\u0000") {
    raise PoolError::InvalidConfig("invalid savepoint name")
  }
  "\"" + name.replace_all(old="\"", new="\"\"") + "\""
}

///|
fn Transaction::record_completion(
  self : Transaction,
  status : TransactionStatus,
  cause : Error?,
) -> Unit {
  self.record.status.val = status
  emit_event(
    self.state.pool,
    TransactionCompleted,
    Cleanup,
    connection_id=self.state.connection.id,
    scope_id=self.state.id,
    cause?,
    transaction_status=status,
  )
}

///|
/// Retire escaped work before any completion SQL or parent gate release.
/// This check must not suspend: another task must never acquire this socket
/// between detecting an active child and aborting its physical client.
fn Transaction::abort_active_children(self : Transaction) -> Bool {
  if self.state.active_ops.val == 0 {
    return false
  }
  self.state.releasing.val = true
  let cause = PoolError::OperationInProgress
  self.state.connection.failure.val = Some(cause)
  if self.state.connection.client.val is Some(client) {
    client.abort()
  }
  // Closing a socket does not acknowledge rollback. Do not overwrite a
  // confirmed result or emit completion again during errdefer/final defer.
  if self.record.status.val == InProgress {
    self.record_completion(OutcomeUnknown, Some(cause))
  }
  true
}

///|
async fn Transaction::rollback_internal(self : Transaction) -> Unit {
  let client = self.state.scoped_client()
  self.state.releasing.val = true
  defer {
    self.state.released.val = true
  }
  if client.is_closed() {
    // An escaped nested scope may already have aborted the shared socket.
    // Retain that diagnostic without attempting rollback on a dead client.
    self.record_completion(OutcomeUnknown, self.state.connection.failure.val)
    return
  }
  let sql = match self.savepoint {
    None => "ROLLBACK"
    Some(name) => "ROLLBACK TO SAVEPOINT \{name}; RELEASE SAVEPOINT \{name}"
  }
  let outcome = try self.state.cleanup(() => client.batch_execute(sql)) catch {
    error => Err(error)
  } noraise {
    _ => Ok(())
  }
  match outcome {
    Err(error) => {
      self.record_completion(OutcomeUnknown, Some(error))
      raise error
    }
    Ok(_) => ()
  }
  self.record_completion(RolledBack, None)
}

///|
/// Once COMMIT may have been written, only the actual server tag decides the
/// record. Never issue ROLLBACK in response to a missing COMMIT response.
/// The scope exit protects completion and propagates cancellation afterwards.
async fn Transaction::commit_internal(self : Transaction) -> Unit {
  ignore(remaining_ms(self.state.deadline, Query))
  let client = self.state.begin_operation()
  defer self.state.finish_operation()
  let control = client.begin_request_control()
  defer client.end_request_control()
  self.state.releasing.val = true
  defer {
    self.state.released.val = true
  }
  let failure = try
    self.state.cleanup(() => {
      client.batch_execute(
        match self.savepoint {
          None => "COMMIT"
          Some(name) => "RELEASE SAVEPOINT \{name}"
        },
      )
    })
  catch {
    error => Some(error)
  } noraise {
    _ => None
  }
  let tags = control.command_tags()
  if self.savepoint is None && tags.contains("COMMIT") {
    self.record_completion(Committed, failure)
  } else if self.savepoint is None && tags.contains("ROLLBACK") {
    self.record_completion(RolledBack, failure)
    raise PoolError::CommitRolledBack
  } else if self.savepoint is Some(_) && tags.contains("RELEASE") {
    self.record_completion(SavepointReleased, failure)
  } else if control.was_sent() {
    client.abort()
    self.record_completion(OutcomeUnknown, failure)
    // Preserve explicit database errors while retaining the independent
    // uncertain completion record. Lost responses use a distinct error.
    if failure is Some(@client.ClientError::Database(_) as error) {
      raise error
    }
    raise PoolError::CommitOutcomeUnknown
  } else {
    self.state.released.val = false
    self.state.releasing.val = false
    self.rollback_internal() catch {
      _ => ()
    }
  }
  if failure is Some(error) {
    raise error
  }
}

///|
async fn[T, E] transaction_scope(
  parent : ClientLeaseState,
  sql : String,
  savepoint : String?,
  f : async (Transaction) -> Result[T, E],
  deadline : Deadline?,
  record : TransactionRecord,
  claimed~ : Bool = false,
) -> Result[T, E] {
  if !claimed {
    record.claim()
  }
  let client = parent.begin_operation()
  defer parent.finish_operation()
  let deadline = earlier_deadline(parent.deadline, deadline)
  let child = Session::new(
    parent.pool,
    parent.connection,
    deadline?,
    cleanup_deadline=parent.cleanup_deadline,
    cleanup_mode=parent.cleanup_mode,
  )
  let transaction : Transaction = { state: child.state, savepoint, record, }
  defer {
    ignore(transaction.abort_active_children())
    child.state.releasing.val = true
    child.state.released.val = true
  }
  let started = Ref(false)
  let rollback = () => {
    if !transaction.abort_active_children() &&
      started.val &&
      record.status.val == InProgress {
      transaction.rollback_internal()
    }
  }
  let result = with_scope_exit(
    () => {
      // BEGIN can complete as cancellation arrives; cleanup must own it
      // before cancellation is propagated to the caller.
      parent.supervise(
        client,
        () => {
          client.batch_execute(sql)
          started.val = true
          record.status.val = InProgress
        },
        deadline?,
      )
      with_deadline(deadline, Query, () => f(transaction))
    },
    result => {
      // Normal completion owns recovery for errors before COMMIT submission.
      // A possibly sent COMMIT records its outcome before raising, so the
      // conditional rollback cannot append SQL to an uncertain completion.
      errdefer (rollback() catch { _ => () })
      // commit_internal owns an operation itself; check children first.
      if transaction.abort_active_children() {
        if result is Ok(_) {
          raise PoolError::OperationInProgress
        }
      } else {
        match result {
          Ok(_) => transaction.commit_internal()
          Err(_) => transaction.rollback_internal() catch { _ => () }
        }
      }
    },
    rollback,
  )
  // A successful nested scope ends its cleanup episode. Failed cleanup keeps
  // the budget for the remaining outer unwind and retires the physical client.
  if !client.is_closed() && !parent.cleanup_mode {
    parent.cleanup_deadline.val = None
  }
  result
}

///|
/// Ok requests commit; Err, an exception, or cancellation requests rollback.
/// Normal completion records its outcome before propagating cancellation,
/// even if commit or rollback fails. An existing callback exception keeps priority.
pub async fn[T, E] Session::with_transaction(
  self : Session,
  f : async (Transaction) -> Result[T, E],
  options~ : TransactionOptions = TransactionOptions(),
  deadline? : Deadline,
  record~ : TransactionRecord = TransactionRecord(),
) -> Result[T, E] {
  transaction_scope(self.state, begin_sql(options), None, f, deadline, record)
}

///|
/// Ok releases this savepoint; it does not commit the enclosing transaction.
pub async fn[T, E] Transaction::with_savepoint(
  self : Transaction,
  name : String,
  f : async (Transaction) -> Result[T, E],
  deadline? : Deadline,
  record~ : TransactionRecord = TransactionRecord(),
) -> Result[T, E] {
  let name = quote_savepoint(name)
  transaction_scope(
    self.state,
    "SAVEPOINT \{name}",
    Some(name),
    f,
    deadline,
    record,
  )
}

///|
pub async fn[T, E] Transaction::with_transaction(
  self : Transaction,
  f : async (Transaction) -> Result[T, E],
  deadline? : Deadline,
  record~ : TransactionRecord = TransactionRecord(),
) -> Result[T, E] {
  self.with_savepoint(
    "pgpool_\{self.state.pool.next_scope_id.val}",
    f,
    deadline?,
    record~,
  )
}

///|
pub async fn[T, E] Pool::with_transaction(
  self : Pool,
  f : async (Transaction) -> Result[T, E],
  options~ : TransactionOptions = TransactionOptions(),
  deadline? : Deadline,
  timeouts? : Timeouts,
  record~ : TransactionRecord = TransactionRecord(),
) -> Result[T, E] {
  record.claim()
  self.with_session(
    session => {
      transaction_scope(
        session.state,
        begin_sql(options),
        None,
        f,
        deadline,
        record,
        claimed=true,
      )
    },
    deadline?,
    timeouts?,
  )
}
