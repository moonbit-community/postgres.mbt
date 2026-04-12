///|
/// Shared connection parameters for the integration tests.
/// This keeps environment parsing in one place so individual tests can focus on behavior instead of setup.
struct IntegrationConfig {
  host : String
  port : Int
  user : String
  password : String
  database : String
}

///|
/// Read one environment variable.
/// Missing variables become `None`, so callers can decide whether to use a default.
async fn env_var(name : String) -> String? {
  let (code, output) = @process.collect_stdout("/usr/bin/printenv", [name])
  if code != 0 {
    return None
  }
  Some(output.text().trim().to_string())
}

///|
/// Decide whether integration tests should run and fill in default connection parameters.
/// Each test uses the same entry point to decide whether to run and where to connect.
async fn integration_config() -> IntegrationConfig? {
  guard env_var("RUN_POSTGRES_INTEGRATION") == Some("1") else { return None }
  let host = env_var("POSTGRES_HOST").unwrap_or("127.0.0.1")
  let port = match env_var("POSTGRES_PORT") {
    None => 5432
    Some(port) => @string.parse_int(port)
  }
  let user = env_var("POSTGRES_USER").unwrap_or("moon")
  let password = env_var("POSTGRES_PASSWORD").unwrap_or("moonpass")
  let database = env_var("POSTGRES_DB").unwrap_or("moondb")
  Some({ host, port, user, password, database })
}

///|
/// Some environments intentionally make TLS verification fail.
/// This flag lets the TLS tests choose the matching branch.
async fn integration_tls_failure_expected() -> Bool {
  env_var("POSTGRES_TLS_EXPECT_FAILURE") == Some("1")
}

///|
/// Turn shared integration settings into a client config.
/// Optional fields stay overridable so each test can change only the host, TLS mode, or application name it cares about.
fn as_client_config(
  config : IntegrationConfig,
  host? : String = config.host,
  hostaddr? : String,
  ssl_mode? : @client.SslMode = @client.SslMode::Disable,
  ssl_root_cert? : String,
  application_name~ : String,
) -> @client.Config {
  @client.Config::new(
    host,
    hostaddr?,
    user=config.user,
    database=config.database,
    password=config.password,
    port=config.port,
    ssl_mode~,
    ssl_root_cert?,
    application_name~,
  )
}

///|
/// Build a config specifically for authentication tests.
/// Tests can override the username and password to cover cleartext and SCRAM cases.
fn auth_client_config(
  config : IntegrationConfig,
  user : String,
  password? : String? = Some(config.password),
  ssl_mode? : @client.SslMode = @client.SslMode::Disable,
  application_name~ : String,
) -> @client.Config {
  match password {
    Some(password) =>
      @client.Config::new(
        config.host,
        user~,
        database=config.database,
        password~,
        port=config.port,
        ssl_mode~,
        application_name~,
      )
    None =>
      @client.Config::new(
        config.host,
        user~,
        database=config.database,
        port=config.port,
        ssl_mode~,
        application_name~,
      )
  }
}

///|
/// Derive pool settings from a client config.
/// The pool tests reuse the same connection settings as the client tests so the two suites do not drift apart.
fn make_pool(
  group : @async.TaskGroup[Unit],
  config : @client.Config,
  pool_config : @pgpool.PoolConfig,
  manager? : @pgpool.ManagerConfig = @pgpool.ManagerConfig::new(),
) -> @pgpool.Pool raise {
  let config : @pgpool.Config = {
    user: Some(config.user),
    password: config.password,
    dbname: Some(config.database),
    options: config.options,
    application_name: config.application_name,
    ssl_mode: Some(config.ssl_mode),
    ssl_root_cert: config.ssl_root_cert,
    channel_binding: Some(config.channel_binding),
    host: Some(config.host),
    hosts: None,
    hostaddr: config.hostaddr,
    hostaddrs: None,
    port: Some(config.port),
    ports: None,
    connect_timeout_ms: config.connect_timeout_ms,
    keepalives: config.keepalives,
    keepalives_idle_s: config.keepalives_idle_s,
    target_session_attrs: Some(@pgpool.TargetSessionAttrs::any()),
    load_balance_hosts: Some(@pgpool.LoadBalanceHosts::Disable),
    manager: Some(manager),
    pool: Some(pool_config),
  }
  config.create_pool(group)
}

///|
/// These `expect_*` helpers make expected failures read directly.
/// Tests can state the error kind they expect and then assert on the important fields.
fn[T] expect_database_error(
  result : Result[T, Error],
) -> @client.DatabaseError raise {
  guard result is Err(@client.ClientError::Database(err)) else {
    fail("expected database error")
  }
  err
}

///|
/// Extract the text message from an authentication error.
fn[T] expect_authentication_error(result : Result[T, Error]) -> String raise {
  guard result is Err(@client.ClientError::Authentication(message)) else {
    fail("expected authentication error")
  }
  message
}

///|
/// Extract row-count errors for `query_one` and `query_opt` tests.
fn[T] expect_row_count_error(result : Result[T, Error]) -> String raise {
  guard result is Err(@client.ClientError::RowCount(message)) else {
    fail("expected row count error")
  }
  message
}

///|
/// Extract type-mismatch errors so tests can assert on both the MoonBit type name and PostgreSQL type metadata.
fn[T] expect_wrong_type_error(
  result : Result[T, Error],
) -> @client.WrongTypeError raise {
  guard result is Err(@client.ClientError::WrongType(err)) else {
    fail("expected wrong type error")
  }
  err
}

///|
/// Extract the message from a TLS-related error.
fn[T] expect_ssl_error(result : Result[T, Error]) -> String raise {
  guard result is Err(@client.ClientError::Ssl(message)) else {
    fail("expected SSL error")
  }
  message
}

///|
/// Extract the message for errors caused by using a closed stream or handle.
fn[T] expect_closed_error(result : Result[T, Error]) -> String raise {
  guard result is Err(@client.ClientError::Closed(message)) else {
    fail("expected closed error")
  }
  message
}

///|
/// Wait until the pool reaches the expected physical connection count.
/// This lets multi-connection tests warm up the pool before asserting on session isolation.
async fn wait_for_pool_size_or_fail(
  pool : @pgpool.Pool,
  expected : Int,
  message : String,
  polls? : Int = 500,
) -> Unit {
  let mut remaining = polls
  while remaining > 0 {
    if pool.status().size == expected {
      return
    }
    remaining -= 1
    @async.sleep(10)
  }
  fail(message)
}
