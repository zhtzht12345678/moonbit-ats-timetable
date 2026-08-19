///|
/// A reproducible workload definition. The generator contains no random
/// source; the same dimensions always produce the same schedule.
pub(all) struct BenchmarkDefinition {
  name : String
  station_count : Int
  train_count : Int
  iterations : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Aggregated work counters returned by the benchmark workload. Wall-clock
/// measurement belongs to the native CLI so this value remains portable.
pub(all) struct BenchmarkWorkload {
  schedule_id : String
  station_count : Int
  train_count : Int
  iterations : Int
  conflict_observations : Int
  interval_queries : Int
  resource_overlap_observations : Int
  passenger_observations : Int
  checksum : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
/// One measured benchmark result. `elapsed_ms` is supplied by the caller using
/// the platform clock; the workload and checksum are generated here.
pub(all) struct BenchmarkResult {
  definition : BenchmarkDefinition
  workload : BenchmarkWorkload
  elapsed_ms : UInt64
  operations_per_ms : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Standard dimensions used by the README benchmark. They are large enough
/// to exercise the index and resource layers while remaining laptop-friendly.
pub fn standard_benchmark_definitions() -> Array[BenchmarkDefinition] {
  [
    { name: "small", station_count: 8, train_count: 24, iterations: 3 },
    { name: "medium", station_count: 16, train_count: 72, iterations: 2 },
    { name: "large", station_count: 24, train_count: 144, iterations: 1 },
  ]
}

///|
pub fn benchmark_definition(
  name~ : String,
  station_count~ : Int,
  train_count~ : Int,
  iterations? : Int = 1,
) -> BenchmarkDefinition {
  {
    name,
    station_count: max_int(2, station_count),
    train_count: max_int(1, train_count),
    iterations: max_int(1, iterations),
  }
}

///|
/// Generate a synthetic metro corridor with bidirectional services,
/// reservations and platform calls. It is a benchmark fixture, not an
/// operational timetable and is safe to redistribute with the repository.
pub fn synthetic_benchmark_schedule(
  station_count : Int,
  train_count : Int,
) -> Schedule {
  let station_total = max_int(2, station_count)
  let train_total = max_int(1, train_count)
  let stations = []
  for i in 0..<station_total {
    stations.push(
      station(
        id="S\{i}",
        name="Benchmark \{i}",
        distance_m=i * 1000,
        platform_count=2,
        is_interchange=i == station_total / 2,
      ),
    )
  }
  let segments = []
  for i in 0..<(station_total - 1) {
    segments.push(
      segment(
        id="B\{i}",
        from_station="S\{i}",
        to_station="S\{i + 1}",
        distance_m=1000,
        min_run_min=2,
        scheduled_run_min=3 + i % 2,
        max_run_min=5 + i % 2,
        headway_min=3 + i % 3,
        throat_resource=if i == station_total / 2 - 1 || i == station_total / 2 {
          Some("J\{i}")
        } else {
          None
        },
      ),
    )
  }
  let trains = []
  let reservations = []
  for train_index in 0..<train_total {
    let down = train_index % 2 == 1
    let offset = 60 + train_index % 12 * 2
    let stops = benchmark_stops(station_total, down, offset)
    trains.push(
      train(
        id="B\{train_index}",
        service_name="Benchmark \{train_index}",
        direction=if down { Down } else { Up },
        stops~,
        priority=if train_index % 5 == 0 { 8 } else { 5 },
        length_m=120,
        max_speed_kmh=80,
      ),
    )
    let junction = station_total / 2 - 1
    reservations.push(
      route_reservation(
        id="BR\{train_index}",
        train_id="B\{train_index}",
        resource_id="J\{junction}",
        entry_min=offset + 3 * max_int(0, junction),
        exit_min=offset + 3 * max_int(0, junction + 1),
        release_margin_min=2,
        route_name="benchmark-junction",
      ),
    )
  }
  schedule(
    id="bench-\{station_total}x\{train_total}",
    service_date="2026-08-19",
    line_name="Synthetic benchmark corridor",
    stations~,
    segments~,
    trains~,
    reservations~,
    notes="Deterministic benchmark fixture; no operational data.",
  )
}

///|
/// Run the complete application workload repeatedly and return only counters
/// and a checksum. Keeping the result compact makes it suitable for CI logs.
pub fn run_benchmark_workload(
  definition : BenchmarkDefinition,
) -> BenchmarkWorkload {
  let schedule = synthetic_benchmark_schedule(
    definition.station_count,
    definition.train_count,
  )
  let loads = synthetic_passenger_loads(schedule)
  let mut conflict_observations = 0
  let mut interval_queries = 0
  let mut resource_overlap_observations = 0
  let mut checksum = 17
  for _ in 0..<definition.iterations {
    let conflicts = detect_conflicts(schedule)
    conflict_observations += conflicts.length()
    checksum = checksum * 31 + conflicts.length()
    let index = build_interval_index(schedule, bucket_size_min=5)
    let queries = query_all_resources(index, 0, 240)
    interval_queries += queries.length()
    for query in queries {
      checksum = checksum + query.matched_count * 7
    }
    let catalogue = build_resource_catalogue_from_index(schedule, index, 0, 240)
    resource_overlap_observations += catalogue.conflicts.length()
    checksum = checksum * 13 + catalogue.loads.length()
    let report = operations_report(schedule, loads, [], 120)
    checksum = checksum + report.total_boardings + report.total_alightings
  }
  {
    schedule_id: schedule.id,
    station_count: definition.station_count,
    train_count: definition.train_count,
    iterations: definition.iterations,
    conflict_observations,
    interval_queries,
    resource_overlap_observations,
    passenger_observations: loads.length(),
    checksum,
  }
}

///|
pub fn benchmark_result(
  definition : BenchmarkDefinition,
  workload : BenchmarkWorkload,
  elapsed_ms : UInt64,
) -> BenchmarkResult {
  let operations = workload.conflict_observations +
    workload.interval_queries +
    workload.resource_overlap_observations +
    workload.passenger_observations
  let per_ms = if elapsed_ms == 0 {
    0
  } else {
    UInt64::to_int(
      UInt64::div(
        UInt64::extend_uint(operations.reinterpret_as_uint()),
        elapsed_ms,
      ),
    )
  }
  { definition, workload, elapsed_ms, operations_per_ms: per_ms }
}

///|
pub fn benchmark_result_json(result : BenchmarkResult) -> String {
  result.to_json().stringify()
}

///|
pub fn benchmark_workload_markdown(workload : BenchmarkWorkload) -> String {
  let builder = StringBuilder()
  builder <+ "| Field | Value |\n|---|---:|\n"
  builder <+ "| Schedule | \{workload.schedule_id} |\n"
  builder <+ "| Stations | \{workload.station_count} |\n"
  builder <+ "| Trains | \{workload.train_count} |\n"
  builder <+ "| Iterations | \{workload.iterations} |\n"
  builder <+ "| Conflict observations | \{workload.conflict_observations} |\n"
  builder <+ "| Interval queries | \{workload.interval_queries} |\n"
  builder <+
    "| Resource overlaps | \{workload.resource_overlap_observations} |\n"
  builder <+ "| Passenger observations | \{workload.passenger_observations} |\n"
  builder <+ "| Checksum | \{workload.checksum} |\n"
  builder.to_string()
}

///|
fn benchmark_stops(
  station_count : Int,
  down : Bool,
  offset : Int,
) -> Array[StopTime] {
  let stops = []
  for i in 0..<station_count {
    let station_index = if down { station_count - 1 - i } else { i }
    let arrival_adjustment = if i == 0 { 0 } else { i % 2 }
    let arrival = offset + i * 3 + arrival_adjustment
    let dwell = if i == 0 || i == station_count - 1 { 0 } else { 1 }
    stops.push(
      stop_time(
        station_id="S\{station_index}",
        arrival_min=arrival,
        departure_min=arrival + dwell,
        platform=1 + station_index % 2,
        stop_kind=if i == 0 {
          "origin"
        } else if i == station_count - 1 {
          "terminal"
        } else {
          "normal"
        },
      ),
    )
  }
  stops
}

///|
fn synthetic_passenger_loads(schedule : Schedule) -> Array[PassengerLoad] {
  let output = []
  for train_index, train in schedule.trains {
    for stop_index, stop in train.stops {
      if stop_index > 0 && stop_index + 1 < train.stops.length() {
        output.push(
          passenger_load(
            train_id=train.id,
            station_id=stop.station_id,
            boardings=8 + (train_index + stop_index) % 17,
            alightings=4 + (train_index * 2 + stop_index) % 11,
            onboard_before=20 + (train_index * 3 + stop_index) % 32,
            capacity=180,
            period=if stop_index % 3 == 0 { Peak } else { OffPeak },
          ),
        )
      }
    }
  }
  output
}
