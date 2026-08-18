///|
priv struct MovementWindow {
  train_id : String
  segment_id : String
  from_station : String
  to_station : String
  entry_min : Int
  exit_min : Int
  headway_min : Int
}

///|
priv struct DwellWindow {
  train_id : String
  station_id : String
  platform : Int
  arrival_min : Int
  departure_min : Int
}

///|
/// Detect all conflict classes supported by the core model. The result is
/// sorted by severity and then by time, making it immediately useful in an
/// OCC alert list.
pub fn detect_conflicts(schedule : Schedule) -> Array[Conflict] {
  let raw = []
  detect_headway_conflicts(schedule, raw)
  detect_platform_conflicts(schedule, raw)
  detect_route_conflicts(schedule, raw)
  prioritize_conflicts(deduplicate_conflicts(raw))
}

///|
pub fn detect_realtime_conflicts(
  schedule : Schedule,
  runtimes : Array[TrainRuntime],
) -> Array[Conflict] {
  let adjusted = schedule_with_runtime_delays(schedule, runtimes)
  detect_conflicts(adjusted)
}

///|
fn detect_headway_conflicts(
  schedule : Schedule,
  output : Array[Conflict],
) -> Unit {
  let windows = []
  for train in schedule.trains {
    for window in movement_windows(schedule, train) {
      windows.push(window)
    }
  }
  for i in 0..<windows.length() {
    for j in (i + 1)..<windows.length() {
      let first = windows[i]
      let second = windows[j]
      if first.segment_id == second.segment_id &&
        first.train_id != second.train_id {
        let required = max_int(first.headway_min, second.headway_min)
        let overlaps = intervals_overlap(
          first.entry_min,
          first.exit_min,
          second.entry_min,
          second.exit_min,
        )
        let start_gap = abs_int(second.entry_min - first.entry_min)
        let separation = start_gap
        if overlaps || separation < required {
          let start = overlap_start(first.entry_min, second.entry_min)
          let end = if overlaps {
            overlap_end(first.exit_min, second.exit_min)
          } else {
            start + 1
          }
          let severity = severity_from_gap(required, separation)
          output.push({
            id: conflict_id(
              "headway",
              first.train_id,
              second.train_id,
              first.segment_id,
            ),
            kind: HeadwayConflict,
            severity,
            resource_id: first.segment_id,
            first_train_id: first.train_id,
            second_train_id: second.train_id,
            start_min: start,
            end_min: end,
            required_separation_min: required,
            actual_separation_min: separation,
            message: "trains violate the safe separation on a line segment",
            evidence: "\{first.from_station}->\{first.to_station} \{format_clock(first.entry_min)}-\{format_clock(first.exit_min)} vs \{format_clock(second.entry_min)}-\{format_clock(second.exit_min)}",
          })
        }
      }
    }
  }
}

///|
fn movement_windows(
  schedule : Schedule,
  train : Train,
) -> Array[MovementWindow] {
  let output = []
  if train.stops.length() < 2 {
    return output
  }
  for i in 0..<(train.stops.length() - 1) {
    let from_stop = train.stops[i]
    let to_stop = train.stops[i + 1]
    let segment = find_segment(
      schedule,
      from_stop.station_id,
      to_stop.station_id,
    )
    match segment {
      Some(value) =>
        output.push({
          train_id: train.id,
          segment_id: value.id,
          from_station: from_stop.station_id,
          to_station: to_stop.station_id,
          entry_min: from_stop.departure_min,
          exit_min: to_stop.arrival_min,
          headway_min: positive_or(value.headway_min, 3),
        })
      None =>
        output.push({
          train_id: train.id,
          segment_id: "\{from_stop.station_id}->\{to_stop.station_id}",
          from_station: from_stop.station_id,
          to_station: to_stop.station_id,
          entry_min: from_stop.departure_min,
          exit_min: to_stop.arrival_min,
          headway_min: 3,
        })
    }
  }
  output
}

///|
fn find_segment(
  schedule : Schedule,
  from_station : String,
  to_station : String,
) -> LineSegment? {
  for segment in schedule.segments {
    if (
        segment.from_station == from_station && segment.to_station == to_station
      ) ||
      (segment.from_station == to_station && segment.to_station == from_station) {
      return Some(segment)
    }
  }
  None
}

///|
fn detect_platform_conflicts(
  schedule : Schedule,
  output : Array[Conflict],
) -> Unit {
  let dwells = []
  for train in schedule.trains {
    for stop in train.stops {
      dwells.push({
        train_id: train.id,
        station_id: stop.station_id,
        platform: stop.platform,
        arrival_min: stop.arrival_min,
        departure_min: stop.departure_min,
      })
    }
  }
  for i in 0..<dwells.length() {
    for j in (i + 1)..<dwells.length() {
      let first = dwells[i]
      let second = dwells[j]
      if first.station_id == second.station_id &&
        first.platform == second.platform &&
        first.train_id != second.train_id &&
        intervals_overlap(
          first.arrival_min,
          first.departure_min + 1,
          second.arrival_min,
          second.departure_min + 1,
        ) {
        output.push({
          id: conflict_id(
            "platform",
            first.train_id,
            second.train_id,
            "\{first.station_id}:\{first.platform}",
          ),
          kind: PlatformConflict,
          severity: "high",
          resource_id: "\{first.station_id}:\{first.platform}",
          first_train_id: first.train_id,
          second_train_id: second.train_id,
          start_min: overlap_start(first.arrival_min, second.arrival_min),
          end_min: overlap_end(
            first.departure_min + 1,
            second.departure_min + 1,
          ),
          required_separation_min: 1,
          actual_separation_min: 0,
          message: "two trains occupy the same platform at the same time",
          evidence: "\{first.station_id} platform \{first.platform}",
        })
      }
    }
  }
}

///|
fn detect_route_conflicts(
  schedule : Schedule,
  output : Array[Conflict],
) -> Unit {
  for i in 0..<schedule.reservations.length() {
    for j in (i + 1)..<schedule.reservations.length() {
      let first = schedule.reservations[i]
      let second = schedule.reservations[j]
      let first_end = first.exit_min + first.release_margin_min
      let second_end = second.exit_min + second.release_margin_min
      if first.resource_id == second.resource_id &&
        first.train_id != second.train_id &&
        intervals_overlap(
          first.entry_min,
          first_end,
          second.entry_min,
          second_end,
        ) {
        output.push({
          id: conflict_id(
            "route",
            first.train_id,
            second.train_id,
            first.resource_id,
          ),
          kind: RouteConflict,
          severity: "critical",
          resource_id: first.resource_id,
          first_train_id: first.train_id,
          second_train_id: second.train_id,
          start_min: overlap_start(first.entry_min, second.entry_min),
          end_min: overlap_end(first_end, second_end),
          required_separation_min: max_int(
            first.release_margin_min,
            second.release_margin_min,
          ),
          actual_separation_min: 0,
          message: "route reservations overlap in an interlocking resource",
          evidence: "\{first.route_name} / \{second.route_name}",
        })
      }
    }
  }
}

///|
fn deduplicate_conflicts(conflicts : Array[Conflict]) -> Array[Conflict] {
  let output = []
  let seen = []
  for conflict in conflicts {
    if !seen.contains(conflict.id) {
      seen.push(conflict.id)
      output.push(conflict)
    }
  }
  output
}

///|
fn prioritize_conflicts(conflicts : Array[Conflict]) -> Array[Conflict] {
  let output = []
  for conflict in conflicts {
    let mut inserted = false
    for i in 0..<output.length() {
      if !inserted && conflict_before(conflict, output[i]) {
        output.insert(i, conflict)
        inserted = true
      }
    }
    if !inserted {
      output.push(conflict)
    }
  }
  output
}

///|
fn conflict_before(first : Conflict, second : Conflict) -> Bool {
  let first_severity = severity_rank(first.severity)
  let second_severity = severity_rank(second.severity)
  first_severity < second_severity ||
  (first_severity == second_severity && first.start_min < second.start_min)
}

///|
fn schedule_with_runtime_delays(
  schedule : Schedule,
  runtimes : Array[TrainRuntime],
) -> Schedule {
  let trains = []
  for train in schedule.trains {
    let delay = runtime_delay_for(train.id, runtimes)
    if delay == 0 {
      trains.push(train)
    } else {
      trains.push(shift_train(train, delay))
    }
  }
  {
    id: schedule.id,
    service_date: schedule.service_date,
    timezone: schedule.timezone,
    line_name: schedule.line_name,
    stations: schedule.stations,
    segments: schedule.segments,
    trains,
    reservations: schedule.reservations,
    version: schedule.version,
    notes: schedule.notes,
  }
}

///|
fn runtime_delay_for(train_id : String, runtimes : Array[TrainRuntime]) -> Int {
  for runtime in runtimes {
    if runtime.train_id == train_id {
      return runtime.delay_min
    }
  }
  0
}

///|
fn shift_train(train : Train, delay : Int) -> Train {
  let stops = []
  for stop in train.stops {
    stops.push({
      station_id: stop.station_id,
      arrival_min: stop.arrival_min + delay,
      departure_min: stop.departure_min + delay,
      platform: stop.platform,
      stop_kind: stop.stop_kind,
      minimum_dwell_min: stop.minimum_dwell_min,
      passenger_dwell_min: stop.passenger_dwell_min,
    })
  }
  {
    id: train.id,
    service_name: train.service_name,
    direction: train.direction,
    priority: train.priority,
    length_m: train.length_m,
    max_speed_kmh: train.max_speed_kmh,
    stops,
    notes: train.notes,
  }
}

///|
pub fn conflict_count_by_kind(
  conflicts : Array[Conflict],
  kind : ConflictKind,
) -> Int {
  conflicts.filter(fn(conflict) { conflict.kind == kind }).length()
}

///|
pub fn highest_severity(conflicts : Array[Conflict]) -> String {
  if conflicts.length() == 0 {
    return "none"
  }
  let mut best = conflicts[0].severity
  for conflict in conflicts {
    if severity_rank(conflict.severity) < severity_rank(best) {
      best = conflict.severity
    }
  }
  best
}

///|
pub fn conflict_summary(conflicts : Array[Conflict]) -> String {
  if conflicts.length() == 0 {
    return "no conflicts"
  }
  let headway = conflict_count_by_kind(conflicts, HeadwayConflict)
  let platform = conflict_count_by_kind(conflicts, PlatformConflict)
  let route = conflict_count_by_kind(conflicts, RouteConflict)
  "\{conflicts.length()} conflict(s): headway=\{headway}, platform=\{platform}, route=\{route}, highest=\{highest_severity(conflicts)}"
}
