///|
pub struct CliOptions {
  scenario : String
  iterations : Int
  warmup : Int
  workers : Int
}

///|
priv struct PostgresEnv {
  host : String
  port : Int
  user : String
  password : String
  database : String
}

///|
pub fn parse_cli(args : ArrayView[String]) -> CliOptions {
  let mut scenario = "all"
  let mut iterations = 200
  let mut warmup = 50
  let mut workers = 8
  for rest_args = args {
    match rest_args {
      [] => break ()
      ["--scenario", .. rest] => {
        guard rest is [value, .. rest] else {
          abort("expected scenario name after --scenario")
        }
        scenario = value
        continue rest
      }
      ["--iterations", .. rest] => {
        guard rest is [value, .. rest] else {
          abort("expected integer after --iterations")
        }
        iterations = parse_positive_int(value, "--iterations")
        continue rest
      }
      ["--warmup", .. rest] => {
        guard rest is [value, .. rest] else {
          abort("expected integer after --warmup")
        }
        warmup = parse_non_negative_int(value, "--warmup")
        continue rest
      }
      ["--workers", .. rest] => {
        guard rest is [value, .. rest] else {
          abort("expected integer after --workers")
        }
        workers = parse_positive_int(value, "--workers")
        continue rest
      }
      [opt, ..] if opt.has_prefix("-") => abort("unknown option \{opt}")
      [arg, ..] => abort("unexpected positional argument \{arg}")
    }
  }
  guard is_supported_scenario(scenario) else {
    abort("unsupported scenario \{scenario}")
  }
  { scenario, iterations, warmup, workers }
}

///|
fn parse_positive_int(raw : String, flag : String) -> Int {
  let parsed = try @string.parse_int(raw) catch {
    _ => abort("\{flag} must be a positive integer")
  } noraise {
    parsed => parsed
  }
  guard parsed > 0 else { abort("\{flag} must be a positive integer") }
  parsed
}

///|
fn parse_non_negative_int(raw : String, flag : String) -> Int {
  let parsed = try @string.parse_int(raw) catch {
    _ => abort("\{flag} must be a non-negative integer")
  } noraise {
    parsed => parsed
  }
  guard parsed >= 0 else { abort("\{flag} must be a non-negative integer") }
  parsed
}

///|
fn is_supported_scenario(name : String) -> Bool {
  match name {
    "all"
    | "client-query-one"
    | "client-prepared-hit"
    | "pgpool-with-client"
    | "pgpool-prepared-cache-hit"
    | "pgpool-contention" => true
    _ => false
  }
}

///|
fn env_or(name : String, fallback : String) -> String {
  @env.get_env_var(name).unwrap_or(fallback)
}

///|
fn env_port() -> Int {
  match @env.get_env_var("POSTGRES_PORT") {
    None => 5432
    Some(port) =>
      try @string.parse_int(port) catch {
        _ => abort("POSTGRES_PORT must be an integer")
      } noraise {
        parsed => parsed
      }
  }
}

///|
fn read_postgres_env() -> PostgresEnv {
  {
    host: env_or("POSTGRES_HOST", "127.0.0.1"),
    port: env_port(),
    user: env_or("POSTGRES_USER", "moon_scram"),
    password: env_or("POSTGRES_PASSWORD", "moonpass"),
    database: env_or("POSTGRES_DB", "moondb"),
  }
}

///|
fn client_config(application_name : String) -> @client.Config {
  let config = read_postgres_env()
  @client.Config::new(
    config.host,
    user=config.user,
    database=config.database,
    password=config.password,
    port=config.port,
    ssl_mode=@client.SslMode::Disable,
    application_name~,
  )
}

///|
fn pool_config(
  group : @async.TaskGroup[Unit],
  application_name : String,
  max_size : Int,
) -> @pgpool.Pool raise {
  let config = read_postgres_env()
  @pgpool.Config::new(
    config.host,
    user=config.user,
    dbname=config.database,
    password=config.password,
    port=config.port,
    ssl_mode=@client.SslMode::Disable,
    application_name~,
    pool=@pgpool.PoolConfig::new(max_size),
  ).create_pool(group)
}
