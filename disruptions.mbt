///|
/// Operational disruption categories supported by the scenario evaluator.
pub(all) enum IncidentKind {
  SegmentClosure
  StationClosure
  PlatformOutage
  SpeedRestriction
  TrainCancellation
  DataBlackout
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum IncidentSeverity {
  Advisory
  Warning
  Emergency
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A bounded disruption event. `value` means delay minutes for a closure or
/// speed restriction, and platform number for a platform outage.
pub(all) struct Incident {
  id : String
  kind : IncidentKind
  severity : IncidentSeverity
  target_id : String
  start_min : Int
  end_min : Int
  value : Int
  reason : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum ScenarioGate {
  Clear
  Review
  Blocked
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Per-service impact retained for dispatch review and post-incident audit.
pub(all) struct IncidentImpact {
  train_id : String
  affected : Bool
  cancelled : Bool
  delay_min : Int
  touched_stations : Array[String]
  reason : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Deterministic scenario comparison for one incident.
pub(all) struct ScenarioAssessment {
  incident : Incident
  gate : ScenarioGate
  conflicts_before : Int
  conflicts_after : Int
  affected_train_count : Int
  cancelled_train_count : Int
  estimated_delay_min : Int
  impacts : Array[IncidentImpact]
  notes : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A multi-incident assessment used for planned maintenance windows.
pub(all) struct ScenarioPortfolio {
  schedule_id : String
  assessments : Array[ScenarioAssessment]
  blocked_count : Int
  review_count : Int
  total_affected_trains : Int
  total_estimated_delay_min : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn incident(
  id~ : String,
  kind~ : IncidentKind,
  severity~ : IncidentSeverity,
  target_id~ : String,
  start_min~ : Int,
  end_min~ : Int,
  value? : Int = 0,
  reason? : String = "",
) -> Incident {
  {
    id,
    kind,
    severity,
    target_id,
    start_min: min_int(start_min, end_min),
    end_min: max_int(start_min, end_min),
    value: max_int(0, value),
    reason,
  }
}

///|
pub fn IncidentKind::label(self : IncidentKind) -> String {
  match self {
    SegmentClosure => "segment_closure"
    StationClosure => "station_closure"
    PlatformOutage => "platform_outage"
    SpeedRestriction => "speed_restriction"
    TrainCancellation => "train_cancellation"
    DataBlackout => "data_blackout"
  }
}

///|
pub fn IncidentSeverity::label(self : IncidentSeverity) -> String {
  match self {
    Advisory => "advisory"
    Warning => "warning"
    Emergency => "emergency"
  }
}

///|
pub fn ScenarioGate::label(self : ScenarioGate) -> String {
  match self {
    Clear => "clear"
    Review => "review"
    Blocked => "blocked"
  }
}

///|
/// Apply one incident to a scenario copy. The original schedule is never
/// mutated, and the returned version is incremented for audit consumers.
pub fn apply_incident(schedule : Schedule, item : Incident) -> Schedule {
  let trains = []
  for train in schedule.trains {
    if item.kind == TrainCancellation && train.id == item.target_id {
      continue
    }
    let affected = train_matches_incident(schedule, train, item)
    let delta = if affected { max_int(0, item.value) } else { 0 }
    let adjusted = if delta > 0 {
      shift_scenario_train(train, delta)
    } else {
      train
    }
    trains.push(adjusted)
  }
  {
    id: schedule.id,
    service_date: schedule.service_date,
    timezone: schedule.timezone,
    line_name: schedule.line_name,
    stations: schedule.stations,
    segments: schedule.segments,
    trains,
    reservations: scenario_reservations(schedule, item),
    version: schedule.version + 1,
    notes: "incident \{item.id}: \{item.reason}",
  }
}

///|
/// Compare conflict and service impact before and after an incident.
pub fn assess_incident(
  schedule : Schedule,
  item : Incident,
) -> ScenarioAssessment {
  let before = detect_conflicts(schedule)
  let impacted = []
  for train in schedule.trains {
    if train_matches_incident(schedule, train, item) {
      impacted.push(incident_impact(train, item))
    }
  }
  let adjusted = apply_incident(schedule, item)
  let after = detect_conflicts(adjusted)
  let cancelled = impacted.count_if(fn(impact) { impact.cancelled })
  let estimated_delay = impacted.fold(init=0, fn(total, impact) {
    total + impact.delay_min
  })
  let notes = scenario_notes(item, impacted, before.length(), after.length())
  {
    incident: item,
    gate: scenario_gate(item, before.length(), after.length(), impacted),
    conflicts_before: before.length(),
    conflicts_after: after.length(),
    affected_train_count: impacted.length(),
    cancelled_train_count: cancelled,
    estimated_delay_min: estimated_delay,
    impacts: impacted,
    notes,
  }
}

///|
/// Assess a portfolio independently so each result is attributable to one
/// incident. A caller can then choose a combined simulation strategy.
pub fn assess_incidents(
  schedule : Schedule,
  incidents : Array[Incident],
) -> ScenarioPortfolio {
  let assessments = incidents.map(fn(item) { assess_incident(schedule, item) })
  let blocked = assessments.count_if(fn(item) { item.gate == Blocked })
  let review = assessments.count_if(fn(item) { item.gate == Review })
  {
    schedule_id: schedule.id,
    assessments,
    blocked_count: blocked,
    review_count: review,
    total_affected_trains: assessments.fold(init=0, fn(total, item) {
      total + item.affected_train_count
    }),
    total_estimated_delay_min: assessments.fold(init=0, fn(total, item) {
      total + item.estimated_delay_min
    }),
  }
}

///|
/// Select the least disruptive incident from a portfolio using a stable
/// lexicographic score: gate, delay, affected services, then ID.
pub fn least_disruptive_incident(
  portfolio : ScenarioPortfolio,
) -> ScenarioAssessment? {
  if portfolio.assessments.length() == 0 {
    return None
  }
  let mut best = portfolio.assessments[0]
  for assessment in portfolio.assessments[1:] {
    if assessment_before(assessment, best) {
      best = assessment
    }
  }
  Some(best)
}

///|
pub fn scenario_assessment_json(assessment : ScenarioAssessment) -> String {
  assessment.to_json().stringify()
}

///|
pub fn scenario_portfolio_json(portfolio : ScenarioPortfolio) -> String {
  portfolio.to_json().stringify()
}

///|
pub fn scenario_portfolio_markdown(portfolio : ScenarioPortfolio) -> String {
  let builder = StringBuilder()
  builder <+ "# Scenario portfolio\n\n"
  builder <+ "Schedule: \{portfolio.schedule_id}\n\n"
  builder <+
    "| Incident | Kind | Gate | Affected | Cancelled | Delay (min) | Conflicts |\n|---|---|---|---:|---:|---:|---:|\n"
  for assessment in portfolio.assessments {
    builder <+
      "| \{assessment.incident.id} | \{assessment.incident.kind.label()} | \{assessment.gate.label()} | \{assessment.affected_train_count} | \{assessment.cancelled_train_count} | \{assessment.estimated_delay_min} | \{assessment.conflicts_before} -> \{assessment.conflicts_after} |\n"
  }
  builder <+
    "\nSummary: blocked=\{portfolio.blocked_count}, review=\{portfolio.review_count}, affected=\{portfolio.total_affected_trains}, delay=\{portfolio.total_estimated_delay_min} min\n"
  builder.to_string()
}

///|
fn train_matches_incident(
  schedule : Schedule,
  train : Train,
  item : Incident,
) -> Bool {
  match item.kind {
    TrainCancellation => train.id == item.target_id
    DataBlackout => train.id == item.target_id
    StationClosure | PlatformOutage =>
      train.stops.any(fn(stop) {
        stop.station_id == item.target_id &&
        stop_time_intersects(stop, item.start_min, item.end_min)
      })
    SegmentClosure | SpeedRestriction =>
      train_has_segment(schedule, train, item.target_id)
  }
}

///|
fn train_has_segment(
  schedule : Schedule,
  train : Train,
  segment_id : String,
) -> Bool {
  if train.stops.length() < 2 {
    return false
  }
  for i in 0..<(train.stops.length() - 1) {
    let first = train.stops[i]
    let second = train.stops[i + 1]
    for segment in schedule.segments {
      if segment.id == segment_id &&
        (
          (
            segment.from_station == first.station_id &&
            segment.to_station == second.station_id
          ) ||
          (
            segment.from_station == second.station_id &&
            segment.to_station == first.station_id
          )
        ) {
        return true
      }
    }
  }
  false
}

///|
fn stop_time_intersects(
  stop : StopTime,
  start_min : Int,
  end_min : Int,
) -> Bool {
  intervals_overlap(
    stop.arrival_min,
    max_int(stop.arrival_min + 1, stop.departure_min),
    start_min,
    end_min,
  )
}

///|
fn incident_impact(train : Train, item : Incident) -> IncidentImpact {
  let touched = []
  for stop in train.stops {
    if stop.station_id == item.target_id ||
      item.kind == SegmentClosure ||
      item.kind == SpeedRestriction {
      if !touched.contains(stop.station_id) {
        touched.push(stop.station_id)
      }
    }
  }
  touched.sort()
  {
    train_id: train.id,
    affected: true,
    cancelled: item.kind == TrainCancellation,
    delay_min: if item.kind == TrainCancellation {
      0
    } else {
      max_int(0, item.value)
    },
    touched_stations: touched,
    reason: impact_reason(item),
  }
}

///|
fn impact_reason(item : Incident) -> String {
  match item.kind {
    TrainCancellation => "service is cancelled by scenario policy"
    DataBlackout => "telemetry source is unavailable for this service"
    StationClosure => "service calls at a closed station"
    PlatformOutage => "service uses an unavailable platform at a station"
    SegmentClosure => "service traverses a closed line segment"
    SpeedRestriction => "service traverses a speed-restricted line segment"
  }
}

///|
fn scenario_reservations(
  schedule : Schedule,
  item : Incident,
) -> Array[RouteReservation] {
  schedule.reservations.map(fn(reservation) {
    if reservation.train_id == item.target_id && item.kind == TrainCancellation {
      {
        id: reservation.id,
        train_id: reservation.train_id,
        resource_id: reservation.resource_id,
        entry_min: reservation.entry_min,
        exit_min: reservation.entry_min,
        release_margin_min: reservation.release_margin_min,
        route_name: "cancelled",
      }
    } else if item.kind == SpeedRestriction &&
      reservation.resource_id == item.target_id {
      {
        id: reservation.id,
        train_id: reservation.train_id,
        resource_id: reservation.resource_id,
        entry_min: reservation.entry_min + item.value,
        exit_min: reservation.exit_min + item.value,
        release_margin_min: reservation.release_margin_min,
        route_name: reservation.route_name,
      }
    } else {
      reservation
    }
  })
}

///|
fn shift_scenario_train(train : Train, delta : Int) -> Train {
  let stops = train.stops.map(fn(stop) {
    {
      station_id: stop.station_id,
      arrival_min: stop.arrival_min + delta,
      departure_min: stop.departure_min + delta,
      platform: stop.platform,
      stop_kind: stop.stop_kind,
      minimum_dwell_min: stop.minimum_dwell_min,
      passenger_dwell_min: stop.passenger_dwell_min,
    }
  })
  {
    id: train.id,
    service_name: train.service_name,
    direction: train.direction,
    priority: train.priority,
    length_m: train.length_m,
    max_speed_kmh: train.max_speed_kmh,
    stops,
    notes: "scenario shift +\{delta} min; \{train.notes}",
  }
}

///|
fn scenario_gate(
  item : Incident,
  conflicts_before : Int,
  conflicts_after : Int,
  impacts : Array[IncidentImpact],
) -> ScenarioGate {
  if item.severity == Emergency ||
    item.kind == SegmentClosure ||
    item.kind == StationClosure {
    Blocked
  } else if conflicts_after > conflicts_before || impacts.length() > 0 {
    Review
  } else {
    Clear
  }
}

///|
fn scenario_notes(
  item : Incident,
  impacts : Array[IncidentImpact],
  conflicts_before : Int,
  conflicts_after : Int,
) -> Array[String] {
  let notes = []
  if item.reason == "" {
    notes.push("incident has no operator reason")
  }
  if impacts.length() == 0 {
    notes.push("no scheduled service matched the incident target")
  }
  if conflicts_after > conflicts_before {
    notes.push("scenario increases the detected conflict count")
  }
  if item.end_min <= item.start_min {
    notes.push("incident window is empty or instantaneous")
  }
  notes
}

///|
fn assessment_before(
  first : ScenarioAssessment,
  second : ScenarioAssessment,
) -> Bool {
  let first_gate = gate_rank(first.gate)
  let second_gate = gate_rank(second.gate)
  first_gate < second_gate ||
  (
    first_gate == second_gate &&
    first.estimated_delay_min < second.estimated_delay_min
  ) ||
  (
    first_gate == second_gate &&
    first.estimated_delay_min == second.estimated_delay_min &&
    first.incident.id < second.incident.id
  )
}

///|
fn gate_rank(gate : ScenarioGate) -> Int {
  match gate {
    Clear => 0
    Review => 1
    Blocked => 2
  }
}
