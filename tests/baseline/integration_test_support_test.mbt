///|
struct IntegrationConfig {
  host : String
  port : Int
  user : String
  password : String
  database : String
}

///|
async fn env_var(name : String) -> String? {
  let (code, output) = @process.collect_stdout("/usr/bin/printenv", [name])
  if code != 0 {
    return None
  }
  Some(output.text().trim().to_string())
}

///|
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
async fn integration_tls_failure_expected() -> Bool {
  env_var("POSTGRES_TLS_EXPECT_FAILURE") == Some("1")
}

///|
fn as_client_config(
  config : IntegrationConfig,
  ssl_mode? : @client.SslMode = @client.SslMode::disable(),
  application_name? : String = "moonbit-postgres",
) -> @client.Config {
  @client.Config::new(
    config.host,
    user=config.user,
    database=config.database,
    password=config.password,
    port=config.port,
    ssl_mode~,
    application_name~,
  )
}

///|
fn auth_client_config(
  config : IntegrationConfig,
  user : String,
  password? : String? = Some(config.password),
  ssl_mode? : @client.SslMode = @client.SslMode::disable(),
  application_name? : String = "moonbit-postgres",
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
fn[T] expect_database_error(
  result : Result[T, Error],
) -> @client.DatabaseError raise {
  guard result is Err(@client.ClientError::Database(err)) else {
    fail("expected database error")
  }
  err
}

///|
fn[T] expect_authentication_error(result : Result[T, Error]) -> String raise {
  guard result is Err(@client.ClientError::Authentication(message)) else {
    fail("expected authentication error")
  }
  message
}

///|
fn[T] expect_row_count_error(result : Result[T, Error]) -> String raise {
  guard result is Err(@client.ClientError::RowCount(message)) else {
    fail("expected row count error")
  }
  message
}

///|
fn[T] expect_wrong_type_error(
  result : Result[T, Error],
) -> @client.WrongTypeError raise {
  guard result is Err(@client.ClientError::WrongType(err)) else {
    fail("expected wrong type error")
  }
  err
}

///|
fn[T] expect_ssl_error(result : Result[T, Error]) -> String raise {
  guard result is Err(@client.ClientError::Ssl(message)) else {
    fail("expected SSL error")
  }
  message
}

///|
fn[T] expect_closed_error(result : Result[T, Error]) -> String raise {
  guard result is Err(@client.ClientError::Closed(message)) else {
    fail("expected closed error")
  }
  message
}
