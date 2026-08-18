///|
/// Bounds used by the advisory policy. The policy is intentionally explicit
/// and serializable so dispatchers can review or version it with a timetable.
pub(all) struct DispatchPolicy {
  max_hold_min : Int
  min_headway_buffer_min : Int
  max_skip_count : Int
  allow_skip : Bool
  allow_speedup : Bool
  allow_slowdown : Bool
  policy_version : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn default_dispatch_policy() -> DispatchPolicy {
  {
    max_hold_min: 8,
    min_headway_buffer_min: 1,
    max_skip_count: 1,
    allow_skip: true,
    allow_speedup: true,
    allow_slowdown: true,
    policy_version: "headway-greedy-v1",
  }
}

///|
/// Produce explainable candidates for every conflict. No candidate is
/// returned as safe unless it passes the policy and timetable constraints.
pub fn suggest_dispatches(
  schedule : Schedule,
  conflicts : Array[Conflict],
  runtimes : Array[TrainRuntime],
  policy? : DispatchPolicy = default_dispatch_policy(),
) -> Array[DispatchRecommendation] {
  let output = []
  for conflict in conflicts {
    let candidates = candidate_actions(schedule, conflict, runtimes, policy)
    let ranked = rank_actions(candidates)
    if ranked.length() == 0 {
      output.push(fallback_recommendation(conflict, policy))
    } else {
      let primary = ranked[0]
      let alternatives = if ranked.length() > 1 {
        ranked[1:].to_owned()
      } else {
        []
      }
      output.push({
        conflict_id: conflict.id,
        primary,
        alternatives,
        expected_recovery_min: expected_recovery(primary),
        impact_summary: action_impact_summary(primary, conflict),
        policy_version: policy.policy_version,
      })
    }
  }
  output
}

///|
fn candidate_actions(
  schedule : Schedule,
  conflict : Conflict,
  runtimes : Array[TrainRuntime],
  policy : DispatchPolicy,
) -> Array[DispatchAction] {
  let actions = []
  let target = action_train_id(schedule, conflict, runtimes)
  let station = conflict_station(schedule, conflict, target)
  let hold_delta = max_int(
    1,
    conflict.required_separation_min -
    conflict.actual_separation_min +
    policy.min_headway_buffer_min,
  )
  let hold_safe = hold_delta <= policy.max_hold_min && target != ""
  actions.push({
    kind: Hold,
    train_id: target,
    station_id: station,
    resource_id: Some(conflict.resource_id),
    delta_min: hold_delta,
    score: if hold_safe {
      100 - hold_delta * 3
    } else {
      0
    },
    safe: hold_safe,
    reason: "hold the following or lower-priority movement to restore separation",
    prerequisites: [
      "dispatcher confirms route protection", "station/platform remains available",
    ],
  })
  let slowdown_safe = policy.allow_slowdown && target != ""
  let slowdown_delta = clamp_int(hold_delta / 2, 1, 4)
  actions.push({
    kind: SlowDown,
    train_id: target,
    station_id: station,
    resource_id: Some(conflict.resource_id),
    delta_min: slowdown_delta,
    score: if slowdown_safe {
      78 - slowdown_delta * 2
    } else {
      0
    },
    safe: slowdown_safe,
    reason: "use available running-time margin before the constrained resource",
    prerequisites: ["driver or ATO accepts a bounded speed profile"],
  })
  let speedup_safe = policy.allow_speedup &&
    has_run_time_margin(schedule, target)
  actions.push({
    kind: SpeedUp,
    train_id: target,
    station_id: station,
    resource_id: Some(conflict.resource_id),
    delta_min: -1,
    score: if speedup_safe {
      65
    } else {
      0
    },
    safe: speedup_safe,
    reason: "recover one minute using declared maximum running-time margin",
    prerequisites: [
      "line speed authority is unchanged", "no passenger stop is removed",
    ],
  })
  let skip_station = skippable_station(schedule, target, conflict)
  let skip_safe = policy.allow_skip && skip_station is Some(_)
  actions.push({
    kind: Skip,
    train_id: target,
    station_id: skip_station,
    resource_id: Some(conflict.resource_id),
    delta_min: -2,
    score: if skip_safe {
      55
    } else {
      0
    },
    safe: skip_safe,
    reason: "skip one non-terminal stop to recover dwell and running margin",
    prerequisites: [
      "passenger information is issued", "station is not a transfer commitment",
    ],
  })
  if conflict.kind is RouteConflict {
    actions.push({
      kind: ManualReview,
      train_id: target,
      station_id: station,
      resource_id: Some(conflict.resource_id),
      delta_min: 0,
      score: 90,
      safe: true,
      reason: "route conflict requires interlocking-aware dispatcher confirmation",
      prerequisites: ["review route locking and release indications"],
    })
  }
  actions.filter(fn(action) { action.safe })
}

///|
fn action_train_id(
  schedule : Schedule,
  conflict : Conflict,
  runtimes : Array[TrainRuntime],
) -> String {
  let first = schedule.train_by_id(conflict.first_train_id)
  let second = schedule.train_by_id(conflict.second_train_id)
  match (first, second) {
    (Some(first_train), Some(second_train)) =>
      if first_train.priority < second_train.priority {
        first_train.id
      } else if second_train.priority < first_train.priority {
        second_train.id
      } else {
        let first_delay = runtime_delay_for_train(first_train.id, runtimes)
        let second_delay = runtime_delay_for_train(second_train.id, runtimes)
        if second_delay > first_delay {
          second_train.id
        } else {
          conflict.second_train_id
        }
      }
    (Some(_), None) => conflict.first_train_id
    (None, Some(_)) => conflict.second_train_id
    _ => conflict.second_train_id
  }
}

///|
fn runtime_delay_for_train(
  train_id : String,
  runtimes : Array[TrainRuntime],
) -> Int {
  for runtime in runtimes {
    if runtime.train_id == train_id {
      return runtime.delay_min
    }
  }
  0
}

///|
fn conflict_station(
  schedule : Schedule,
  conflict : Conflict,
  train_id : String,
) -> String? {
  match schedule.train_by_id(train_id) {
    Some(train) => {
      let mut found : String? = None
      for stop in train.stops {
        if found is None && stop.departure_min >= conflict.start_min {
          found = Some(stop.station_id)
        }
      }
      found
    }
    None => None
  }
}

///|
fn has_run_time_margin(schedule : Schedule, train_id : String) -> Bool {
  match schedule.train_by_id(train_id) {
    Some(train) => {
      let mut has_margin = false
      for i in 0..<(train.stops.length() - 1) {
        let from_stop = train.stops[i]
        let to_stop = train.stops[i + 1]
        match find_segment(schedule, from_stop.station_id, to_stop.station_id) {
          Some(segment) =>
            if segment.max_run_min > segment.scheduled_run_min {
              has_margin = true
            }
          None => ()
        }
      }
      has_margin
    }
    None => false
  }
}

///|
fn skippable_station(
  schedule : Schedule,
  train_id : String,
  conflict : Conflict,
) -> String? {
  match schedule.train_by_id(train_id) {
    Some(train) =>
      if train.stops.length() <= 2 {
        None
      } else {
        for i in 1..<(train.stops.length() - 1) {
          let stop = train.stops[i]
          if stop.arrival_min >= conflict.start_min &&
            stop.stop_kind != "terminal" &&
            stop.stop_kind != "transfer" &&
            stop.stop_kind != "pass" {
            return Some(stop.station_id)
          }
        }
        None
      }
    None => None
  }
}

///|
fn rank_actions(actions : Array[DispatchAction]) -> Array[DispatchAction] {
  let output = []
  for action in actions {
    let mut inserted = false
    for i in 0..<output.length() {
      if !inserted && action_before(action, output[i]) {
        output.insert(i, action)
        inserted = true
      }
    }
    if !inserted {
      output.push(action)
    }
  }
  output
}

///|
fn action_before(first : DispatchAction, second : DispatchAction) -> Bool {
  first.score > second.score ||
  (
    first.score == second.score &&
    action_rank(first.kind) < action_rank(second.kind)
  )
}

///|
fn expected_recovery(action : DispatchAction) -> Int {
  match action.kind {
    Hold => action.delta_min
    SlowDown => action.delta_min / 2
    SpeedUp => 1
    Skip => 2
    KeepPlan | ManualReview => 0
  }
}

///|
fn action_impact_summary(
  action : DispatchAction,
  conflict : Conflict,
) -> String {
  "\{action.kind.label()} \{action.train_id} at \{conflict.resource_id}: \{action.reason}"
}

///|
fn fallback_recommendation(
  conflict : Conflict,
  policy : DispatchPolicy,
) -> DispatchRecommendation {
  let primary : DispatchAction = {
    kind: ManualReview,
    train_id: conflict.second_train_id,
    station_id: None,
    resource_id: Some(conflict.resource_id),
    delta_min: 0,
    score: 10,
    safe: true,
    reason: "no bounded automatic candidate passed the safety policy",
    prerequisites: ["dispatcher reviews the complete movement graph"],
  }
  {
    conflict_id: conflict.id,
    primary,
    alternatives: [],
    expected_recovery_min: 0,
    impact_summary: "manual review required",
    policy_version: policy.policy_version,
  }
}

///|
/// Apply one recommendation to a copy of the schedule. This is intended for
/// scenario preview and tests; an OCC integration must still approve the
/// resulting plan before it reaches a control system.
pub fn apply_dispatch_action(
  schedule : Schedule,
  action : DispatchAction,
) -> Schedule {
  let trains = []
  for train in schedule.trains {
    if train.id != action.train_id {
      trains.push(train)
    } else {
      trains.push(apply_action_to_train(train, action))
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
    version: schedule.version + 1,
    notes: schedule.notes + " | dispatch preview: " + action.kind.label(),
  }
}

///|
fn apply_action_to_train(train : Train, action : DispatchAction) -> Train {
  match action.kind {
    Hold | SlowDown => shift_train(train, action.delta_min)
    SpeedUp => shift_train(train, action.delta_min)
    Skip =>
      match action.station_id {
        Some(station_id) => remove_stop(train, station_id)
        None => train
      }
    KeepPlan | ManualReview => train
  }
}

///|
fn remove_stop(train : Train, station_id : String) -> Train {
  let stops = []
  for stop in train.stops {
    if stop.station_id != station_id {
      stops.push(stop)
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
    notes: train.notes + " | skipped " + station_id,
  }
}

///|
pub fn recommendation_summary(
  recommendations : Array[DispatchRecommendation],
) -> String {
  if recommendations.length() == 0 {
    return "no dispatch recommendations"
  }
  let mut holds = 0
  let mut skips = 0
  let mut reviews = 0
  for recommendation in recommendations {
    match recommendation.primary.kind {
      Hold => holds += 1
      Skip => skips += 1
      ManualReview => reviews += 1
      _ => ()
    }
  }
  "\{recommendations.length()} recommendation(s): hold=\{holds}, skip=\{skips}, manual_review=\{reviews}"
}
