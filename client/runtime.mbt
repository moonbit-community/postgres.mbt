// Core runtime state shared by all files in the client package.

///|
/// Internal transport abstraction that hides whether startup negotiated TLS.
///
/// A secure stream retains both the TLS state and its original TCP transport.
/// `Tls::close` releases only TLS resources, so the TCP handle must remain
/// available for deterministic transport teardown.
priv enum Stream {
  Plain(@socket.Tcp)
  Secure(@tls.Tls, @socket.Tcp)
}

///|
/// Release protocol state before closing the underlying transport.
fn Stream::close(self : Stream) -> Unit {
  match self {
    Plain(conn) => conn.close()
    Secure(tls, conn) => {
      tls.close()
      conn.close()
    }
  }
}

///|
/// Forward raw reads to the active transport implementation.
impl @io.Reader for Stream with fn _direct_read(self, buf, offset~, max_len~) {
  match self {
    Plain(conn) => conn._direct_read(buf, offset~, max_len~)
    Secure(tls, _) => tls._direct_read(buf, offset~, max_len~)
  }
}

///|
/// Reuse the underlying transport's internal read buffer.
impl @io.Reader for Stream with fn _get_internal_buffer(self) {
  match self {
    Plain(conn) => conn._get_internal_buffer()
    Secure(tls, _) => tls._get_internal_buffer()
  }
}

///|
extend Stream with @io.Reader::{read_exactly}

///|
/// Forward writes to the active transport implementation.
impl @io.Writer for Stream with fn write_once(self, buf, offset~, len~) {
  match self {
    Plain(conn) => conn.write_once(buf, offset~, len~)
    Secure(tls, _) => tls.write_once(buf, offset~, len~)
  }
}

///|
extend Stream with @io.Writer::{write}

///|
/// High-level request categories sent from `Client` to the connection loop.
///
/// `Messages` covers ordinary simple and extended protocol traffic.
/// `CopyIn` marks a request that must interleave outbound `CopyData` frames with
/// inbound backend messages.
/// `Terminate` requests graceful shutdown after earlier logical operations.
priv enum RequestKind {
  Messages
  CopyIn
  Terminate
}

///|
/// Items the client can push into an active COPY FROM STDIN request.
priv enum CopyInAction {
  /// Send one `CopyData` payload.
  Data(Bytes)
  /// Finish COPY successfully with `CopyDone`.
  Finish
  /// Abort COPY with a textual error message.
  Fail(String)
}

///|
/// A small bounded per-request buffer prevents unread streams from accumulating
/// responses without bound.
let request_response_queue_kind : @aqueue.Kind = Blocking(8)

///|
/// One outbound request queued for the private driver.
///
/// The request owns the exact bytes to write on the wire and the queue that the
/// connection loop will feed with backend messages for this request.
priv struct Request {
  kind : RequestKind
  bytes : Bytes
  responses : @async.Queue[@backend.Message]
  copy_input : @async.Queue[CopyInAction]?
  copy_error : @ref.Ref[DatabaseError?]?
}

///|
/// FIFO gate that gives one logical operation exclusive use of a connection.
///
/// The permit covers the whole operation rather than one wire request. A query,
/// for example, may prepare a statement, inspect type metadata, execute it, and
/// close temporary server state before releasing the connection.
priv struct OperationGate {
  mutex : @async.Mutex
}

///|
/// One idempotently releasable acquisition of an `OperationGate`.
priv struct OperationPermit {
  gate : OperationGate
  released : @ref.Ref[Bool]
}

///|
/// Private capability passed through nested pieces of one logical operation.
///
/// Internal helpers that receive this context must not reacquire the client's
/// operation gate. This is what lets type-cache catalog queries and deferred
/// statement cleanup remain part of their parent operation without deadlocking.
priv struct OpContext {
  client : Client
}

///|
/// Shared mutable state visible to every handle created from one connection.
///
/// The client, prepared statements, transactions, cancellation tokens, and
/// private driver task reference this struct to coordinate lifecycle, cache
/// type metadata, and publish async messages without global state.
priv struct Shared {
  config : Config
  requests : @async.Queue[Request]
  async_messages : @async.Queue[AsyncMessage]
  dropped_async_messages : @ref.Ref[Int64]
  async_message_handler : @ref.Ref[((AsyncMessage) -> Unit)?]
  root_transaction_occupancy : @ref.Ref[Int]
  control : DrainControl
  ready : Completion
  done : Completion
  started : @ref.Ref[Bool]
  runtime_error : @ref.Ref[Error?]
  parameters : Map[String, String]
  types : Map[@proto.Oid, Type]
  process_id : @ref.Ref[Int]
  secret_key : @ref.Ref[Int]
  transaction_status : @ref.Ref[Byte]
  closed : @ref.Ref[Bool]
  closing : @ref.Ref[Bool]
  close_requested : @ref.Ref[Bool]
  aborted : @ref.Ref[Bool]
  operation_gate : OperationGate
  driver_task : @ref.Ref[@async.Task[Unit]?]
  next_id : @ref.Ref[Int]
}

///|
/// User-facing handle used to enqueue work onto the private driver.
///
/// `Client` is intentionally lightweight. It does not own the socket and can be
/// cloned freely by value because all mutable state lives inside `Shared`.
struct Client {
  shared : Shared
}

///|
/// Owns the socket and all background work for a single client.
/// Spawn `run` once, then await `Client::ready` before using startup metadata.
struct ClientExecutor {
  shared : Shared
}

///|
/// Deferred cleanup performed once a row stream reaches its terminal state.
///
/// Helper APIs that create temporary prepared statements attach one of these to
/// the returned `RowStream` so the statement is closed only after all rows and
/// trailing protocol messages have been consumed.
priv struct StreamCleanup {
  context : OpContext
  bytes : Bytes
  mut done : Bool
}

///|
/// Socket-owning private runtime task.
priv struct Driver {
  shared : Shared
  stream : Stream
}

///|
/// Prepared statement stored on the PostgreSQL server.
///
/// The public `params` and `columns` fields expose the server-inferred
/// parameter and result metadata so callers can inspect what PostgreSQL
/// resolved during preparation.
pub struct Statement {
  priv client : Client
  priv name : Bytes
  /// Parameter types in server order.
  params : Array[Type]
  /// Result columns produced by executing the statement.
  columns : Array[Column]
  priv closed : @ref.Ref[Bool]
}

///|
/// Bound portal ready for repeated or chunked execution.
///
/// Portals are created and used through an open transaction. Fetch rows
/// incrementally with
/// `Transaction::query_portal` or `Transaction::with_portal_stream`.
pub struct Portal {
  priv name : Bytes
  /// Result columns currently associated with the portal.
  columns : Array[Column]
  priv closed : @ref.Ref[Bool]
}

///|
/// Capability object used to send a PostgreSQL cancel request.
///
/// PostgreSQL cancellation happens over a separate short-lived TCP connection,
/// so the token stores the backend process ID and secret key learned during
/// startup rather than a direct handle to the existing socket.
struct CancelToken {
  config : Config
  process_id : @ref.Ref[Int]
  secret_key : @ref.Ref[Int]
  closed : @ref.Ref[Bool]
}

///|
/// Client-side sink for an active `COPY ... FROM STDIN` operation.
///
/// The sink feeds `CopyInAction` values to the connection loop while the paired
/// response queue waits for the backend's completion status.
struct CopyInSink {
  control : DrainControl
  input : @async.Queue[CopyInAction]
  responses : @async.Queue[@backend.Message]
  finished : @ref.Ref[Bool]
  abandoned_done : @ref.Ref[Completion?]
  permit : OperationPermit
}

///|
/// Transaction handle that enforces single-use commit or rollback semantics.
///
/// Nested transactions are implemented with savepoints. The same handle shape
/// is reused for the top-level transaction and for nested savepoint scopes.
struct Transaction {
  client : Client
  context : OpContext
  scope_gate : OperationGate
  child : @ref.Ref[TransactionChild?]
  scoped_resources : @ref.Ref[Int]
  closing : @ref.Ref[Completion?]
  root_permit : OperationPermit?
  parent_permit : OperationPermit?
  savepoint : String?
  finished : @ref.Ref[Bool]
}

///|
// A child owns the scope permit until its protocol work has completed.
// Creating is published before startup can suspend, so completion can wait
// without trying to acquire the permit held by the creator.
priv enum TransactionChild {
  Creating(Completion)
  Stream(RowStream)
  Nested(Transaction)
}
