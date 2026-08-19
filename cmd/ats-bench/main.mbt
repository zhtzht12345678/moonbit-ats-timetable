///|
/// Run the deterministic workload definitions and print counters plus the
/// host clock measurement. The workload itself stays in the library so a
/// service can run the same path without depending on this executable.
fn main {
  let args = @env.args()
  if has_flag(args, "--help") || has_flag(args, "-h") {
    print_usage()
    return
  }
  let definitions = selected_definitions(args)
  if definitions.length() == 0 {
    println("unknown benchmark case")
    print_usage()
    return
  }
  if has_flag(args, "--json") {
    for definition in definitions {
      println(run_one_json(definition))
    }
  } else {
    println(
      "case|stations|trains|iterations|elapsed_ms|operations_per_ms|conflicts|interval_queries|resource_overlaps|passenger_observations|checksum",
    )
    for definition in definitions {
      println(run_one_row(definition))
    }
  }
}

///|
fn selected_definitions(
  args : Array[String],
) -> Array[@ats.BenchmarkDefinition] {
  match option_value(args, "--case") {
    None => @ats.standard_benchmark_definitions()
    Some(wanted) =>
      @ats.standard_benchmark_definitions().filter(fn(item) {
        item.name == wanted
      })
  }
}

///|
fn run_one(definition : @ats.BenchmarkDefinition) -> @ats.BenchmarkResult {
  let start = @env.now()
  let workload = @ats.run_benchmark_workload(definition)
  let finish = @env.now()
  @ats.benchmark_result(definition, workload, UInt64::sub(finish, start))
}

///|
fn run_one_row(definition : @ats.BenchmarkDefinition) -> String {
  let result = run_one(definition)
  let workload = result.workload
  "\{result.definition.name}|\{result.definition.station_count}|\{result.definition.train_count}|\{result.definition.iterations}|\{result.elapsed_ms}|\{result.operations_per_ms}|\{workload.conflict_observations}|\{workload.interval_queries}|\{workload.resource_overlap_observations}|\{workload.passenger_observations}|\{workload.checksum}"
}

///|
fn run_one_json(definition : @ats.BenchmarkDefinition) -> String {
  @ats.benchmark_result_json(run_one(definition))
}

///|
fn has_flag(args : Array[String], wanted : String) -> Bool {
  args.contains(wanted)
}

///|
fn option_value(args : Array[String], wanted : String) -> String? {
  for i in 0..<args.length() {
    if args[i] == wanted && i + 1 < args.length() {
      return Some(args[i + 1])
    }
  }
  None
}

///|
fn print_usage() -> Unit {
  println(
    "moonbit-ats-timetable benchmark\n\n  moon run cmd/ats-bench -- [--case small|medium|large] [--json]\n\nThe counters are deterministic; elapsed_ms is measured on the native host.",
  )
}
