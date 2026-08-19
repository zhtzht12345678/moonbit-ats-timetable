///|
/// Passenger-demand classification used by the dwell and platform models.
pub(all) enum DemandPeriod {
  OffPeak
  Peak
  Special
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A demand observation for one train call at one station. Values are counts
/// for the service interval represented by the observation.
pub(all) struct PassengerLoad {
  train_id : String
  station_id : String
  boardings : Int
  alightings : Int
  onboard_before : Int
  capacity : Int
  period : DemandPeriod
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Dwell-time estimate with the intermediate terms retained for audit.
pub(all) struct DwellEstimate {
  train_id : String
  station_id : String
  scheduled_dwell_min : Int
  boarding_min : Int
  alighting_min : Int
  door_clearance_min : Int
  estimated_dwell_min : Int
  capped : Bool
  explanation : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Station-level operating load summary.
pub(all) struct StationPerformance {
  station_id : String
  station_name : String
  service_count : Int
  observed_service_count : Int
  peak_boardings : Int
  peak_alightings : Int
  peak_platform_load : Int
  average_dwell_min : Int
  delayed_service_count : Int
  overloaded_service_count : Int
  utilization_percent : Int
  status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Line-level performance report suitable for an OCC dashboard export.
pub(all) struct OperationsReport {
  schedule_id : String
  at_min : Int
  station_count : Int
  train_count : Int
  passenger_observation_count : Int
  total_boardings : Int
  total_alightings : Int
  average_delay_min : Int
  p95_delay_min : Int
  on_time_percent : Int
  overloaded_service_count : Int
  station_performance : Array[StationPerformance]
  notes : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Construct a passenger observation while clamping impossible negative
/// counts at the data boundary.
pub fn passenger_load(
  train_id~ : String,
  station_id~ : String,
  boardings~ : Int,
  alightings~ : Int,
  onboard_before~ : Int,
  capacity~ : Int,
  period? : DemandPeriod = OffPeak,
) -> PassengerLoad {
  {
    train_id,
    station_id,
    boardings: non_negative(boardings),
    alightings: non_negative(alightings),
    onboard_before: non_negative(onboard_before),
    capacity: max_int(1, capacity),
    period,
  }
}

///|
/// Estimate dwell from passenger exchange rates. `boarding_rate` and
/// `alighting_rate` are passengers per minute; the returned value is always
/// within the supplied operational dwell limits.
pub fn estimate_dwell(
  scheduled_dwell_min~ : Int,
  boardings~ : Int,
  alightings~ : Int,
  boarding_rate~ : Int,
  alighting_rate~ : Int,
  door_clearance_min~ : Int,
  minimum_dwell_min~ : Int,
  maximum_dwell_min~ : Int,
) -> DwellEstimate {
  let safe_boarding_rate = max_int(1, boarding_rate)
  let safe_alighting_rate = max_int(1, alighting_rate)
  let boarding_min = ceil_div(non_negative(boardings), safe_boarding_rate)
  let alighting_min = ceil_div(non_negative(alightings), safe_alighting_rate)
  let clearance = max_int(0, door_clearance_min)
  let raw = max_int(
    max_int(0, scheduled_dwell_min),
    boarding_min + alighting_min + clearance,
  )
  let low = max_int(0, minimum_dwell_min)
  let high = max_int(low, maximum_dwell_min)
  let estimated = clamp_int(raw, low, high)
  let capped = raw != estimated
  {
    train_id: "",
    station_id: "",
    scheduled_dwell_min,
    boarding_min,
    alighting_min,
    door_clearance_min: clearance,
    estimated_dwell_min: estimated,
    capped,
    explanation: dwell_explanation(raw, estimated, capped),
  }
}

///|
/// Estimate a concrete train call, preserving the train and station identity
/// in the result for downstream event and audit records.
pub fn estimate_call_dwell(
  train : Train,
  stop : StopTime,
  load : PassengerLoad,
  boarding_rate? : Int = 18,
  alighting_rate? : Int = 24,
  door_clearance_min? : Int = 1,
  maximum_dwell_min? : Int = 8,
) -> DwellEstimate {
  let base = estimate_dwell(
    scheduled_dwell_min=stop.departure_min - stop.arrival_min,
    boardings=load.boardings,
    alightings=load.alightings,
    boarding_rate~,
    alighting_rate~,
    door_clearance_min~,
    minimum_dwell_min=stop.minimum_dwell_min,
    maximum_dwell_min~,
  )
  {
    train_id: train.id,
    station_id: stop.station_id,
    scheduled_dwell_min: base.scheduled_dwell_min,
    boarding_min: base.boarding_min,
    alighting_min: base.alighting_min,
    door_clearance_min: base.door_clearance_min,
    estimated_dwell_min: base.estimated_dwell_min,
    capped: base.capped,
    explanation: base.explanation,
  }
}

///|
/// Estimate the platform capacity pressure of one observation in percent.
pub fn passenger_load_percent(load : PassengerLoad) -> Int {
  let after_alighting = max_int(0, load.onboard_before - load.alightings)
  let onboard_after = after_alighting + load.boardings
  percentage(onboard_after, load.capacity)
}

///|
/// Return a stable station performance report. The function intentionally
/// accepts an array rather than a database adapter so an OCC integration can
/// feed the same logic from a file, replay stream, or live connector.
pub fn station_performance(
  schedule : Schedule,
  loads : Array[PassengerLoad],
  runtimes : Array[TrainRuntime],
  at_min : Int,
) -> Array[StationPerformance] {
  let reports = []
  for station in schedule.stations {
    let station_loads = loads.filter(fn(load) { load.station_id == station.id })
    let services = schedule.trains.filter(fn(train) {
      train.stops.any(fn(stop) { stop.station_id == station.id })
    })
    let observed = services.filter(fn(train) {
      runtime_at(runtimes, train.id) is Some(runtime) &&
      runtime.observed_min <= at_min
    })
    let boardings = sum_load_field(station_loads, fn(load) { load.boardings })
    let alightings = sum_load_field(station_loads, fn(load) { load.alightings })
    let platform_load = max_load_percent(station_loads)
    let delayed = observed.count_if(fn(train) {
      runtime_at(runtimes, train.id) is Some(runtime) && runtime.delay_min > 0
    })
    let overloaded = station_loads.count_if(fn(load) {
      passenger_load_percent(load) > 100
    })
    let dwell = average_dwell_for_station(schedule, station.id, station_loads)
    let utilization = station_utilization(
      station,
      services.length(),
      platform_load,
    )
    let status = station_status(platform_load, delayed, overloaded)
    reports.push({
      station_id: station.id,
      station_name: station.name,
      service_count: services.length(),
      observed_service_count: observed.length(),
      peak_boardings: boardings,
      peak_alightings: alightings,
      peak_platform_load: platform_load,
      average_dwell_min: dwell,
      delayed_service_count: delayed,
      overloaded_service_count: overloaded,
      utilization_percent: utilization,
      status,
    })
  }
  reports
}

///|
/// Build the complete operations report, including deterministic delay
/// statistics and explicit notes when input data is sparse.
pub fn operations_report(
  schedule : Schedule,
  loads : Array[PassengerLoad],
  runtimes : Array[TrainRuntime],
  at_min : Int,
) -> OperationsReport {
  let station_reports = station_performance(schedule, loads, runtimes, at_min)
  let delays = runtimes.map(fn(runtime) { max_int(0, runtime.delay_min) })
  let total_boardings = sum_load_field(loads, fn(load) { load.boardings })
  let total_alightings = sum_load_field(loads, fn(load) { load.alightings })
  let average_delay = average_int(delays)
  let p95 = percentile_nearest(delays, 95)
  let on_time = delays.count_if(fn(delay) { delay <= 2 })
  let notes = []
  if loads.length() == 0 {
    notes.push("no passenger observations were supplied")
  }
  if runtimes.length() == 0 {
    notes.push("no realtime observations were supplied")
  }
  if schedule.trains.length() == 0 {
    notes.push("schedule has no train services")
  }
  {
    schedule_id: schedule.id,
    at_min,
    station_count: schedule.stations.length(),
    train_count: schedule.trains.length(),
    passenger_observation_count: loads.length(),
    total_boardings,
    total_alightings,
    average_delay_min: average_delay,
    p95_delay_min: p95,
    on_time_percent: percentage(on_time, max_int(1, delays.length())),
    overloaded_service_count: station_reports.fold(init=0, fn(total, report) {
      total + report.overloaded_service_count
    }),
    station_performance: station_reports,
    notes,
  }
}

///|
/// JSON export kept as a named API so an adapter does not depend on the
/// representation details of `OperationsReport`.
pub fn operations_report_json(report : OperationsReport) -> String {
  report.to_json().stringify()
}

///|
/// Human-readable report used by the CLI and incident review notebooks.
pub fn operations_report_markdown(report : OperationsReport) -> String {
  let builder = StringBuilder()
  builder <+ "# Operations report\n\n"
  builder <+ "| Metric | Value |\n|---|---:|\n"
  write_operation_metric(builder, "Schedule", report.schedule_id)
  write_operation_metric(builder, "Stations", report.station_count.to_string())
  write_operation_metric(builder, "Trains", report.train_count.to_string())
  write_operation_metric(
    builder,
    "Passenger observations",
    report.passenger_observation_count.to_string(),
  )
  write_operation_metric(
    builder,
    "Boardings",
    report.total_boardings.to_string(),
  )
  write_operation_metric(
    builder,
    "Alightings",
    report.total_alightings.to_string(),
  )
  write_operation_metric(
    builder,
    "Average delay (min)",
    report.average_delay_min.to_string(),
  )
  write_operation_metric(
    builder,
    "P95 delay (min)",
    report.p95_delay_min.to_string(),
  )
  write_operation_metric(
    builder,
    "On-time (%)",
    report.on_time_percent.to_string(),
  )
  write_operation_metric(
    builder,
    "Overloaded calls",
    report.overloaded_service_count.to_string(),
  )
  builder <+ "\n## Stations\n\n"
  builder <+
    "| Station | Services | Peak load (%) | Dwell (min) | Status |\n|---|---:|---:|---:|---|\n"
  for report in report.station_performance {
    builder <+
      "| \{report.station_name} | \{report.service_count} | \{report.peak_platform_load} | \{report.average_dwell_min} | \{report.status} |\n"
  }
  if report.notes.length() > 0 {
    builder <+ "\n## Notes\n\n"
    for note in report.notes {
      builder <+ "- \{note}\n"
    }
  }
  builder.to_string()
}

///|
/// Calculate an integer percentage without overflowing the business-facing
/// result. A zero denominator represents an empty capacity and is reported as
/// 100% pressure rather than an arithmetic failure.
pub fn percentage(value : Int, denominator : Int) -> Int {
  if denominator <= 0 {
    return if value > 0 { 100 } else { 0 }
  }
  let non_negative_value = max_int(0, value)
  non_negative_value * 100 / denominator
}

///|
pub fn load_status(load_percent : Int) -> String {
  if load_percent >= 120 {
    "critical"
  } else if load_percent > 100 {
    "overloaded"
  } else if load_percent >= 85 {
    "busy"
  } else {
    "normal"
  }
}

///|
pub fn delay_percentile(delays : Array[Int], percentile_value : Int) -> Int {
  percentile_nearest(delays, percentile_value)
}

///|
fn non_negative(value : Int) -> Int {
  max_int(0, value)
}

///|
fn ceil_div(value : Int, divisor : Int) -> Int {
  if value <= 0 {
    0
  } else {
    (value + divisor - 1) / divisor
  }
}

///|
fn dwell_explanation(raw : Int, estimated : Int, capped : Bool) -> String {
  if capped {
    "raw dwell \{raw} min was bounded to \{estimated} min"
  } else {
    "passenger exchange requires \{estimated} min"
  }
}

///|
fn runtime_at(
  runtimes : Array[TrainRuntime],
  train_id : String,
) -> TrainRuntime? {
  for runtime in runtimes {
    if runtime.train_id == train_id {
      return Some(runtime)
    }
  }
  None
}

///|
fn sum_load_field(
  loads : Array[PassengerLoad],
  getter : (PassengerLoad) -> Int,
) -> Int {
  loads.fold(init=0, fn(total, load) { total + getter(load) })
}

///|
fn max_load_percent(loads : Array[PassengerLoad]) -> Int {
  let mut best = 0
  for load in loads {
    let value = passenger_load_percent(load)
    if value > best {
      best = value
    }
  }
  best
}

///|
fn average_dwell_for_station(
  schedule : Schedule,
  station_id : String,
  loads : Array[PassengerLoad],
) -> Int {
  let dwells = []
  for train in schedule.trains {
    for stop in train.stops {
      if stop.station_id == station_id {
        let load = find_load(loads, train.id, station_id)
        let dwell = match load {
          Some(item) =>
            estimate_call_dwell(train, stop, item).estimated_dwell_min
          None => stop.departure_min - stop.arrival_min
        }
        dwells.push(max_int(0, dwell))
      }
    }
  }
  average_int(dwells)
}

///|
fn station_utilization(
  station : Station,
  service_count : Int,
  peak_platform_load : Int,
) -> Int {
  let platform_pressure = percentage(
    service_count,
    max_int(1, station.platform_count * 4),
  )
  max_int(platform_pressure, peak_platform_load)
}

///|
fn station_status(
  peak_platform_load : Int,
  delayed_service_count : Int,
  overloaded_service_count : Int,
) -> String {
  if overloaded_service_count > 0 || peak_platform_load >= 120 {
    "critical"
  } else if peak_platform_load > 100 || delayed_service_count >= 2 {
    "watch"
  } else {
    "normal"
  }
}

///|
fn average_int(values : Array[Int]) -> Int {
  if values.length() == 0 {
    0
  } else {
    values.fold(init=0, fn(total, value) { total + value }) / values.length()
  }
}

///|
fn percentile_nearest(values : Array[Int], percentile_value : Int) -> Int {
  if values.length() == 0 {
    return 0
  }
  let sorted = values.copy()
  sorted.sort()
  let bounded = clamp_int(percentile_value, 0, 100)
  let rank = ((sorted.length() - 1) * bounded + 50) / 100
  sorted[clamp_int(rank, 0, sorted.length() - 1)]
}

///|
fn write_operation_metric(
  builder : StringBuilder,
  name : String,
  value : String,
) -> Unit {
  builder <+ "| \{name} | \{value} |\n"
}

///|
fn find_load(
  loads : Array[PassengerLoad],
  train_id : String,
  station_id : String,
) -> PassengerLoad? {
  for load in loads {
    if load.train_id == train_id && load.station_id == station_id {
      return Some(load)
    }
  }
  None
}
