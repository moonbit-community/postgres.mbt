// Shared runtime state and private wrappers used by the pool package.

///|
/// Shared mutable pool state. The package runs on one event loop, so this
/// state only needs async-safe coordination, not cross-thread primitives.
/// An idle connection removed for recycling stays in `connections` and `size`
/// until checkout succeeds or retirement removes it. Cancelled recycling must
/// retire it; the checkout owner separately restores its reserved `slots` entry.
priv struct Shared {
  ready : Completion
  done : Completion
  shutdown : Completion
  started : @ref.Ref[Bool]
  create_requests : @async.Queue[CreateRequest]
  close_requests : @async.Queue[@client.Client]
  pending_creations : @ref.Ref[Int32]
  active_creations : Array[CreateRequest]
  next_creation_id : @ref.Ref[Int32]
  targets : Array[@client.Config]
  connector : Connector
  initialize_session : (async (Session) -> Unit)?
  before_acquire : (async (Session) -> Unit)?
  events : @async.Queue[PoolEvent]
  dropped_events : @ref.Ref[Int64]
  next_scope_id : @ref.Ref[Int64]
  target_session_attrs : TargetSessionAttrs
  load_balance_hosts : LoadBalanceHosts
  pool_config : @ref.Ref[PoolConfig]
  slots : @async.Queue[Unit]
  resize_debt : @ref.Ref[Int32]
  idle : Array[ConnectionState]
  connections : Array[ConnectionState]
  next_connection_id : @ref.Ref[Int32]
  async_messages : @async.Queue[PoolAsyncMessage]
  dropped_async_messages : @ref.Ref[Int64]
  size : @ref.Ref[Int32]
  waiting : @ref.Ref[Int32]
  closed : @ref.Ref[Bool]
}

///|
/// Public handle to one connection-pool instance.
///
/// A `Pool` owns capacity accounting, idle connections, and the policies used
/// to create and recycle physical PostgreSQL sessions.
struct Pool {
  shared : Shared
}

///|
/// Asynchronous backend message tagged with its physical pool connection.
pub struct PoolAsyncMessage {
  connection_id : Int32
  message : @client.AsyncMessage
} derive(Debug, Eq)

///|
pub extend PoolAsyncMessage with @debug.Debug::{to_repr}

///|
pub extend PoolAsyncMessage with Eq::{not_equal, equal}

///|
/// Owns all physical connection executors and pool maintenance tasks.
struct PoolExecutor {
  shared : Shared
}

///|
priv struct CreateRequest {
  id : Int32
  physical_id : Int32
  target : @client.Config
  result : @async.Queue[(@client.Client, Int32)]
  cancelled : @ref.Ref[Bool]
  task : @ref.Ref[@async.Task[Unit]?]
}

///|
/// Wrapper around the callback that opens one physical PostgreSQL connection.
///
/// Pool options can replace the default `@client.Client::create` path during tests or
/// custom integration.
struct Connector {
  run : async (@client.Config) -> (@client.Client, @client.ClientExecutor)
}

///|
/// Runtime extension points used when constructing a pool.
pub struct PoolOptions {
  /// Custom connector used when checkout needs to open a new physical session.
  connector : Connector?
  /// Establish the application baseline on creation and after DISCARD ALL.
  initialize_session : (async (Session) -> Unit)?
  /// Validate a scoped session before each acquisition. Failures end checkout.
  before_acquire : (async (Session) -> Unit)?
}

///|
/// Physical PostgreSQL session plus its connection-local statement cache.
priv struct ConnectionState {
  target : String
  failure : @ref.Ref[Error?]
  id : Int32
  client : @ref.Ref[@client.Client?]
  statement_cache_capacity : Int32
  statement_cache : Array[CachedStatementEntry]
}

///|
/// Cached prepared statement attached to one physical PostgreSQL session.
priv struct CachedStatementEntry {
  sql : String
  param_types : Array[@client.Type]
  statement : @client.Statement
  in_use : @ref.Ref[Int32]
  evicted : @ref.Ref[Bool]
}

///|
/// Shared statement-scope state used by scoped prepared-statement callbacks.
priv enum PreparedStatementScope {
  ClientScope(ClientLeaseState)
}

///|
/// Lease on one cached statement entry while a scoped callback is active.
priv struct CachedStatementLease {
  entry : CachedStatementEntry
}

///|
/// Underlying prepared-statement handle owned by one scoped callback.
priv enum PreparedStatementHandle {
  Temporary(@client.Statement)
  Cached(CachedStatementLease)
}

///|
/// Shared mutable state for one scoped prepared statement.
priv struct PreparedStatementState {
  scope : PreparedStatementScope
  deadline : Deadline?
  handle : PreparedStatementHandle
  active : @ref.Ref[Bool]
  released : @ref.Ref[Bool]
}

///|
/// Shared lease state for one checked-out pooled client.
priv struct ClientLeaseState {
  pool : Shared
  connection : ConnectionState
  gate : @async.Mutex
  active_ops : @ref.Ref[Int32]
  releasing : @ref.Ref[Bool]
  released : @ref.Ref[Bool]
  deadline : Deadline?
  cleanup_deadline : @ref.Ref[Deadline?]
  cleanup_mode : Bool
  active_control : @ref.Ref[@client.RequestControl?]
  id : Int64
}

///|
/// Callback-scoped pooled session.
///
/// This handle temporarily owns one physical PostgreSQL session and expires
/// when the `Pool::with_session` callback returns.
struct Session {
  state : ClientLeaseState
}

///|
/// Prepared statement handle scoped to the current pooled callback.
///
/// The handle may wrap either a temporary statement or a lease on a cached
/// statement entry. It becomes invalid once the owning callback ends.
struct PreparedStatement {
  /// Parameter types resolved by PostgreSQL.
  params : Array[@client.Type]
  /// Result columns produced by executing the statement.
  columns : Array[@client.Column]
  state : PreparedStatementState
}

///|
/// Return a read-only view of the prepared statement's parameter types.
pub fn PreparedStatement::params(
  self : PreparedStatement,
) -> ArrayView[@client.Type] {
  self.params[:]
}

///|
/// Return a read-only view of the prepared statement's result columns.
pub fn PreparedStatement::columns(
  self : PreparedStatement,
) -> ArrayView[@client.Column] {
  self.columns[:]
}

///|
/// Fully consumed query operations shared by Pool, Session and Transaction.
pub(open) trait GenericClient {
  async fn query_all(
    Self,
    String,
    params? : Array[&@client.ToSql],
    deadline? : Deadline,
  ) -> Array[@client.Row]
  async fn query_one(
    Self,
    String,
    params? : Array[&@client.ToSql],
    deadline? : Deadline,
  ) -> @client.Row
  async fn query_opt(
    Self,
    String,
    params? : Array[&@client.ToSql],
    deadline? : Deadline,
  ) -> @client.Row?
  async fn execute(
    Self,
    String,
    params? : Array[&@client.ToSql],
    deadline? : Deadline,
  ) -> UInt64
  async fn query_typed_all(
    Self,
    String,
    Array[@client.Type],
    params? : Array[&@client.ToSql],
    deadline? : Deadline,
  ) -> Array[@client.Row]
  async fn query_typed_one(
    Self,
    String,
    Array[@client.Type],
    params? : Array[&@client.ToSql],
    deadline? : Deadline,
  ) -> @client.Row
  async fn query_typed_opt(
    Self,
    String,
    Array[@client.Type],
    params? : Array[&@client.ToSql],
    deadline? : Deadline,
  ) -> @client.Row?
  async fn execute_typed(
    Self,
    String,
    Array[@client.Type],
    params? : Array[&@client.ToSql],
    deadline? : Deadline,
  ) -> UInt64
  async fn batch_execute(Self, String, deadline? : Deadline) -> Unit
  async fn check_connection(Self, deadline? : Deadline) -> Unit
}

///|
/// Transaction callback capability. Completion belongs to its scope helper.
struct Transaction {
  state : ClientLeaseState
  savepoint : String?
  record : TransactionRecord
}

///|
fn Session::new(
  pool : Shared,
  connection : ConnectionState,
  deadline? : Deadline,
  cleanup_deadline~ : @ref.Ref[Deadline?] = Ref(None),
  cleanup_mode~ : Bool = false,
) -> Session {
  pool.next_scope_id.val += 1L
  {
    state: {
      pool,
      connection,
      gate: Mutex(),
      active_ops: Ref(0),
      releasing: Ref(false),
      released: Ref(false),
      deadline,
      cleanup_deadline,
      cleanup_mode,
      active_control: Ref(None),
      id: pool.next_scope_id.val,
    },
  }
}

///|
/// Build the default connector around `Client::create`.
fn default_connector() -> Connector {
  { run: config => @client.Client::create(config), }
}

///|
/// Open one physical client connection through this connector.
async fn Connector::connect(
  self : Connector,
  config : @client.Config,
) -> (@client.Client, @client.ClientExecutor) {
  (self.run)(config)
}

///|
/// Create a scoped prepared-statement wrapper around a raw statement handle.
fn PreparedStatement::new(
  scope : PreparedStatementScope,
  handle : PreparedStatementHandle,
  statement : @client.Statement,
  deadline? : Deadline,
) -> PreparedStatement {
  {
    params: statement.params().to_owned(),
    columns: statement.columns().to_owned(),
    state: { scope, deadline, handle, active: Ref(true), released: Ref(false), },
  }
}
