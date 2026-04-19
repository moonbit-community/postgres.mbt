///|
async fn run_serial_benchmark(
  scenario : String,
  options : CliOptions,
  op : async (Int) -> Int,
) -> PerfResult {
  for i in 0..<options.warmup {
    ignore(op(i))
  }
  let samples : Array[Double] = []
  let total_start = @bench.monotonic_clock_start()
  let mut checksum = 0
  for i in 0..<options.iterations {
    let op_start = @bench.monotonic_clock_start()
    checksum += op(i)
    samples.push(@bench.monotonic_clock_end(op_start))
  }
  let total_us = @bench.monotonic_clock_end(total_start)
  if checksum == -1 {
    abort("unexpected checksum")
  }
  build_result(scenario, options, 1, options.iterations, total_us, samples)
}

///|
async fn run_client_query_one(options : CliOptions) -> PerfResult {
  let result = @ref.new(None)
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      client_config("moonbit-postgres-perf-client-query-one"),
    )
    group.spawn_bg(() => connection.run())
    result.val = Some(
      run_serial_benchmark("client-query-one", options, _ => {
        let row = client.query_one("select 1::int4 as value")
        let value : Int = row.get_name("value")
        value
      }),
    )
    client.close()
  })
  result.val.unwrap()
}

///|
async fn run_client_prepared_hit(options : CliOptions) -> PerfResult {
  let result = @ref.new(None)
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      client_config("moonbit-postgres-perf-client-prepared"),
    )
    group.spawn_bg(() => connection.run())
    let statement = client.prepare("select $1::int4 as value")
    result.val = Some(
      run_serial_benchmark("client-prepared-hit", options, i => {
        let value = i + 1
        let params : Array[&@client.ToSql] = [value as &@client.ToSql]
        let row = client.query_statement(statement, params~).collect()[0]
        let decoded : Int = row.get_name("value")
        decoded
      }),
    )
    statement.close()
    client.close()
  })
  result.val.unwrap()
}

///|
async fn run_pgpool_with_client(options : CliOptions) -> PerfResult {
  let result = @ref.new(None)
  @async.with_task_group(group => {
    let pool = pool_config(group, "moonbit-postgres-perf-pool-with-client", 1)
    result.val = Some(
      run_serial_benchmark("pgpool-with-client", options, _ => {
        pool.with_client(client => {
          let row = client.query_one("select 1::int4 as value")
          let value : Int = row.get_name("value")
          value
        })
      }),
    )
    pool.close()
  })
  result.val.unwrap()
}

///|
async fn prime_pgpool_cached_statement(pool : @pgpool.Pool) -> Unit {
  let value : Int = pool.with_client(client => {
    client.with_prepared_cached("select $1::int4 as value", prepared => {
      let row = prepared.query_one(params=[1 as &@client.ToSql])
      let decoded : Int = row.get_name("value")
      decoded
    })
  })
  ignore(value)
}

///|
async fn run_pgpool_prepared_cache_hit(options : CliOptions) -> PerfResult {
  let result = @ref.new(None)
  @async.with_task_group(group => {
    let pool = pool_config(group, "moonbit-postgres-perf-pool-cache-hit", 1)
    prime_pgpool_cached_statement(pool)
    result.val = Some(
      run_serial_benchmark("pgpool-prepared-cache-hit", options, i => {
        let value = i + 1
        pool.with_client(client => {
          client.with_prepared_cached("select $1::int4 as value", prepared => {
            let row = prepared.query_one(params=[value as &@client.ToSql])
            let decoded : Int = row.get_name("value")
            decoded
          })
        })
      }),
    )
    pool.close()
  })
  result.val.unwrap()
}

///|
async fn run_contention_worker(
  pool : @pgpool.Pool,
  iterations : Int,
) -> (Array[Double], Int) {
  let samples : Array[Double] = []
  let mut checksum = 0
  for _ in 0..<iterations {
    let op_start = @bench.monotonic_clock_start()
    let value : Int = pool.with_client(client => {
      client.query_one("select 1::int4 as value").get_name("value")
    })
    samples.push(@bench.monotonic_clock_end(op_start))
    checksum += value
  }
  (samples, checksum)
}

///|
async fn warmup_contention_pool(
  pool : @pgpool.Pool,
  options : CliOptions,
) -> Unit {
  let warmup_ops = options.warmup * options.workers
  for _ in 0..<warmup_ops {
    let value : Int = pool.with_client(client => {
      let row = client.query_one("select 1::int4 as value")
      let decoded : Int = row.get_name("value")
      decoded
    })
    ignore(value)
  }
}

///|
async fn run_pgpool_contention(options : CliOptions) -> PerfResult {
  let result = @ref.new(None)
  @async.with_task_group(group => {
    let pool = pool_config(group, "moonbit-postgres-perf-pool-contention", 2)
    warmup_contention_pool(pool, options)
    let tasks : Array[@async.Task[(Array[Double], Int)]] = []
    let total_start = @bench.monotonic_clock_start()
    for _ in 0..<options.workers {
      tasks.push(
        group.spawn(no_wait=true, () => {
          run_contention_worker(pool, options.iterations)
        }),
      )
    }
    let samples : Array[Double] = []
    let mut checksum = 0
    for task in tasks {
      let (worker_samples, worker_checksum) = task.wait()
      checksum += worker_checksum
      for sample in worker_samples {
        samples.push(sample)
      }
    }
    let total_us = @bench.monotonic_clock_end(total_start)
    pool.close()
    if checksum == -1 {
      abort("unexpected checksum")
    }
    result.val = Some(
      build_result(
        "pgpool-contention",
        options,
        options.workers,
        options.iterations * options.workers,
        total_us,
        samples,
      ),
    )
  })
  result.val.unwrap()
}

///|
pub async fn run_selected(options : CliOptions) -> Array[PerfResult] {
  let results : Array[PerfResult] = []
  match options.scenario {
    "all" => {
      results.push(run_client_query_one(options))
      results.push(run_client_prepared_hit(options))
      results.push(run_pgpool_with_client(options))
      results.push(run_pgpool_prepared_cache_hit(options))
      results.push(run_pgpool_contention(options))
    }
    "client-query-one" => results.push(run_client_query_one(options))
    "client-prepared-hit" => results.push(run_client_prepared_hit(options))
    "pgpool-with-client" => results.push(run_pgpool_with_client(options))
    "pgpool-prepared-cache-hit" =>
      results.push(run_pgpool_prepared_cache_hit(options))
    "pgpool-contention" => results.push(run_pgpool_contention(options))
    _ => abort("unsupported scenario \{options.scenario}")
  }
  results
}
