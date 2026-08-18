///|
/// Validate all static timetable invariants and return every issue found.
pub fn validate_schedule(schedule : Schedule) -> Array[ValidationIssue] {
  let issues = []
  if schedule.id.trim() == "" {
    issues.push({
      code: "S001",
      severity: "error",
      path: "id",
      message: "schedule id must not be empty",
      hint: "Use a stable identifier shared by the OCC import job.",
    })
  }
  if schedule.line_name.trim() == "" {
    issues.push({
      code: "S002",
      severity: "error",
      path: "line_name",
      message: "line name must not be empty",
      hint: "Name the operating line or service family.",
    })
  }
  validate_stations(schedule, issues)
  validate_segments(schedule, issues)
  validate_trains(schedule, issues)
  validate_reservations(schedule, issues)
  issues
}

///|
pub fn Schedule::is_valid(self : Schedule) -> Bool {
  validate_schedule(self).length() == 0
}

///|
pub fn validation_errors(
  issues : Array[ValidationIssue],
) -> Array[ValidationIssue] {
  issues.filter(fn(issue) { issue.severity == "error" })
}

///|
pub fn validation_summary(issues : Array[ValidationIssue]) -> String {
  if issues.length() == 0 {
    return "schedule is valid"
  }
  let errors = issues.filter(fn(issue) { issue.severity == "error" }).length()
  let warnings = issues
    .filter(fn(issue) { issue.severity == "warning" })
    .length()
  "\{errors} error(s), \{warnings} warning(s)"
}

///|
fn validate_stations(
  schedule : Schedule,
  issues : Array[ValidationIssue],
) -> Unit {
  let seen = []
  let mut previous_distance = -1
  for i, station in schedule.stations {
    let path = "stations[\{i}]"
    if !station.is_valid() {
      issues.push({
        code: "ST001",
        severity: "error",
        path,
        message: "station has invalid identity or position",
        hint: "Use a non-empty id/name and a positive platform count.",
      })
    }
    if seen.contains(station.id) {
      issues.push({
        code: "ST002",
        severity: "error",
        path: "\{path}.id",
        message: "station id is duplicated",
        hint: "Station identifiers are used by telemetry and must be unique.",
      })
    }
    seen.push(station.id)
    if station.distance_m <= previous_distance {
      issues.push({
        code: "ST003",
        severity: "error",
        path: "\{path}.distance_m",
        message: "station distances must increase along the line",
        hint: "Reverse-direction services still use the same line origin.",
      })
    }
    previous_distance = station.distance_m
  }
}

///|
fn validate_segments(
  schedule : Schedule,
  issues : Array[ValidationIssue],
) -> Unit {
  let seen = []
  for i, segment in schedule.segments {
    let path = "segments[\{i}]"
    if !segment.is_valid() {
      issues.push({
        code: "SG001",
        severity: "error",
        path,
        message: "segment timing constraints are inconsistent",
        hint: "Require min <= scheduled <= max and a positive headway.",
      })
    }
    if seen.contains(segment.id) {
      issues.push({
        code: "SG002",
        severity: "error",
        path: "\{path}.id",
        message: "segment id is duplicated",
        hint: "Use one stable id per adjacent station pair.",
      })
    }
    seen.push(segment.id)
    if schedule.station_by_id(segment.from_station) is None {
      issues.push({
        code: "SG003",
        severity: "error",
        path: "\{path}.from_station",
        message: "segment references an unknown origin station",
        hint: "Add the station to the schedule before adding the segment.",
      })
    }
    if schedule.station_by_id(segment.to_station) is None {
      issues.push({
        code: "SG004",
        severity: "error",
        path: "\{path}.to_station",
        message: "segment references an unknown destination station",
        hint: "Add the station to the schedule before adding the segment.",
      })
    }
    if segment.throat_resource is Some(resource) && resource.trim() == "" {
      issues.push({
        code: "SG005",
        severity: "warning",
        path: "\{path}.throat_resource",
        message: "empty throat resource is ignored",
        hint: "Use null when no throat resource is modelled.",
      })
    }
  }
}

///|
fn validate_trains(
  schedule : Schedule,
  issues : Array[ValidationIssue],
) -> Unit {
  let seen = []
  for i, train in schedule.trains {
    let path = "trains[\{i}]"
    if train.id.trim() == "" || train.service_name.trim() == "" {
      issues.push({
        code: "TR001",
        severity: "error",
        path,
        message: "train id and service name must not be empty",
        hint: "Keep train ids stable across schedule versions.",
      })
    }
    if seen.contains(train.id) {
      issues.push({
        code: "TR002",
        severity: "error",
        path: "\{path}.id",
        message: "train id is duplicated",
        hint: "Use one id per planned movement.",
      })
    }
    seen.push(train.id)
    if train.priority < 0 || train.priority > 9 {
      issues.push({
        code: "TR003",
        severity: "warning",
        path: "\{path}.priority",
        message: "priority outside the recommended 0..9 range",
        hint: "Use 0 for lowest and 9 for highest operational priority.",
      })
    }
    if train.length_m <= 0 || train.max_speed_kmh <= 0 {
      issues.push({
        code: "TR004",
        severity: "error",
        path,
        message: "train length and speed must be positive",
        hint: "Use physical consist data or an explicit simulation default.",
      })
    }
    validate_train_stops(schedule, train, path, issues)
  }
}

///|
fn validate_train_stops(
  schedule : Schedule,
  train : Train,
  path : String,
  issues : Array[ValidationIssue],
) -> Unit {
  if train.stops.length() < 2 {
    issues.push({
      code: "TR005",
      severity: "error",
      path: "\{path}.stops",
      message: "a train must have at least an origin and destination",
      hint: "Provide two or more ordered stop records.",
    })
  }
  let mut previous_departure = -1
  for j, stop in train.stops {
    let stop_path = "\{path}.stops[\{j}]"
    if schedule.station_by_id(stop.station_id) is None {
      issues.push({
        code: "TR006",
        severity: "error",
        path: "\{stop_path}.station_id",
        message: "stop references an unknown station",
        hint: "Use a station id declared by the line model.",
      })
    }
    if !stop.is_dwell_valid() {
      issues.push({
        code: "TR007",
        severity: "error",
        path: stop_path,
        message: "arrival/departure/platform values are invalid",
        hint: "Arrival must be no later than departure and platform must be positive.",
      })
    }
    if stop.arrival_min < previous_departure {
      issues.push({
        code: "TR008",
        severity: "error",
        path: "\{stop_path}.arrival_min",
        message: "train stops are not chronological",
        hint: "Sort stop times by movement direction before exporting.",
      })
    }
    previous_departure = stop.departure_min
  }
}

///|
fn validate_reservations(
  schedule : Schedule,
  issues : Array[ValidationIssue],
) -> Unit {
  for i, reservation in schedule.reservations {
    let path = "reservations[\{i}]"
    if reservation.entry_min >= reservation.exit_min {
      issues.push({
        code: "RS001",
        severity: "error",
        path,
        message: "route reservation must have positive duration",
        hint: "Exit time must be later than entry time.",
      })
    }
    if schedule.train_by_id(reservation.train_id) is None {
      issues.push({
        code: "RS002",
        severity: "error",
        path: "\{path}.train_id",
        message: "reservation references an unknown train",
        hint: "Reservations must belong to a train in this schedule.",
      })
    }
    if reservation.resource_id.trim() == "" {
      issues.push({
        code: "RS003",
        severity: "error",
        path: "\{path}.resource_id",
        message: "route resource id must not be empty",
        hint: "Use the interlocking, throat or crossover identifier.",
      })
    }
  }
}

///|
pub fn validation_report_json(schedule : Schedule) -> String {
  let issues = validate_schedule(schedule)
  let report : Map[String, Json] = Map([])
  report["valid"] = (issues.length() == 0).to_json()
  report["summary"] = validation_summary(issues).to_json()
  report["issues"] = issues.to_json()
  Json::object(report).stringify()
}
