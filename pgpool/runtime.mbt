// Shared runtime state and private wrappers used by the pool package.

///|
/// SQL sequence matching `deadpool-postgres` clean recycling semantics.
let clean_recycle_sql = "CLOSE ALL; SET SESSION AUTHORIZATION DEFAULT; RESET ALL; UNLISTEN *; SELECT pg_advisory_unlock_all(); DISCARD TEMP; DISCARD SEQUENCES;"

///|
/// Shared mutable pool state. The package runs on one event loop, so this
/// state only needs async-safe coordination, not cross-thread primitives.
priv struct Shared {
  group : @async.TaskGroup[Unit]
  targets : Array[@client.Config]
  connector : Connector
  post_create : (async (@client.Client) -> Unit)?
  pre_recycle : (async (@client.Client) -> Unit)?
  post_recycle : (async (@client.Client) -> Unit)?
  target_session_attrs : TargetSessionAttrs
  load_balance_hosts : LoadBalanceHosts
  pool_config : @ref.Ref[PoolConfig]
  slots : @async.Queue[Unit]
  resize_debt : @ref.Ref[Int]
  idle : Array[ConnectionState]
  connections : Array[ConnectionState]
  next_connection_id : @ref.Ref[Int]
  size : @ref.Ref[Int]
  waiting : @ref.Ref[Int]
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
/// Wrapper around the callback that opens one physical PostgreSQL connection.
///
/// Pool options can replace the default `@client.connect` path during tests or
/// custom integration.
struct Connector {
  run : async (@client.Config, @async.TaskGroup[Unit]) -> @client.Client
}

///|
/// Runtime extension points used when constructing a pool.
pub struct PoolOptions {
  /// Custom connector used when checkout needs to open a new physical session.
  connector : Connector?
  /// Hook that runs after a new connection opens successfully.
  post_create : (async (@client.Client) -> Unit)?
  /// Hook that runs before checkout-time recycling of an idle connection.
  pre_recycle : (async (@client.Client) -> Unit)?
  /// Hook that runs after the configured recycling step succeeds.
  post_recycle : (async (@client.Client) -> Unit)?
}

///|
/// Physical PostgreSQL session plus its connection-local statement cache.
priv struct ConnectionState {
  id : Int
  client : @ref.Ref[@client.Client?]
  statement_cache_capacity : Int
  statement_cache : Array[CachedStatementEntry]
}

///|
/// Cached prepared statement attached to one physical PostgreSQL session.
priv struct CachedStatementEntry {
  sql : String
  param_types : Array[@client.Type]
  statement : @client.Statement
  in_use : @ref.Ref[Int]
  evicted : @ref.Ref[Bool]
}

///|
/// Shared statement-scope state used by scoped prepared-statement callbacks.
priv enum PreparedStatementScope {
  ClientScope(ClientLeaseState)
  TransactionScope(TransactionState)
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
  active_ops : @ref.Ref[Int]
  releasing : @ref.Ref[Bool]
  released : @ref.Ref[Bool]
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
pub struct PreparedStatement {
  /// Parameter types resolved by PostgreSQL.
  params : Array[@client.Type]
  /// Result columns produced by executing the statement.
  columns : Array[@client.Column]
  priv state : PreparedStatementState
}

///|
/// Shared high-level query surface implemented by pools, sessions, and pooled
/// transactions.
///
/// Implementors provide fully materialized query helpers that are safe to use
/// without handling raw protocol streams directly.
pub(open) trait GenericClient {
  /// Run one query and collect every returned row before the call completes.
  async fn query_all(Self, String, params? : Array[&@client.ToSql]) -> Array[
    @client.Row,
  ]
  /// Run one query and require exactly one row.
  async fn query_one(Self, String, params? : Array[&@client.ToSql]) -> @client.Row
  /// Run one query and allow zero or one rows.
  async fn query_opt(Self, String, params? : Array[&@client.ToSql]) -> @client.Row?
  /// Run one typed query and collect every returned row.
  async fn query_typed_all(
    Self,
    String,
    Array[@client.Type],
    params? : Array[&@client.ToSql],
  ) -> Array[@client.Row]
  /// Execute one command and return its affected row count.
  async fn execute(Self, String, params? : Array[&@client.ToSql]) -> Int
  /// Execute one or more SQL commands that do not return rows.
  async fn batch_execute(Self, String) -> Unit
  /// Perform a lightweight round-trip health check.
  async fn check_connection(Self) -> Unit
}

///|
/// Shared state for one cancellable pooled-operation scope.
priv struct OperationScopeState {
  connection : ConnectionState
  cancel_token : @client.CancelToken
  gate : @async.Mutex
  active : @ref.Ref[Bool]
  closing : @ref.Ref[Bool]
  request_in_flight : @ref.Ref[Bool]
  next_request_id : @ref.Ref[Int]
  active_request_id : @ref.Ref[Int]
  last_cancelled_request_id : @ref.Ref[Int]
  cancel_in_flight : @ref.Ref[Int]
}

///|
/// Exclusive cancellable request scope created by `Session::run_cancellable`.
///
/// Unlike plain `Client` operations, an `Operation` allows only one request at
/// a time so the paired cancel token can target a single in-flight request.
struct Operation {
  state : OperationScopeState
}

///|
/// Best-effort cancel handle paired with one `Operation` scope.
///
/// The token is valid only while the owning `run_cancellable` callback is still
/// active. After that it becomes inert instead of affecting a later borrower of
/// the same physical connection.
struct OperationCancelToken {
  state : OperationScopeState
}

///|
/// Outer scope keeping this pooled transaction's connection lease alive.
priv enum TransactionOwner {
  ClientLease(ClientLeaseState)
  ParentTransaction(TransactionState)
}

///|
/// Shared state for a transaction scoped to one pooled client operation.
priv struct TransactionState {
  connection : ConnectionState
  transaction : @ref.Ref[@client.Transaction?]
  gate : @async.Mutex
  finished : @ref.Ref[Bool]
  owner : TransactionOwner
  owner_released : @ref.Ref[Bool]
}

///|
/// Callback-scoped pooled transaction.
///
/// This wraps a live PostgreSQL transaction or savepoint while its
/// `with_transaction` / `with_savepoint` callback owns the pooled session.
/// Completion expires the handle before it can be used by a later borrower.
struct Transaction {
  state : TransactionState
}

///|
/// Create a pooled client wrapper around one checked-out client.
fn make_session(pool : Shared, connection : ConnectionState) -> Session {
  {
    state: {
      pool,
      connection,
      gate: Mutex(),
      active_ops: @ref.new(0),
      releasing: @ref.new(false),
      released: @ref.new(false),
    },
  }
}

///|
/// Create wrappers for one cancellable pooled-operation scope.
fn make_pooled_operation(
  connection : ConnectionState,
) -> (Operation, OperationCancelToken) raise {
  let client = match connection.client.val {
    Some(client) => client
    None => raise PoolError::ScopeExpired
  }
  let state = {
    connection,
    cancel_token: client.cancel_token(),
    gate: Mutex(),
    active: @ref.new(true),
    closing: @ref.new(false),
    request_in_flight: @ref.new(false),
    next_request_id: @ref.new(0),
    active_request_id: @ref.new(0),
    last_cancelled_request_id: @ref.new(0),
    cancel_in_flight: @ref.new(0),
  }
  ({ state, }, { state, })
}

///|
/// Create a pooled transaction wrapper around one live transaction.
fn make_pooled_transaction(
  connection : ConnectionState,
  transaction : @client.Transaction,
  owner : TransactionOwner,
) -> Transaction {
  {
    state: {
      connection,
      transaction: @ref.new(Some(transaction)),
      gate: Mutex(),
      finished: @ref.new(false),
      owner,
      owner_released: @ref.new(false),
    },
  }
}

///|
/// Build the default connector around `@client.connect`.
fn default_connector() -> Connector {
  { run: (config, group) => @client.connect(config, group) }
}

///|
/// Open one physical client connection through this connector.
async fn Connector::connect(
  self : Connector,
  config : @client.Config,
  group : @async.TaskGroup[Unit],
) -> @client.Client {
  (self.run)(config, group)
}

///|
/// Create a scoped prepared-statement wrapper around a raw statement handle.
fn make_prepared_statement(
  scope : PreparedStatementScope,
  handle : PreparedStatementHandle,
  statement : @client.Statement,
) -> PreparedStatement {
  {
    params: statement.params,
    columns: statement.columns,
    state: { scope, handle, active: @ref.new(true), released: @ref.new(false) },
  }
}
