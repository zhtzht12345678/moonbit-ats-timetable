///|
/// Recovery action categories used by the service-recovery layer. A recovery
/// candidate is an auditable proposal; it does not actuate a train.
pub(all) enum RecoveryAction {
  HoldAtStation
  SkipStation
  UseRunningMargin
  ShortTurn
  ManualReview
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Policy limits keep automatic ranking inside the operating envelope
/// declared by a caller. The policy is data, so a control room can record it
/// beside every recommendation.
pub(all) struct RecoveryPolicy {
  minimum_delay_min : Int
  maximum_hold_min : Int
  maximum_speedup_min : Int
  minimum_platform_buffer_min : Int
  maximum_candidates_per_train : Int
  allow_skip : Bool
  allow_short_turn : Bool
  require_transfer_protection : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
/// One ranked service-recovery candidate with before/after conflict evidence.
pub(all) struct RecoveryCandidate {
  id : String
  train_id : String
  action : RecoveryAction
  station_id : String?
  target_station_id : String?
  delta_min : Int
  estimated_recovery_min : Int
  passenger_impact : Int
  conflicts_before : Int
  conflicts_after : Int
  score : Int
  feasible : Bool
  explanation : String
  prerequisites : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Gate for a selected recovery plan.
pub(all) enum RecoveryGate {
  Ready
  Review
  Blocked
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Rolling recovery plan. Selection is deterministic and at most one
/// candidate per train is selected in a single horizon.
pub(all) struct RecoveryPlan {
  schedule_id : String
  at_min : Int
  horizon_min : Int
  policy : RecoveryPolicy
  gate : RecoveryGate
  initial_delay_min : Int
  projected_delay_min : Int
  initial_conflict_count : Int
  projected_conflict_count : Int
  selected_count : Int
  candidates : Array[RecoveryCandidate]
  selected_ids : Array[String]
  explanation : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn default_recovery_policy() -> RecoveryPolicy {
  {
    minimum_delay_min: 2,
    maximum_hold_min: 4,
    maximum_speedup_min: 2,
    minimum_platform_buffer_min: 1,
    maximum_candidates_per_train: 4,
    allow_skip: true,
    allow_short_turn: true,
    require_transfer_protection: true,
  }
}

///|
/// Construct a policy with safe lower bounds and a bounded candidate fan-out.
pub fn recovery_policy(
  minimum_delay_min~ : Int,
  maximum_hold_min~ : Int,
  maximum_speedup_min~ : Int,
  minimum_platform_buffer_min~ : Int,
  maximum_candidates_per_train~ : Int,
  allow_skip~ : Bool,
  allow_short_turn~ : Bool,
  require_transfer_protection~ : Bool,
) -> RecoveryPolicy {
  {
    minimum_delay_min: max_int(0, minimum_delay_min),
    maximum_hold_min: max_int(0, maximum_hold_min),
    maximum_speedup_min: max_int(0, maximum_speedup_min),
    minimum_platform_buffer_min: max_int(0, minimum_platform_buffer_min),
    maximum_candidates_per_train: clamp_int(maximum_candidates_per_train, 1, 12),
    allow_skip,
    allow_short_turn,
    require_transfer_protection,
  }
}

///|
pub fn RecoveryAction::label(self : RecoveryAction) -> String {
  match self {
    HoldAtStation => "hold_at_station"
    SkipStation => "skip_station"
    UseRunningMargin => "use_running_margin"
    ShortTurn => "short_turn"
    ManualReview => "manual_review"
  }
}

///|
pub fn RecoveryGate::label(self : RecoveryGate) -> String {
  match self {
    Ready => "ready"
    Review => "review"
    Blocked => "blocked"
  }
}

///|
/// Build a ranked, bounded set of recovery candidates from current telemetry.
/// Every candidate is checked against the static conflict detector before it
/// is returned, so a caller can display evidence rather than a score alone.
pub fn build_recovery_candidates(
  schedule : Schedule,
  runtimes : Array[TrainRuntime],
  policy? : RecoveryPolicy = default_recovery_policy(),
) -> Array[RecoveryCandidate] {
  let before = detect_conflicts(schedule)
  let output = []
  let processed_train_ids = []
  for runtime in runtimes {
    if runtime.delay_min >= policy.minimum_delay_min &&
      !processed_train_ids.contains(runtime.train_id) {
      processed_train_ids.push(runtime.train_id)
      match schedule.train_by_id(runtime.train_id) {
        Some(train) => {
          let station = recovery_station(train, runtime.observed_min)
          let candidates = candidates_for_train(
            schedule,
            train,
            station,
            runtime.delay_min,
            policy,
            before.length(),
          )
          for candidate in candidates {
            output.push(candidate)
          }
        }
        None => ()
      }
    }
  }
  output.sort_by(recovery_candidate_before)
  output
}

///|
/// Select a rolling plan from the candidate set. A candidate must not worsen
/// static conflicts, and two actions for the same train are never combined.
pub fn build_recovery_plan(
  schedule : Schedule,
  runtimes : Array[TrainRuntime],
  at_min : Int,
  horizon_min? : Int = 30,
  policy? : RecoveryPolicy = default_recovery_policy(),
) -> RecoveryPlan {
  let horizon = max_int(1, horizon_min)
  let initial_conflicts = detect_conflicts(schedule)
  let initial_delay = total_recovery_delay(runtimes)
  let candidates = build_recovery_candidates(schedule, runtimes, policy~)
  let selected_ids = []
  let selected_trains = []
  let mut projected_schedule = schedule
  let mut selected_recovery = 0
  for candidate in candidates {
    if candidate.feasible && !selected_trains.contains(candidate.train_id) {
      let next_schedule = apply_recovery_candidate(
        projected_schedule, candidate,
      )
      let next_conflicts = detect_conflicts(next_schedule)
      if next_conflicts.length() <=
        detect_conflicts(projected_schedule).length() {
        selected_ids.push(candidate.id)
        selected_trains.push(candidate.train_id)
        selected_recovery += candidate.estimated_recovery_min
        projected_schedule = next_schedule
      }
    }
  }
  let projected_conflicts = detect_conflicts(projected_schedule)
  let projected_delay = max_int(0, initial_delay - selected_recovery)
  let gate = recovery_gate(
    initial_conflicts.length(),
    projected_conflicts.length(),
    selected_ids.length(),
    candidates.length(),
  )
  {
    schedule_id: schedule.id,
    at_min,
    horizon_min: horizon,
    policy,
    gate,
    initial_delay_min: initial_delay,
    projected_delay_min: projected_delay,
    initial_conflict_count: initial_conflicts.length(),
    projected_conflict_count: projected_conflicts.length(),
    selected_count: selected_ids.length(),
    candidates,
    selected_ids,
    explanation: recovery_explanation(
      gate,
      initial_delay,
      projected_delay,
      initial_conflicts.length(),
      projected_conflicts.length(),
    ),
  }
}

///|
pub fn RecoveryPlan::to_json_text(self : RecoveryPlan) -> String {
  self.to_json().stringify()
}

///|
pub fn RecoveryPlan::to_markdown(self : RecoveryPlan) -> String {
  let builder = StringBuilder()
  builder <+ "# Service recovery plan\n\n"
  builder <+ "| Metric | Value |\n|---|---:|\n"
  recovery_metric(builder, "Schedule", self.schedule_id)
  recovery_metric(builder, "Gate", self.gate.label())
  recovery_metric(builder, "At", format_clock(self.at_min))
  recovery_metric(builder, "Horizon (min)", self.horizon_min.to_string())
  recovery_metric(
    builder,
    "Initial delay (min)",
    self.initial_delay_min.to_string(),
  )
  recovery_metric(
    builder,
    "Projected delay (min)",
    self.projected_delay_min.to_string(),
  )
  recovery_metric(
    builder,
    "Conflicts",
    "\{self.initial_conflict_count} -> \{self.projected_conflict_count}",
  )
  recovery_metric(builder, "Selected", self.selected_count.to_string())
  builder <+ "\n## Candidates\n\n"
  builder <+
    "| Selected | Train | Action | Station | Recovery (min) | Conflicts | Score | Feasible |\n|---:|---|---|---|---:|---:|---:|---:|\n"
  for candidate in self.candidates {
    builder <+
      "|\{self.selected_ids.contains(candidate.id)}|\{candidate.train_id}|\{candidate.action.label()}|\{recovery_station_label(candidate.station_id)}|\{candidate.estimated_recovery_min}|\{candidate.conflicts_before} -> \{candidate.conflicts_after}|\{candidate.score}|\{candidate.feasible}|\n"
  }
  builder <+ "\n"
  builder.write_string(self.explanation)
  builder.to_string()
}

///|
pub fn recovery_candidate_json(candidate : RecoveryCandidate) -> String {
  candidate.to_json().stringify()
}

///|
pub fn selected_recovery_candidates(
  plan : RecoveryPlan,
) -> Array[RecoveryCandidate] {
  plan.candidates.filter(fn(candidate) {
    plan.selected_ids.contains(candidate.id)
  })
}

///|
pub fn recovery_candidate_before(
  left : RecoveryCandidate,
  right : RecoveryCandidate,
) -> Int {
  if left.feasible != right.feasible {
    if left.feasible {
      -1
    } else {
      1
    }
  } else if left.score != right.score {
    right.score - left.score
  } else if left.train_id != right.train_id {
    compare_strings(left.train_id, right.train_id)
  } else {
    compare_strings(left.id, right.id)
  }
}

///|
fn candidates_for_train(
  schedule : Schedule,
  train : Train,
  station : StopTime?,
  delay_min : Int,
  policy : RecoveryPolicy,
  conflicts_before : Int,
) -> Array[RecoveryCandidate] {
  let output = []
  match station {
    None =>
      output.push({
        id: "review:\{train.id}",
        train_id: train.id,
        action: ManualReview,
        station_id: None,
        target_station_id: None,
        delta_min: 0,
        estimated_recovery_min: 0,
        passenger_impact: 0,
        conflicts_before,
        conflicts_after: conflicts_before,
        score: 0,
        feasible: false,
        explanation: "the current telemetry does not map to a planned station",
        prerequisites: ["operator confirms train identity and position"],
      })
    Some(stop) => {
      let hold_delta = clamp_int(delay_min, 1, policy.maximum_hold_min)
      if policy.maximum_hold_min > 0 {
        output.push(
          make_candidate(
            schedule,
            train,
            HoldAtStation,
            Some(stop.station_id),
            None,
            hold_delta,
            0,
            conflicts_before,
            policy,
          ),
        )
      }
      if policy.maximum_speedup_min > 0 && train_has_margin(schedule, train) {
        output.push(
          make_candidate(
            schedule,
            train,
            UseRunningMargin,
            Some(stop.station_id),
            None,
            -clamp_int(delay_min, 1, policy.maximum_speedup_min),
            0,
            conflicts_before,
            policy,
          ),
        )
      }
      match skippable_recovery_stop(train, stop, policy) {
        Some(skip_stop) =>
          output.push(
            make_candidate(
              schedule,
              train,
              SkipStation,
              Some(stop.station_id),
              Some(skip_stop.station_id),
              -skip_stop.passenger_dwell_min,
              1,
              conflicts_before,
              policy,
            ),
          )
        None => ()
      }
      if policy.allow_short_turn && train.stops.length() >= 4 {
        output.push(
          make_candidate(
            schedule,
            train,
            ShortTurn,
            Some(stop.station_id),
            Some(train.stops[train.stops.length() - 2].station_id),
            -delay_min,
            2,
            conflicts_before,
            policy,
          ),
        )
      }
    }
  }
  limit_candidates(output, policy.maximum_candidates_per_train)
}

///|
fn make_candidate(
  schedule : Schedule,
  train : Train,
  action : RecoveryAction,
  station_id : String?,
  target_station_id : String?,
  delta_min : Int,
  passenger_impact : Int,
  conflicts_before : Int,
  policy : RecoveryPolicy,
) -> RecoveryCandidate {
  let candidate = {
    id: recovery_candidate_id(train.id, action, target_station_id),
    train_id: train.id,
    action,
    station_id,
    target_station_id,
    delta_min,
    estimated_recovery_min: estimated_recovery(action, delta_min, train),
    passenger_impact,
    conflicts_before,
    conflicts_after: conflicts_after_candidate(
      schedule, train, action, target_station_id, delta_min,
    ),
    score: 0,
    feasible: recovery_candidate_feasible(
      train, action, target_station_id, policy,
    ),
    explanation: recovery_explanation_for_action(action, target_station_id),
    prerequisites: recovery_prerequisites(action),
  }
  {
    id: candidate.id,
    train_id: candidate.train_id,
    action: candidate.action,
    station_id: candidate.station_id,
    target_station_id: candidate.target_station_id,
    delta_min: candidate.delta_min,
    estimated_recovery_min: candidate.estimated_recovery_min,
    passenger_impact: candidate.passenger_impact,
    conflicts_before: candidate.conflicts_before,
    conflicts_after: candidate.conflicts_after,
    score: recovery_score(candidate),
    feasible: candidate.feasible,
    explanation: candidate.explanation,
    prerequisites: candidate.prerequisites,
  }
}

///|
fn conflicts_after_candidate(
  schedule : Schedule,
  train : Train,
  action : RecoveryAction,
  target_station_id : String?,
  delta_min : Int,
) -> Int {
  let adjusted = apply_recovery_to_train(
    schedule, train, action, target_station_id, delta_min,
  )
  detect_conflicts(adjusted).length()
}

///|
fn apply_recovery_candidate(
  schedule : Schedule,
  candidate : RecoveryCandidate,
) -> Schedule {
  match schedule.train_by_id(candidate.train_id) {
    None => schedule
    Some(train) =>
      apply_recovery_to_train(
        schedule,
        train,
        candidate.action,
        candidate.target_station_id,
        candidate.delta_min,
      )
  }
}

///|
fn apply_recovery_to_train(
  schedule : Schedule,
  train : Train,
  action : RecoveryAction,
  target_station_id : String?,
  delta_min : Int,
) -> Schedule {
  let adjusted = match action {
    HoldAtStation => recovery_shift_train(train, max_int(0, delta_min))
    UseRunningMargin => recovery_shift_train(train, delta_min)
    SkipStation => recovery_remove_stop(train, target_station_id)
    ShortTurn => recovery_short_turn(train, target_station_id)
    ManualReview => train
  }
  let trains = schedule.trains.map(fn(item) {
    if item.id == train.id {
      adjusted
    } else {
      item
    }
  })
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
    notes: schedule.notes + " | recovery preview: " + action.label(),
  }
}

///|
fn recovery_shift_train(train : Train, delta_min : Int) -> Train {
  let stops = train.stops.map(fn(stop) {
    {
      station_id: stop.station_id,
      arrival_min: stop.arrival_min + delta_min,
      departure_min: stop.departure_min + delta_min,
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
    notes: train.notes + " | recovery shift " + delta_min.to_string(),
  }
}

///|
fn recovery_remove_stop(train : Train, station_id : String?) -> Train {
  let stops = match station_id {
    None => train.stops
    Some(id) => train.stops.filter(fn(stop) { stop.station_id != id })
  }
  {
    id: train.id,
    service_name: train.service_name,
    direction: train.direction,
    priority: train.priority,
    length_m: train.length_m,
    max_speed_kmh: train.max_speed_kmh,
    stops,
    notes: train.notes + " | recovery skip",
  }
}

///|
fn recovery_short_turn(train : Train, station_id : String?) -> Train {
  let stops = match station_id {
    None => train.stops
    Some(id) => {
      let output = []
      for stop in train.stops {
        output.push(stop)
        if stop.station_id == id {
          break
        }
      }
      if output.length() < 2 {
        train.stops
      } else {
        output
      }
    }
  }
  {
    id: train.id,
    service_name: train.service_name,
    direction: train.direction,
    priority: train.priority,
    length_m: train.length_m,
    max_speed_kmh: train.max_speed_kmh,
    stops,
    notes: train.notes + " | recovery short turn",
  }
}

///|
fn recovery_station(train : Train, observed_min : Int) -> StopTime? {
  for stop in train.stops {
    if stop.departure_min >= observed_min {
      return Some(stop)
    }
  }
  None
}

///|
fn skippable_recovery_stop(
  train : Train,
  current : StopTime,
  policy : RecoveryPolicy,
) -> StopTime? {
  if !policy.allow_skip || train.stops.length() < 3 {
    return None
  }
  let mut passed_current = false
  for i, stop in train.stops {
    if passed_current &&
      i < train.stops.length() - 1 &&
      stop.stop_kind != "terminal" &&
      stop.stop_kind != "transfer" &&
      stop.stop_kind != "pass" {
      return Some(stop)
    }
    if stop.station_id == current.station_id {
      passed_current = true
    }
  }
  None
}

///|
fn train_has_margin(schedule : Schedule, train : Train) -> Bool {
  if train.stops.length() < 2 {
    return false
  }
  for i in 0..<(train.stops.length() - 1) {
    match
      find_segment(
        schedule,
        train.stops[i].station_id,
        train.stops[i + 1].station_id,
      ) {
      Some(segment) =>
        if segment.max_run_min > segment.scheduled_run_min {
          return true
        }
      None => ()
    }
  }
  false
}

///|
fn recovery_candidate_feasible(
  train : Train,
  action : RecoveryAction,
  target_station_id : String?,
  policy : RecoveryPolicy,
) -> Bool {
  match action {
    HoldAtStation => true
    UseRunningMargin => true
    SkipStation =>
      if policy.require_transfer_protection {
        match target_station_id {
          None => false
          Some(id) =>
            !train.stops.any(fn(stop) {
              stop.station_id == id && stop.stop_kind == "transfer"
            })
        }
      } else {
        target_station_id is Some(_)
      }
    ShortTurn => policy.allow_short_turn && target_station_id is Some(_)
    ManualReview => false
  }
}

///|
fn estimated_recovery(
  action : RecoveryAction,
  delta_min : Int,
  train : Train,
) -> Int {
  match action {
    HoldAtStation => 0
    UseRunningMargin => max_int(0, 0 - delta_min)
    SkipStation =>
      train.stops.fold(init=0, fn(best, stop) {
        max_int(best, stop.passenger_dwell_min)
      })
    ShortTurn => max_int(1, train.stops.length() / 2)
    ManualReview => 0
  }
}

///|
fn recovery_score(candidate : RecoveryCandidate) -> Int {
  let conflict_gain = candidate.conflicts_before - candidate.conflicts_after
  let feasibility_score = if candidate.feasible { 10 } else { -1000 }
  candidate.estimated_recovery_min * 20 +
  conflict_gain * 50 -
  candidate.passenger_impact * 15 +
  feasibility_score
}

///|
fn recovery_candidate_id(
  train_id : String,
  action : RecoveryAction,
  target_station_id : String?,
) -> String {
  let station = match target_station_id {
    Some(value) => value
    None => "line"
  }
  "recovery:\{train_id}:\{action.label()}:\{station}"
}

///|
fn recovery_prerequisites(action : RecoveryAction) -> Array[String] {
  match action {
    HoldAtStation =>
      [
        "route remains protected", "platform and following headway remain available",
      ]
    UseRunningMargin =>
      [
        "declared maximum running time is not exceeded", "speed authority remains unchanged",
      ]
    SkipStation =>
      [
        "passenger information is issued", "station is not a protected transfer commitment",
      ]
    ShortTurn =>
      [
        "turnback route is available", "affected passengers receive an alternative service",
      ]
    ManualReview =>
      [
        "operator confirms the train identity", "operator confirms the current route state",
      ]
  }
}

///|
fn recovery_explanation_for_action(
  action : RecoveryAction,
  target_station_id : String?,
) -> String {
  let station = recovery_station_label(target_station_id)
  match action {
    HoldAtStation => "hold at " + station + " to protect the following headway"
    SkipStation => "skip " + station + " to recover passenger dwell"
    UseRunningMargin =>
      "use declared running-time margin before the constrained section"
    ShortTurn =>
      "turn back at " + station + " to preserve the remaining service pattern"
    ManualReview => "position or timetable evidence requires manual review"
  }
}

///|
fn recovery_station_label(station_id : String?) -> String {
  match station_id {
    Some(value) => value
    None => "-"
  }
}

///|
fn limit_candidates(
  candidates : Array[RecoveryCandidate],
  limit : Int,
) -> Array[RecoveryCandidate] {
  if candidates.length() <= limit {
    candidates
  } else {
    let output = []
    for i in 0..<limit {
      output.push(candidates[i])
    }
    output
  }
}

///|
fn total_recovery_delay(runtimes : Array[TrainRuntime]) -> Int {
  runtimes.fold(init=0, fn(total, runtime) {
    total + max_int(0, runtime.delay_min)
  })
}

///|
fn recovery_gate(
  initial_conflicts : Int,
  projected_conflicts : Int,
  selected_count : Int,
  candidate_count : Int,
) -> RecoveryGate {
  if candidate_count == 0 {
    Blocked
  } else if projected_conflicts > initial_conflicts {
    Blocked
  } else if selected_count == 0 {
    Review
  } else {
    Ready
  }
}

///|
fn recovery_explanation(
  gate : RecoveryGate,
  initial_delay : Int,
  projected_delay : Int,
  initial_conflicts : Int,
  projected_conflicts : Int,
) -> String {
  if gate == Blocked {
    "no safe recovery selection was produced within the policy limits"
  } else if gate == Review {
    "candidates exist but none passed the selection gate; operator review is required"
  } else {
    "selected recovery reduces delay from \{initial_delay} to \{projected_delay} minutes and conflicts from \{initial_conflicts} to \{projected_conflicts}"
  }
}

///|
fn recovery_metric(
  builder : StringBuilder,
  name : String,
  value : String,
) -> Unit {
  builder <+ "| \{name} | \{value} |\n"
}
