///|
/// Aggregate health indicators for a timetable review screen.
pub(all) struct ScheduleMetrics {
  train_count : Int
  station_count : Int
  segment_count : Int
  total_train_km : Int
  average_run_min : Int
  peak_headway_load_percent : Int
  platform_occupancy_percent : Int
  conflict_count : Int
  high_risk_conflict_count : Int
  active_train_count : Int
  average_delay_min : Int
  maximum_delay_min : Int
  validation_issue_count : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SegmentLoad {
  segment_id : String
  service_count : Int
  occupied_minutes : Int
  headway_min : Int
  load_percent : Int
  directions : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PlatformLoad {
  station_id : String
  platform : Int
  occupied_minutes : Int
  service_count : Int
  load_percent : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn analyze_schedule(
  schedule : Schedule,
  runtimes : Array[TrainRuntime],
  at_min : Int,
) -> ScheduleMetrics {
  let conflicts = detect_realtime_conflicts(schedule, runtimes)
  let issues = validate_schedule(schedule)
  let total_train_km = schedule.trains.fold(init=0, fn(total, train) {
    total + train_distance_m(schedule, train) / 1000
  })
  let total_run = schedule.trains.fold(init=0, fn(total, train) {
    total + train_duration(train)
  })
  let average_run_min = if schedule.trains.length() == 0 {
    0
  } else {
    total_run / schedule.trains.length()
  }
  let delays = runtimes.map(fn(runtime) { runtime.delay_min })
  let average_delay_min = if delays.length() == 0 {
    0
  } else {
    delays.fold(init=0, fn(total, delay) { total + delay }) / delays.length()
  }
  let maximum_delay_min = if delays.length() == 0 {
    0
  } else {
    delays.fold(init=0, fn(best, delay) {
      if delay > best {
        delay
      } else {
        best
      }
    })
  }
  let loads = segment_loads(schedule)
  let platform_loads = platform_loads(schedule)
  {
    train_count: schedule.trains.length(),
    station_count: schedule.stations.length(),
    segment_count: schedule.segments.length(),
    total_train_km,
    average_run_min,
    peak_headway_load_percent: loads.fold(init=0, fn(best, load) {
      if load.load_percent > best {
        load.load_percent
      } else {
        best
      }
    }),
    platform_occupancy_percent: platform_loads.fold(init=0, fn(best, load) {
      if load.load_percent > best {
        load.load_percent
      } else {
        best
      }
    }),
    conflict_count: conflicts.length(),
    high_risk_conflict_count: conflicts
    .filter(fn(conflict) {
      conflict.severity == "critical" || conflict.severity == "high"
    })
    .length(),
    active_train_count: runtimes
    .filter(fn(runtime) {
      runtime.mode != Finished &&
      runtime.mode != Cancelled &&
      runtime.observed_min <= at_min
    })
    .length(),
    average_delay_min,
    maximum_delay_min,
    validation_issue_count: issues.length(),
  }
}

///|
pub fn segment_loads(schedule : Schedule) -> Array[SegmentLoad] {
  let output = []
  for segment in schedule.segments {
    let mut service_count = 0
    let mut occupied_minutes = 0
    let directions = []
    for train in schedule.trains {
      let windows = movement_windows(schedule, train)
      for window in windows {
        if window.segment_id == segment.id {
          service_count += 1
          occupied_minutes += max_int(1, window.exit_min - window.entry_min)
          append_unique(directions, train.direction.label())
        }
      }
    }
    let span = timetable_span(schedule)
    let load_percent = if span == 0 {
      0
    } else {
      clamp_int(occupied_minutes * 100 / span, 0, 999)
    }
    output.push({
      segment_id: segment.id,
      service_count,
      occupied_minutes,
      headway_min: segment.headway_min,
      load_percent,
      directions,
    })
  }
  output
}

///|
pub fn platform_loads(schedule : Schedule) -> Array[PlatformLoad] {
  let output = []
  let keys = []
  for train in schedule.trains {
    for stop in train.stops {
      let key = "\{stop.station_id}:\{stop.platform}"
      if !keys.contains(key) {
        keys.push(key)
        let occupied = platform_occupied_minutes(
          schedule,
          stop.station_id,
          stop.platform,
        )
        let count = platform_service_count(
          schedule,
          stop.station_id,
          stop.platform,
        )
        output.push({
          station_id: stop.station_id,
          platform: stop.platform,
          occupied_minutes: occupied,
          service_count: count,
          load_percent: if timetable_span(schedule) == 0 {
            0
          } else {
            clamp_int(occupied * 100 / timetable_span(schedule), 0, 999)
          },
        })
      }
    }
  }
  output
}

///|
fn train_distance_m(schedule : Schedule, train : Train) -> Int {
  let mut total = 0
  for i in 0..<(train.stops.length() - 1) {
    let start = station_distance(schedule, train.stops[i].station_id)
    let finish = station_distance(schedule, train.stops[i + 1].station_id)
    total += abs_int(finish - start)
  }
  total
}

///|
fn train_duration(train : Train) -> Int {
  match (train.first_time(), train.last_time()) {
    (Some(first), Some(last)) => max_int(0, last - first)
    _ => 0
  }
}

///|
fn timetable_span(schedule : Schedule) -> Int {
  let starts = []
  let ends = []
  for train in schedule.trains {
    if train.first_time() is Some(first) {
      starts.push(first)
    }
    if train.last_time() is Some(last) {
      ends.push(last)
    }
  }
  if starts.length() == 0 || ends.length() == 0 {
    0
  } else {
    let sorted_starts = unique_sorted_ints(starts)
    let sorted_ends = unique_sorted_ints(ends)
    max_int(1, sorted_ends[sorted_ends.length() - 1] - sorted_starts[0])
  }
}

///|
fn platform_occupied_minutes(
  schedule : Schedule,
  station_id : String,
  platform : Int,
) -> Int {
  schedule.trains.fold(init=0, fn(total, train) {
    total +
    train.stops.fold(init=0, fn(inner, stop) {
      if stop.station_id == station_id && stop.platform == platform {
        inner + max_int(1, stop.departure_min - stop.arrival_min)
      } else {
        inner
      }
    })
  })
}

///|
fn platform_service_count(
  schedule : Schedule,
  station_id : String,
  platform : Int,
) -> Int {
  schedule.trains.fold(init=0, fn(total, train) {
    total +
    train.stops
    .filter(fn(stop) {
      stop.station_id == station_id && stop.platform == platform
    })
    .length()
  })
}

///|
pub fn service_headways(schedule : Schedule, segment_id : String) -> Array[Int] {
  let entries = []
  for train in schedule.trains {
    for window in movement_windows(schedule, train) {
      if window.segment_id == segment_id {
        entries.push(window.entry_min)
      }
    }
  }
  let sorted = unique_sorted_ints(entries)
  let headways = []
  for i in 1..<sorted.length() {
    headways.push(sorted[i] - sorted[i - 1])
  }
  headways
}

///|
pub fn minimum_service_headway(
  schedule : Schedule,
  segment_id : String,
) -> Int? {
  let headways = service_headways(schedule, segment_id)
  if headways.length() == 0 {
    None
  } else {
    Some(
      headways.fold(init=headways[0], fn(best, current) {
        if current < best {
          current
        } else {
          best
        }
      }),
    )
  }
}

///|
pub fn schedule_health_label(metrics : ScheduleMetrics) -> String {
  if metrics.validation_issue_count > 0 {
    "invalid"
  } else if metrics.high_risk_conflict_count > 0 {
    "at-risk"
  } else if metrics.conflict_count > 0 || metrics.maximum_delay_min > 3 {
    "watch"
  } else {
    "stable"
  }
}

///|
pub fn schedule_metrics_markdown(metrics : ScheduleMetrics) -> String {
  let builder = StringBuilder()
  builder.write_string("# ATS schedule health\n\n")
  builder.write_string("| Metric | Value |\n|---|---:|\n")
  write_metric(builder, "Health", schedule_health_label(metrics))
  write_metric(builder, "Trains", metrics.train_count.to_string())
  write_metric(builder, "Stations", metrics.station_count.to_string())
  write_metric(builder, "Segments", metrics.segment_count.to_string())
  write_metric(builder, "Train kilometres", metrics.total_train_km.to_string())
  write_metric(
    builder,
    "Average run (min)",
    metrics.average_run_min.to_string(),
  )
  write_metric(
    builder,
    "Peak segment load (%)",
    metrics.peak_headway_load_percent.to_string(),
  )
  write_metric(
    builder,
    "Peak platform load (%)",
    metrics.platform_occupancy_percent.to_string(),
  )
  write_metric(builder, "Conflicts", metrics.conflict_count.to_string())
  write_metric(
    builder,
    "High-risk conflicts",
    metrics.high_risk_conflict_count.to_string(),
  )
  write_metric(
    builder,
    "Average delay (min)",
    metrics.average_delay_min.to_string(),
  )
  write_metric(
    builder,
    "Maximum delay (min)",
    metrics.maximum_delay_min.to_string(),
  )
  write_metric(
    builder,
    "Validation issues",
    metrics.validation_issue_count.to_string(),
  )
  builder.to_string()
}

///|
fn write_metric(builder : StringBuilder, name : String, value : String) -> Unit {
  builder.write_string("| ")
  builder.write_string(pad_right(name, 28))
  builder.write_string(" | ")
  builder.write_string(value)
  builder.write_string(" |\n")
}

///|
pub fn station_sequence(schedule : Schedule, train_id : String) -> String {
  match schedule.train_by_id(train_id) {
    Some(train) => train.stops.map(fn(stop) { stop.station_id }).join(" -> ")
    None => ""
  }
}

///|
pub fn operating_window(schedule : Schedule) -> (Int, Int)? {
  let starts = []
  let ends = []
  for train in schedule.trains {
    if train.first_time() is Some(start) {
      starts.push(start)
    }
    if train.last_time() is Some(end) {
      ends.push(end)
    }
  }
  if starts.length() == 0 || ends.length() == 0 {
    None
  } else {
    let ordered_starts = unique_sorted_ints(starts)
    let ordered_ends = unique_sorted_ints(ends)
    Some((ordered_starts[0], ordered_ends[ordered_ends.length() - 1]))
  }
}

///|
pub fn compact_schedule_text(schedule : Schedule) -> String {
  let builder = StringBuilder()
  builder.write_string("\{schedule.line_name} / \{schedule.service_date}\n")
  builder.write_string(repeat_char("-", 48))
  builder.write_string("\n")
  match operating_window(schedule) {
    Some((start, end)) =>
      builder.write_string(
        "window \{format_clock(start)}-\{format_clock(end)}\n",
      )
    None => builder.write_string("window empty\n")
  }
  for train in schedule.trains {
    builder.write_string(
      "\{train.id} \{train.direction.label()} \{format_clock(train.first_time().unwrap_or(0))}-\{format_clock(train.last_time().unwrap_or(0))}: \{station_sequence(schedule, train.id)}\n",
    )
  }
  builder.to_string()
}

///|
pub fn delay_histogram(
  runtimes : Array[TrainRuntime],
  bucket_min : Int,
) -> Array[(Int, Int)] {
  let bucket = positive_or(bucket_min, 1)
  let starts = []
  for runtime in runtimes {
    starts.push(runtime.delay_min / bucket * bucket)
  }
  let values = unique_sorted_ints(starts)
  let output = []
  for value in values {
    output.push(
      (
        value,
        runtimes
        .filter(fn(runtime) { runtime.delay_min / bucket * bucket == value })
        .length(),
      ),
    )
  }
  output
}

///|
pub fn conflict_resource_ids(conflicts : Array[Conflict]) -> Array[String] {
  let ids = []
  for conflict in conflicts {
    append_unique(ids, conflict.resource_id)
  }
  ids
}

///|
pub fn health_dashboard_json(
  schedule : Schedule,
  runtimes : Array[TrainRuntime],
  at_min : Int,
) -> String {
  let metrics = analyze_schedule(schedule, runtimes, at_min)
  Json::object({
    "metrics": metrics.to_json(),
    "health": schedule_health_label(metrics).to_json(),
    "resources": conflict_resource_ids(
      detect_realtime_conflicts(schedule, runtimes),
    ).to_json(),
    "histogram": delay_histogram(runtimes, 2).to_json(),
  }).stringify()
}
