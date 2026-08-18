///|
/// Gate used by an import or dispatch review.
pub(all) enum PlanGate {
  Pass
  Warn
  Reject
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CadenceReport {
  segment_id : String
  planned_entries : Int
  minimum_headway_min : Int?
  required_headway_min : Int
  utilization_percent : Int
  stable : Bool
  detail : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PlanReview {
  gate : PlanGate
  score : Int
  validation_issues : Array[ValidationIssue]
  conflicts : Array[Conflict]
  recommendations : Array[DispatchRecommendation]
  metrics : ScheduleMetrics
  cadence : Array[CadenceReport]
  explanation : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct TimetableMutation {
  train_id : String
  action : ActionKind
  station_id : String?
  before_arrival_min : Int
  after_arrival_min : Int
  before_departure_min : Int
  after_departure_min : Int
  reason : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Run one repeatable review across model, conflict, strategy and load
/// layers. This is a useful CI gate for schedule fixtures.
pub fn review_timetable(
  schedule : Schedule,
  runtimes : Array[TrainRuntime],
  at_min : Int,
  policy? : DispatchPolicy = default_dispatch_policy(),
) -> PlanReview {
  let validation_issues = validate_schedule(schedule)
  let conflicts = detect_realtime_conflicts(schedule, runtimes)
  let recommendations = suggest_dispatches(
    schedule,
    conflicts,
    runtimes,
    policy~,
  )
  let metrics = analyze_schedule(schedule, runtimes, at_min)
  let cadence = cadence_reports(schedule)
  let score = review_score(validation_issues, conflicts, metrics)
  let gate = if validation_issues.any(fn(issue) { issue.severity == "error" }) {
    Reject
  } else if conflicts.any(fn(conflict) {
      conflict.severity == "critical" || conflict.severity == "high"
    }) {
    Warn
  } else {
    Pass
  }
  {
    gate,
    score,
    validation_issues,
    conflicts,
    recommendations,
    metrics,
    cadence,
    explanation: review_explanation(gate, score),
  }
}

///|
fn review_score(
  issues : Array[ValidationIssue],
  conflicts : Array[Conflict],
  metrics : ScheduleMetrics,
) -> Int {
  let issue_penalty = issues
    .filter(fn(issue) { issue.severity == "error" })
    .length() *
    20
  let conflict_penalty = conflicts.fold(init=0, fn(total, conflict) {
    let penalty = match conflict.severity {
      "critical" => 15
      "high" => 8
      "medium" => 3
      _ => 1
    }
    total + penalty
  })
  clamp_int(
    100 - issue_penalty - conflict_penalty - metrics.maximum_delay_min,
    0,
    100,
  )
}

///|
fn review_explanation(gate : PlanGate, score : Int) -> String {
  let base = match gate {
    Pass =>
      "schedule passes static and dynamic review with no high-risk finding"
    Warn =>
      "schedule is usable for rehearsal but needs dispatcher review before release"
    Reject => "schedule has structural errors and must not be released"
  }
  base + " (score=\{score})"
}

///|
pub fn cadence_reports(schedule : Schedule) -> Array[CadenceReport] {
  let output = []
  for load in segment_loads(schedule) {
    let required = load.headway_min
    let minimum = minimum_service_headway(schedule, load.segment_id)
    let stable = match minimum {
      Some(value) => value >= required
      None => true
    }
    let detail = match minimum {
      Some(_) =>
        if stable {
          "minimum service headway meets the segment rule"
        } else {
          "planned entries are closer than the segment headway rule"
        }
      None => "fewer than two services are planned on this segment"
    }
    output.push({
      segment_id: load.segment_id,
      planned_entries: load.service_count,
      minimum_headway_min: minimum,
      required_headway_min: required,
      utilization_percent: load.load_percent,
      stable,
      detail,
    })
  }
  output
}

///|
/// Apply explicit delays to a copy of a schedule and return the mutations.
/// A missing train id is ignored so a stream adapter can pass a sparse set of
/// observations without building a separate lookup table.
pub fn apply_delay_profile(
  schedule : Schedule,
  delays : Array[(String, Int)],
) -> (Schedule, Array[TimetableMutation]) {
  let trains = []
  let mutations = []
  for train in schedule.trains {
    let delay = delay_for(train.id, delays)
    if delay == 0 {
      trains.push(train)
    } else {
      let shifted = shift_train_with_mutations(
        train,
        delay,
        mutations,
        SlowDown,
        "external delay profile",
      )
      trains.push(shifted)
    }
  }
  let shifted_schedule : Schedule = {
    id: schedule.id,
    service_date: schedule.service_date,
    timezone: schedule.timezone,
    line_name: schedule.line_name,
    stations: schedule.stations,
    segments: schedule.segments,
    trains,
    reservations: schedule.reservations,
    version: schedule.version + 1,
    notes: schedule.notes + " | delay profile applied",
  }
  (shifted_schedule, mutations)
}

///|
fn delay_for(train_id : String, delays : Array[(String, Int)]) -> Int {
  for item in delays {
    let (id, delay) = item
    if id == train_id {
      return delay
    }
  }
  0
}

///|
fn shift_train_with_mutations(
  train : Train,
  delay : Int,
  mutations : Array[TimetableMutation],
  action : ActionKind,
  reason : String,
) -> Train {
  let stops = []
  for stop in train.stops {
    let next_arrival = stop.arrival_min + delay
    let next_departure = stop.departure_min + delay
    mutations.push({
      train_id: train.id,
      action,
      station_id: Some(stop.station_id),
      before_arrival_min: stop.arrival_min,
      after_arrival_min: next_arrival,
      before_departure_min: stop.departure_min,
      after_departure_min: next_departure,
      reason,
    })
    stops.push({
      station_id: stop.station_id,
      arrival_min: next_arrival,
      departure_min: next_departure,
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
pub fn retime_station(
  schedule : Schedule,
  train_id : String,
  station_id : String,
  delta_min : Int,
  action : ActionKind,
  reason : String,
) -> (Schedule, Array[TimetableMutation]) {
  let trains = []
  let mutations = []
  for train in schedule.trains {
    if train.id != train_id {
      trains.push(train)
    } else {
      let stops = []
      for stop in train.stops {
        if stop.station_id == station_id {
          let arrival = max_int(0, stop.arrival_min + delta_min)
          let departure = max_int(arrival, stop.departure_min + delta_min)
          mutations.push({
            train_id,
            action,
            station_id: Some(station_id),
            before_arrival_min: stop.arrival_min,
            after_arrival_min: arrival,
            before_departure_min: stop.departure_min,
            after_departure_min: departure,
            reason,
          })
          stops.push({
            station_id: stop.station_id,
            arrival_min: arrival,
            departure_min: departure,
            platform: stop.platform,
            stop_kind: stop.stop_kind,
            minimum_dwell_min: stop.minimum_dwell_min,
            passenger_dwell_min: stop.passenger_dwell_min,
          })
        } else {
          stops.push(stop)
        }
      }
      trains.push({
        id: train.id,
        service_name: train.service_name,
        direction: train.direction,
        priority: train.priority,
        length_m: train.length_m,
        max_speed_kmh: train.max_speed_kmh,
        stops,
        notes: train.notes,
      })
    }
  }
  (
    {
      id: schedule.id,
      service_date: schedule.service_date,
      timezone: schedule.timezone,
      line_name: schedule.line_name,
      stations: schedule.stations,
      segments: schedule.segments,
      trains,
      reservations: schedule.reservations,
      version: schedule.version + 1,
      notes: schedule.notes + " | station retime",
    },
    mutations,
  )
}

///|
pub fn plan_gate_label(gate : PlanGate) -> String {
  match gate {
    Pass => "pass"
    Warn => "warn"
    Reject => "reject"
  }
}

///|
pub fn cadence_markdown(reports : Array[CadenceReport]) -> String {
  let builder = StringBuilder()
  builder.write_string("# Segment cadence\n\n")
  builder.write_string(
    "| Segment | Services | Minimum | Required | Load | Status |\n",
  )
  builder.write_string("|---|---:|---:|---:|---:|---|\n")
  for report in reports {
    let minimum = match report.minimum_headway_min {
      Some(value) => value.to_string()
      None => "-"
    }
    builder.write_string(
      "|\{report.segment_id}| \{report.planned_entries}| \{minimum}| \{report.required_headway_min}| \{report.utilization_percent}%| \{if report.stable { "stable" } else { "tight" }}|\n",
    )
  }
  builder.to_string()
}

///|
pub fn plan_review_json(review : PlanReview) -> String {
  review.to_json().stringify()
}

///|
pub fn plan_review_markdown(review : PlanReview) -> String {
  let builder = StringBuilder()
  builder.write_string("# Timetable review\n\n")
  builder.write_string(
    "Gate: **\{plan_gate_label(review.gate)}**  \nScore: **\{review.score}/100**  \n\{review.explanation}\n\n",
  )
  builder.write_string(
    "Conflicts: \{review.conflicts.length()}  \nRecommendations: \{review.recommendations.length()}  \nValidation issues: \{review.validation_issues.length()}\n\n",
  )
  builder.write_string(cadence_markdown(review.cadence))
  builder.to_string()
}

///|
pub fn services_between(
  schedule : Schedule,
  start_min : Int,
  end_min : Int,
) -> Array[String] {
  let output = []
  for train in schedule.trains {
    match train.first_time() {
      Some(start) =>
        if start >= start_min && start <= end_min {
          output.push(train.id)
        }
      None => ()
    }
  }
  output
}

///|
pub fn train_priority_order(schedule : Schedule) -> Array[String] {
  let trains = schedule.trains.copy()
  for i in 1..<trains.length() {
    let current = trains[i]
    let mut j = i
    while j > 0 && trains[j - 1].priority < current.priority {
      trains[j] = trains[j - 1]
      j -= 1
    }
    trains[j] = current
  }
  trains.map(fn(train) { train.id })
}

///|
pub fn safe_release_ready(review : PlanReview) -> Bool {
  review.gate is Pass &&
  review.conflicts.length() == 0 &&
  review.validation_issues.length() == 0
}
