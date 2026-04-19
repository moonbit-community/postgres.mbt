///|
let help_message : String =
  #|Usage: moon run benchmark/pg_perf -- [options]
  #|
  #|Options:
  #|  --scenario NAME    all | client-query-one | client-prepared-hit | pgpool-with-client | pgpool-prepared-cache-hit | pgpool-contention
  #|  --iterations N     measured iterations per scenario
  #|  --warmup N         warmup iterations per scenario
  #|  --workers N        concurrent workers for pgpool-contention
  #|  -h, --help         show this message

///|
fn has_help(args : ArrayView[String]) -> Bool {
  for arg in args {
    if arg == "-h" || arg == "--help" {
      return true
    }
  }
  false
}

///|
async fn main {
  let args = @env.args()[1:]
  if has_help(args) {
    println(help_message)
    return
  }
  let options = @perf.parse_cli(args)
  let results = @perf.run_selected(options)
  println(results.to_json().stringify())
}
