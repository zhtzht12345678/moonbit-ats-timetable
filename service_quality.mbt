///|
/// Service-quality bands provide a stable vocabulary for an OCC dashboard.
/// They are intentionally derived from observable evidence rather than from a
/// single alarm, so the same report can be used in replay and live modes.
pub(all) enum QualityBand {
  Excellent
  Good
  Watch
  Poor
  Unknown
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Thresholds used by the quality scorer. All time values are minutes and
/// percentages are integer percentages of the observed service.
pub(all) struct QualityThresholds {
  good_on_time_percent : Int
  excellent_on_time_percent : Int
  maximum_delay_min : Int
  maximum_headway_deviation_min : Int
  maximum_load_percent : Int
  stale_after_min : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Per-train quality evidence retained for an audit or a dashboard drill-down.
pub(all) struct TrainQuality {
  train_id : String
  observed : Bool
  delay_min : Int
  on_time : Bool
  maximum_load_percent : Int
  headway_deviation_min : Int
  band : QualityBand
  reason : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Line-level quality dashboard assembled from schedule, telemetry, and
/// passenger observations.
pub(all) struct QualityDashboard {
  schedule_id : String
  at_min : Int
  thresholds : QualityThresholds
  train_count : Int
  observed_train_count : Int
  on_time_train_count : Int
  on_time_percent : Int
  average_delay_min : Int
  p95_delay_min : Int
  maximum_headway_deviation_min : Int
  maximum_load_percent : Int
  band : QualityBand
  trains : Array[TrainQuality]
  notes : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn default_quality_thresholds() -> QualityThresholds {
  {
    good_on_time_percent: 95,
    excellent_on_time_percent: 98,
    maximum_delay_min: 2,
    maximum_headway_deviation_min: 3,
    maximum_load_percent: 110,
    stale_after_min: 5,
  }
}

///|
/// Construct thresholds while clamping values that would make a useful
/// report impossible to interpret.
pub fn quality_thresholds(
  good_on_time_percent~ : Int,
  excellent_on_time_percent~ : Int,
  maximum_delay_min~ : Int,
  maximum_headway_deviation_min~ : Int,
  maximum_load_percent~ : Int,
  stale_after_min~ : Int,
) -> QualityThresholds {
  let good = clamp_int(good_on_time_percent, 0, 100)
  let excellent = clamp_int(max_int(good, excellent_on_time_percent), 0, 100)
  {
    good_on_time_percent: good,
    excellent_on_time_percent: excellent,
    maximum_delay_min: max_int(0, maximum_delay_min),
    maximum_headway_deviation_min: max_int(0, maximum_headway_deviation_min),
    maximum_load_percent: max_int(0, maximum_load_percent),
    stale_after_min: max_int(0, stale_after_min),
  }
}

///|
/// Score a line at `at_min`. Missing telemetry is retained as Unknown instead
/// of being silently treated as on-time, which prevents optimistic reports
/// during a data outage.
pub fn assess_service_quality(
  schedule : Schedule,
  runtimes : Array[TrainRuntime],
  loads : Array[PassengerLoad],
  at_min : Int,
  thresholds? : QualityThresholds = default_quality_thresholds(),
) -> QualityDashboard {
  let quality_trains = []
  let delays = []
  let mut observed_count = 0
  let mut on_time_count = 0
  for train in schedule.trains {
    let runtime = find_quality_runtime(runtimes, train.id)
    let load_percent = train_max_load_percent(loads, train.id)
    let headway_deviation = train_headway_deviation(schedule, train)
    let quality = match runtime {
      None =>
        {
          train_id: train.id,
          observed: false,
          delay_min: 0,
          on_time: false,
          maximum_load_percent: load_percent,
          headway_deviation_min: headway_deviation,
          band: Unknown,
          reason: "no matching telemetry in the observation window",
        }
      Some(value) => {
        let stale = at_min - value.observed_min > thresholds.stale_after_min
        let delay = max_int(0, value.delay_min)
        let on_time = !stale && delay <= thresholds.maximum_delay_min
        observed_count += 1
        delays.push(delay)
        if on_time {
          on_time_count += 1
        }
        {
          train_id: train.id,
          observed: !stale,
          delay_min: delay,
          on_time,
          maximum_load_percent: load_percent,
          headway_deviation_min: headway_deviation,
          band: train_quality_band(
            stale, delay, load_percent, headway_deviation, thresholds,
          ),
          reason: train_quality_reason(
            stale, delay, load_percent, headway_deviation, thresholds,
          ),
        }
      }
    }
    quality_trains.push(quality)
  }
  let on_time_percent = percentage(on_time_count, observed_count)
  let maximum_headway_deviation = schedule_max_headway_deviation(schedule)
  let maximum_load = quality_trains.fold(init=0, fn(current, item) {
    max_int(current, item.maximum_load_percent)
  })
  let band = dashboard_band(
    schedule, observed_count, on_time_percent, delays, maximum_headway_deviation,
    maximum_load, thresholds,
  )
  let notes = quality_notes(
    schedule, observed_count, on_time_percent, maximum_headway_deviation, maximum_load,
    thresholds,
  )
  {
    schedule_id: schedule.id,
    at_min,
    thresholds,
    train_count: schedule.trains.length(),
    observed_train_count: observed_count,
    on_time_train_count: on_time_count,
    on_time_percent,
    average_delay_min: average_non_negative(delays),
    p95_delay_min: percentile_nearest(delays, 95),
    maximum_headway_deviation_min: maximum_headway_deviation,
    maximum_load_percent: maximum_load,
    band,
    trains: quality_trains,
    notes,
  }
}

///|
pub fn QualityDashboard::to_json_text(self : QualityDashboard) -> String {
  self.to_json().stringify()
}

///|
pub fn QualityDashboard::to_markdown(self : QualityDashboard) -> String {
  let builder = StringBuilder()
  builder.write_string("# Service quality\n\n")
  builder.write_string("| Metric | Value |\n|---|---:|\n")
  quality_metric(builder, "Band", quality_band_label(self.band))
  quality_metric(
    builder,
    "Observed trains",
    self.observed_train_count.to_string(),
  )
  quality_metric(
    builder,
    "On-time trains",
    self.on_time_train_count.to_string(),
  )
  quality_metric(builder, "On-time percent", "\{self.on_time_percent}%")
  quality_metric(
    builder,
    "Average delay (min)",
    self.average_delay_min.to_string(),
  )
  quality_metric(builder, "P95 delay (min)", self.p95_delay_min.to_string())
  quality_metric(
    builder,
    "Maximum headway deviation (min)",
    self.maximum_headway_deviation_min.to_string(),
  )
  quality_metric(builder, "Maximum load", "\{self.maximum_load_percent}%")
  builder.write_string("\n## Train evidence\n\n")
  builder.write_string(
    "| Train | Observed | Delay | Load | Headway deviation | Band |\n|---|---:|---:|---:|---:|---|\n",
  )
  for train in self.trains {
    builder.write_string(
      "|\{train.train_id}|\{train.observed}|\{train.delay_min}|\{train.maximum_load_percent}%|\{train.headway_deviation_min}|\{quality_band_label(train.band)}|\n",
    )
  }
  if self.notes.length() > 0 {
    builder.write_string("\n## Notes\n\n")
    for note in self.notes {
      builder.write_string("- \{note}\n")
    }
  }
  builder.to_string()
}

///|
pub fn quality_band_label(band : QualityBand) -> String {
  match band {
    Excellent => "excellent"
    Good => "good"
    Watch => "watch"
    Poor => "poor"
    Unknown => "unknown"
  }
}

///|
fn find_quality_runtime(
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
fn train_max_load_percent(
  loads : Array[PassengerLoad],
  train_id : String,
) -> Int {
  loads.fold(init=0, fn(current, load) {
    if load.train_id == train_id {
      max_int(current, passenger_load_percent(load))
    } else {
      current
    }
  })
}

///|
/// Use the first traversed segment as the train's service reference. This is
/// deterministic for a line timetable and remains useful when later adapters
/// add branch-specific segment groups.
fn train_headway_deviation(schedule : Schedule, train : Train) -> Int {
  if train.stops.length() < 2 {
    return 0
  }
  let first = train.stops[0].station_id
  let second = train.stops[1].station_id
  for segment in schedule.segments {
    if segment.from_station == first && segment.to_station == second {
      return abs_int(segment.headway_min - segment.scheduled_run_min / 2)
    }
  }
  0
}

///|
fn schedule_max_headway_deviation(schedule : Schedule) -> Int {
  schedule.segments.fold(init=0, fn(current, segment) {
    let headways = service_headways(schedule, segment.id)
    if headways.length() == 0 {
      current
    } else {
      let deviation = headways.fold(init=0, fn(best, headway) {
        max_int(best, abs_int(headway - segment.headway_min))
      })
      max_int(current, deviation)
    }
  })
}

///|
fn train_quality_band(
  stale : Bool,
  delay : Int,
  load_percent : Int,
  headway_deviation : Int,
  thresholds : QualityThresholds,
) -> QualityBand {
  if stale {
    Poor
  } else if delay > thresholds.maximum_delay_min * 2 ||
    load_percent > thresholds.maximum_load_percent * 2 ||
    headway_deviation > thresholds.maximum_headway_deviation_min * 2 {
    Poor
  } else if delay > thresholds.maximum_delay_min ||
    load_percent > thresholds.maximum_load_percent ||
    headway_deviation > thresholds.maximum_headway_deviation_min {
    Watch
  } else {
    Good
  }
}

///|
fn train_quality_reason(
  stale : Bool,
  delay : Int,
  load_percent : Int,
  headway_deviation : Int,
  thresholds : QualityThresholds,
) -> String {
  if stale {
    "telemetry is stale"
  } else if delay > thresholds.maximum_delay_min {
    "delay exceeds the quality threshold"
  } else if load_percent > thresholds.maximum_load_percent {
    "passenger load exceeds the configured capacity threshold"
  } else if headway_deviation > thresholds.maximum_headway_deviation_min {
    "headway deviation needs dispatcher review"
  } else {
    "within configured service-quality thresholds"
  }
}

///|
fn dashboard_band(
  schedule : Schedule,
  observed_count : Int,
  on_time_percent : Int,
  delays : Array[Int],
  maximum_headway_deviation : Int,
  maximum_load : Int,
  thresholds : QualityThresholds,
) -> QualityBand {
  if schedule.trains.length() == 0 || observed_count == 0 {
    return Unknown
  }
  if validate_schedule(schedule).length() > 0 {
    return Poor
  }
  if maximum_load > thresholds.maximum_load_percent ||
    maximum_headway_deviation > thresholds.maximum_headway_deviation_min ||
    percentile_nearest(delays, 95) > thresholds.maximum_delay_min {
    return Watch
  }
  if on_time_percent >= thresholds.excellent_on_time_percent {
    Excellent
  } else if on_time_percent >= thresholds.good_on_time_percent {
    Good
  } else {
    Watch
  }
}

///|
fn quality_notes(
  schedule : Schedule,
  observed_count : Int,
  on_time_percent : Int,
  maximum_headway_deviation : Int,
  maximum_load : Int,
  thresholds : QualityThresholds,
) -> Array[String] {
  let notes = []
  if schedule.trains.length() == 0 {
    notes.push("the schedule contains no trains")
  }
  if observed_count < schedule.trains.length() {
    notes.push("some planned trains have no fresh telemetry")
  }
  if on_time_percent < thresholds.good_on_time_percent && observed_count > 0 {
    notes.push("on-time performance is below the configured good threshold")
  }
  if maximum_headway_deviation > thresholds.maximum_headway_deviation_min {
    notes.push("at least one segment has a headway deviation above threshold")
  }
  if maximum_load > thresholds.maximum_load_percent {
    notes.push("at least one passenger observation exceeds configured capacity")
  }
  notes
}

///|
fn average_non_negative(values : Array[Int]) -> Int {
  if values.length() == 0 {
    0
  } else {
    values.fold(init=0, fn(total, value) { total + max_int(0, value) }) /
    values.length()
  }
}

///|
fn quality_metric(
  builder : StringBuilder,
  name : String,
  value : String,
) -> Unit {
  builder.write_string("| \{name} | \{value} |\n")
}
