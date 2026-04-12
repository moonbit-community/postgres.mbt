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
  manager_config : ManagerConfig
  slots : @async.Queue[Unit]
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
/// `PoolBuilder` stores this so callers can replace the default
/// `@client.connect` path during tests or custom integration.
struct Connector {
  run : async (@client.Config) -> (@client.Client, @client.Connection)
}

///|
/// Immutable builder value used to finish pool construction.
///
/// Each setter returns a new `PoolBuilder` with one field changed. The builder
/// itself does not own any live connection until `build()` runs.
struct PoolBuilder {
  group : @async.TaskGroup[Unit]
  targets : Array[@client.Config]
  pool_config : PoolConfig
  manager_config : ManagerConfig
  connector : Connector
  post_create : (async (@client.Client) -> Unit)?
  pre_recycle : (async (@client.Client) -> Unit)?
  post_recycle : (async (@client.Client) -> Unit)?
  target_session_attrs : TargetSessionAttrs
  load_balance_hosts : LoadBalanceHosts
}

///|
/// Administrative handle for one pool instance.
///
/// This separates operational controls, such as statement-cache management,
/// from the regular checkout API on `Pool`.
struct Manager {
  shared : Shared
}

///|
/// Administrative handle spanning every currently live statement cache in a pool.
///
/// The handle affects only connections that already exist when a method runs.
/// Future connections start with fresh empty caches.
struct StatementCaches {
  shared : Shared
}

///|
/// Physical PostgreSQL session plus its connection-local statement cache.
priv struct ConnectionState {
  id : Int
  group : @async.TaskGroup[Unit]
  client : @ref.Ref[@client.Client?]
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
  OperationScope(OperationScopeState)
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
  active_ops : @ref.Ref[Int]
  scope_active : @ref.Ref[Bool]
  releasing : @ref.Ref[Bool]
  released : @ref.Ref[Bool]
}

///|
/// Checked-out pooled client lease.
///
/// This handle represents temporary ownership of one physical PostgreSQL
/// session. Releasing the lease returns the session to the pool unless it has
/// been detached or the pool is closing.
struct Client {
  state : ClientLeaseState
}

///|
/// Administrative handle for the statement cache attached to one physical
/// PostgreSQL session.
///
/// A `StatementCache` is scoped to the connection, not to SQL text globally
/// across the pool. Callers should treat it as valid only while they still own
/// the client or transaction lease that exposed it.
struct StatementCache {
  connection : ConnectionState
}

///|
/// Prepared statement handle scoped to the current pooled callback.
///
/// The handle may wrap either a temporary statement or a lease on a cached
/// statement entry. It becomes invalid once the owning callback ends or after
/// `close()` is called explicitly.
pub struct PreparedStatement {
  /// Parameter types resolved by PostgreSQL.
  params : Array[@client.Type]
  /// Result columns produced by executing the statement.
  columns : Array[@client.Column]
  priv state : PreparedStatementState
}

///|
/// Shared high-level query surface implemented by pooled clients and pooled
/// transactions.
///
/// Implementors provide fully materialized query helpers that are safe to use
/// without handling raw protocol streams directly.
pub(open) trait GenericClient {
  /// Run one query and collect every returned row before the call completes.
  async query_all(Self, String, params? : Array[&@client.ToSql]) -> Array[
    @client.Row,
  ]
  /// Run one query and require exactly one row.
  async query_one(Self, String, params? : Array[&@client.ToSql]) -> @client.Row
  /// Run one query and allow zero or one rows.
  async query_opt(Self, String, params? : Array[&@client.ToSql]) -> @client.Row?
  /// Run one typed query and collect every returned row.
  async query_typed_all(
    Self,
    String,
    Array[@client.Type],
    params? : Array[&@client.ToSql],
  ) -> Array[@client.Row]
  /// Execute one command and return its affected row count.
  async execute(Self, String, params? : Array[&@client.ToSql]) -> Int
  /// Execute one or more SQL commands that do not return rows.
  async batch_execute(Self, String) -> Unit
  /// Perform a lightweight round-trip health check.
  async check_connection(Self) -> Unit
}

///|
/// Extended-query row stream scoped to one pooled callback.
///
/// The stream keeps low-level protocol state open until it is drained, finished,
/// or detached into background cleanup. The owning callback must not leak it
/// beyond the pool scope.
pub struct RowStream {
  /// Latest column metadata reported by the underlying stream.
  mut columns : Array[@client.Column]
  priv group : @async.TaskGroup[Unit]
  priv raw : @client.RowStream
  priv cleanup : (async () -> Unit)?
  priv cleanup_done : @ref.Ref[Bool]
  priv detached_task : @ref.Ref[@async.Task[Unit]?]
  priv completed : @ref.Ref[Bool]
}

///|
/// Simple-query protocol stream scoped to one pooled callback.
///
/// This is the low-level counterpart to `Client::with_simple_query`.
struct SimpleQueryStream {
  group : @async.TaskGroup[Unit]
  raw : @client.SimpleQueryStream
  detached_task : @ref.Ref[@async.Task[Unit]?]
  completed : @ref.Ref[Bool]
}

///|
/// COPY FROM STDIN sink scoped to one pooled callback.
///
/// The callback must eventually call `finish()` or `abort()`. If it returns
/// early, the pool aborts the COPY operation before the connection becomes
/// reusable.
struct CopyInSink {
  raw : @client.CopyInSink
  finished : @ref.Ref[Bool]
}

///|
/// COPY TO STDOUT stream scoped to one pooled callback.
///
/// As with `RowStream`, the callback may consume it directly or detach cleanup
/// into the background before returning.
pub struct CopyOutStream {
  /// Wire formats reported by PostgreSQL for COPY output columns.
  formats : Array[@client.WireFormat]
  priv group : @async.TaskGroup[Unit]
  priv raw : @client.CopyOutStream
  priv detached_task : @ref.Ref[@async.Task[Unit]?]
  priv completed : @ref.Ref[Bool]
}

///|
/// Bound portal scoped to one pooled callback.
///
/// A `Portal` can produce multiple fetch streams over time until it is closed.
/// It remains tied to the prepared-statement scope that created it.
pub struct Portal {
  /// Result columns for rows fetched from this portal.
  columns : Array[@client.Column]
  priv scope : PreparedStatementScope
  priv raw : @client.Portal
  priv closed : @ref.Ref[Bool]
}

///|
/// Shared state for one cancellable pooled-operation scope.
priv struct OperationScopeState {
  connection : ConnectionState
  cancel_token : @client.CancelToken
  active : @ref.Ref[Bool]
  closing : @ref.Ref[Bool]
  request_in_flight : @ref.Ref[Bool]
  next_request_id : @ref.Ref[Int]
  active_request_id : @ref.Ref[Int]
  last_cancelled_request_id : @ref.Ref[Int]
  cancel_in_flight : @ref.Ref[Int]
}

///|
/// Exclusive cancellable request scope created by `Client::run_cancellable`.
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
  active_ops : @ref.Ref[Int]
  scope_active : @ref.Ref[Bool]
  closing : @ref.Ref[Bool]
  finished : @ref.Ref[Bool]
  owner : TransactionOwner
  owner_released : @ref.Ref[Bool]
}

///|
/// Pooled transaction lease.
///
/// This wraps a live PostgreSQL transaction or savepoint-backed nested
/// transaction while keeping the underlying pooled connection checked out.
/// Callers should prefer helpers such as `with_transaction` or `run` unless
/// they are prepared to commit or roll back explicitly.
struct Transaction {
  state : TransactionState
}

///|
/// Builder for pooled transaction options before opening the transaction.
///
/// The builder stores SQL `BEGIN` modifiers and then starts the transaction on
/// the same checked-out client lease.
struct TransactionBuilder {
  client : Client
  isolation_level : IsolationLevel?
  read_only : Bool?
  deferrable : Bool?
}

///|
/// Create a pooled client wrapper around one checked-out client.
fn make_pooled_client(pool : Shared, connection : ConnectionState) -> Client {
  {
    state: {
      pool,
      connection,
      active_ops: @ref.new(0),
      scope_active: @ref.new(false),
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
    None => raise PoolError::LeaseReleased
  }
  let state = {
    connection,
    cancel_token: client.cancel_token(),
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
      active_ops: @ref.new(0),
      scope_active: @ref.new(false),
      closing: @ref.new(false),
      finished: @ref.new(false),
      owner,
      owner_released: @ref.new(false),
    },
  }
}

///|
/// Create a pooled transaction builder attached to one leased client.
fn make_transaction_builder(client : Client) -> TransactionBuilder {
  { client, isolation_level: None, read_only: None, deferrable: None }
}

///|
/// Build the default connector around `@client.connect`.
fn default_connector() -> Connector {
  { run: config => @client.connect(config) }
}

///|
/// Open one physical client connection through this connector.
async fn Connector::connect(
  self : Connector,
  config : @client.Config,
) -> (@client.Client, @client.Connection) {
  (self.run)(config)
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

///|
/// Wrap one raw row stream for pooled callback-scoped cleanup.
fn make_row_stream(
  group : @async.TaskGroup[Unit],
  raw : @client.RowStream,
  cleanup? : (async () -> Unit)? = None,
) -> RowStream {
  {
    columns: raw.columns,
    group,
    raw,
    cleanup,
    cleanup_done: @ref.new(false),
    detached_task: @ref.new(None),
    completed: @ref.new(false),
  }
}

///|
/// Wrap one raw simple-query stream for pooled callback-scoped cleanup.
fn make_simple_query_stream(
  group : @async.TaskGroup[Unit],
  raw : @client.SimpleQueryStream,
) -> SimpleQueryStream {
  { group, raw, detached_task: @ref.new(None), completed: @ref.new(false) }
}

///|
/// Wrap one raw COPY IN sink for pooled callback-scoped cleanup.
fn make_copy_in_sink(raw : @client.CopyInSink) -> CopyInSink {
  { raw, finished: @ref.new(false) }
}

///|
/// Wrap one raw COPY OUT stream for pooled callback-scoped cleanup.
fn make_copy_out_stream(
  group : @async.TaskGroup[Unit],
  raw : @client.CopyOutStream,
) -> CopyOutStream {
  {
    formats: raw.formats,
    group,
    raw,
    detached_task: @ref.new(None),
    completed: @ref.new(false),
  }
}

///|
/// Wrap one raw portal for pooled callback-scoped cleanup.
fn make_portal(scope : PreparedStatementScope, raw : @client.Portal) -> Portal {
  { columns: raw.columns, scope, raw, closed: @ref.new(false) }
}
