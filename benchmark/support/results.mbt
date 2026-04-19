///|
pub struct PerfResult {
  scenario : String
  mode : String
  iterations : Int
  warmup : Int
  workers : Int
  operations : Int
  total_us : Double
  mean_us : Double
  p50_us : Double
  p95_us : Double
  max_us : Double
  ops_per_sec : Double
}

///|
pub impl ToJson for PerfResult with to_json(self) {
  Json::object({
    "scenario": self.scenario.to_json(),
    "mode": self.mode.to_json(),
    "iterations": self.iterations.to_json(),
    "warmup": self.warmup.to_json(),
    "workers": self.workers.to_json(),
    "operations": self.operations.to_json(),
    "total_us": self.total_us.to_json(),
    "mean_us": self.mean_us.to_json(),
    "p50_us": self.p50_us.to_json(),
    "p95_us": self.p95_us.to_json(),
    "max_us": self.max_us.to_json(),
    "ops_per_sec": self.ops_per_sec.to_json(),
  })
}

///|
fn benchmark_mode() -> String {
  "native-release-scram-disable"
}

///|
pub fn build_result(
  scenario : String,
  options : CliOptions,
  workers : Int,
  operations : Int,
  total_us : Double,
  samples : Array[Double],
) -> PerfResult {
  let sorted = clone_samples(samples)
  sorted.sort()
  let mean_us = mean(samples)
  let p50_us = percentile(sorted, 50)
  let p95_us = percentile(sorted, 95)
  let max_us = if sorted.is_empty() { 0.0 } else { sorted[sorted.length() - 1] }
  let ops_per_sec = if total_us <= 0.0 {
    0.0
  } else {
    operations.to_double() * 1_000_000.0 / total_us
  }
  {
    scenario,
    mode: benchmark_mode(),
    iterations: options.iterations,
    warmup: options.warmup,
    workers,
    operations,
    total_us,
    mean_us,
    p50_us,
    p95_us,
    max_us,
    ops_per_sec,
  }
}

///|
fn clone_samples(samples : Array[Double]) -> Array[Double] {
  let out : Array[Double] = []
  for sample in samples {
    out.push(sample)
  }
  out
}

///|
fn mean(samples : Array[Double]) -> Double {
  if samples.is_empty() {
    return 0.0
  }
  let mut total = 0.0
  for sample in samples {
    total += sample
  }
  total / samples.length().to_double()
}

///|
fn percentile(sorted : Array[Double], pct : Int) -> Double {
  if sorted.is_empty() {
    return 0.0
  }
  let last = sorted.length() - 1
  let index = last * pct / 100
  sorted[index]
}
