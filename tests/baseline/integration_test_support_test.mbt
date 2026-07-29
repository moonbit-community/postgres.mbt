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
fn env_var(name : String) -> String? {
  @env.get_env_var(name)
}

///|
/// Decide whether integration tests should run and fill in default connection parameters.
/// Each test uses the same entry point to decide whether to run and where to connect.
fn integration_config() -> IntegrationConfig? raise {
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
fn integration_tls_failure_expected() -> Bool {
  env_var("POSTGRES_TLS_EXPECT_FAILURE") == Some("1")
}

///|
/// Turn shared integration settings into a client config.
/// Optional fields stay overridable so each test can change only the host, TLS mode, or application name it cares about.
fn as_client_config(
  config : IntegrationConfig,
  host? : String = config.host,
  hostaddr? : String,
  ssl_mode? : @client.SslMode = Disable,
  ssl_root_cert? : String,
  channel_binding? : @client.ChannelBinding = Disable,
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
    channel_binding~,
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
  ssl_mode? : @client.SslMode = Disable,
  channel_binding? : @client.ChannelBinding = Disable,
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
        channel_binding~,
        application_name~,
      )
    None =>
      @client.Config::new(
        config.host,
        user~,
        database=config.database,
        port=config.port,
        ssl_mode~,
        channel_binding~,
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
) -> @pgpool.Pool raise {
  let config = @pgpool.Config::new(
    config.host,
    hostaddr?=config.hostaddr,
    user=config.user,
    dbname=config.database,
    password?=config.password,
    port=config.port,
    ssl_mode=config.ssl_mode,
    ssl_root_cert?=config.ssl_root_cert,
    channel_binding=config.channel_binding,
    application_name=config.application_name,
    options?=config.options,
    connect_timeout_ms?=config.connect_timeout_ms,
    keepalives?=config.keepalives,
    keepalives_idle_s?=config.keepalives_idle_s,
    target_session_attrs=@pgpool.TargetSessionAttrs::any(),
    load_balance_hosts=Disable,
    pool=pool_config,
  )
  @pgpool.Pool::new(config, group)
}

///|
/// These `expect_*` helpers make expected failures read directly.
/// Tests can state the error kind they expect and then assert on the important fields.
fn expect_database_error(error : Error) -> @client.DatabaseError raise {
  guard error is @client.ClientError::Database(err) else {
    fail("expected database error")
  }
  err
}

///|
/// Extract the text message from an authentication error.
fn expect_authentication_error(error : Error) -> String raise {
  guard error is @client.ClientError::Authentication(message) else {
    fail("expected authentication error")
  }
  message
}

///|
/// Extract row-count errors for `query_one` and `query_opt` tests.
fn expect_row_count_error(error : Error) -> String raise {
  guard error is @client.ClientError::RowCount(message) else {
    fail("expected row count error")
  }
  message
}

///|
/// Extract type-mismatch errors so tests can assert on both the MoonBit type name and PostgreSQL type metadata.
fn expect_wrong_type_error(error : Error) -> @client.WrongTypeError raise {
  guard error is @client.ClientError::WrongType(err) else {
    fail("expected wrong type error")
  }
  err
}

///|
/// Extract the message from a TLS-related error.
fn expect_ssl_error(error : Error) -> String raise {
  guard error is @client.ClientError::Ssl(message) else {
    fail("expected SSL error")
  }
  message
}

///|
/// Extract the message for errors caused by using a closed stream or handle.
fn expect_closed_error(error : Error) -> String raise {
  guard error is @client.ClientError::Closed(message) else {
    fail("expected closed error")
  }
  message
}

///|
/// Async counterpart to `@test.expect_error` for integration tests.
///
/// The project currently uses async 0.19.0, whose public test support does not
/// provide this helper.
#callsite(autofill(loc))
async fn[T, E : Error] expect_error_async(
  f : async () -> T raise E,
  loc~ : SourceLoc,
) -> E {
  try f() catch {
    error => error
  } noraise {
    _ =>
      @test.fail(
        "expected error, but program succeeded without raising anything",
        loc~,
      )
  }
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
