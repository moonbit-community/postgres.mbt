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
    Some(port) => @strconv.parse_int(port)
  }
  let user = env_var("POSTGRES_USER").unwrap_or("moon")
  let password = env_var("POSTGRES_PASSWORD").unwrap_or("moonpass")
  let database = env_var("POSTGRES_DB").unwrap_or("moondb")
  Some({ host, port, user, password, database })
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
