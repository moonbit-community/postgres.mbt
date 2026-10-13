///|
pub(all) enum PoolEventKind {
  ConnectionReplaced
  HealthChecked
  HookCompleted
  CancelRequested
  CleanupCompleted
  TransactionCompleted
  ConnectionAttempt
} derive(Eq, Debug)

///|
/// Original errors remain inspectable, including PostgreSQL SQLSTATE fields.
pub struct PoolEvent {
  kind : PoolEventKind
  connection_id : Int32?
  scope_id : Int64?
  request_id : Int64?
  phase : TimeoutKind
  target : String?
  elapsed_ms : Int64
  cause : Error?
  transaction_status : TransactionStatus?
} derive(Debug)

///|
pub struct ConnectionAttempt {
  target : String
  phase : TimeoutKind
  elapsed_ms : Int64
  cause : Error
} derive(Debug)

///|
pub suberror AcquireError {
  AttemptsFailed(Array[ConnectionAttempt])
} derive(Debug)

///|
fn emit_event(
  shared : Shared,
  kind : PoolEventKind,
  phase : TimeoutKind,
  connection_id? : Int32,
  scope_id? : Int64,
  request_id? : Int64,
  target? : String,
  started~ : Int64 = @async.now(),
  cause? : Error,
  transaction_status? : TransactionStatus,
) -> Unit {
  let event = {
    kind,
    phase,
    connection_id,
    scope_id,
    request_id,
    target,
    elapsed_ms: @async.now() - started,
    cause,
    transaction_status,
  }
  if (shared.events.try_put(event) catch { _ => true }) {
    return
  }
  ignore(shared.events.try_get()) catch {
    _ => ()
  }
  shared.dropped_events.val += 1L
  ignore(shared.events.try_put(event)) catch {
    _ => ()
  }
}

///|
/// Receive diagnostics. Buffered events remain readable after pool shutdown.
pub async fn Pool::next_event(self : Pool) -> PoolEvent? {
  Some(self.shared.events.get()) catch {
    @aqueue.QueueAlreadyClosed => None
    error => raise error
  }
}

///|
pub fn Pool::dropped_events(self : Pool) -> Int64 {
  self.shared.dropped_events.val
}

///|
pub(all) enum TransactionStatus {
  NotStarted
  InProgress
  Committed
  RolledBack
  SavepointReleased
  OutcomeUnknown
} derive(Eq, Debug)

///|
/// One-shot completion storage, independent of task cancellation and events.
struct TransactionRecord {
  used : @ref.Ref[Bool]
  status : @ref.Ref[TransactionStatus]
}

///|
pub fn TransactionRecord::TransactionRecord() -> TransactionRecord {
  { used: Ref(false), status: Ref(NotStarted), }
}

///|
pub fn TransactionRecord::status(self : TransactionRecord) -> TransactionStatus {
  self.status.val
}

///|
fn TransactionRecord::claim(self : TransactionRecord) -> Unit raise {
  if self.used.val {
    raise PoolError::TransactionRecordUsed
  }
  self.used.val = true
}

///|
pub extend PoolEventKind with @debug.Debug::{to_repr}

///|
pub extend PoolEventKind with Eq::{equal, not_equal}

///|
pub extend TransactionStatus with @debug.Debug::{to_repr}

///|
pub extend TransactionStatus with Eq::{equal, not_equal}

///|
pub extend PoolEvent with @debug.Debug::{to_repr}

///|
pub extend ConnectionAttempt with @debug.Debug::{to_repr}

///|
pub extend AcquireError with @debug.Debug::{to_repr}
