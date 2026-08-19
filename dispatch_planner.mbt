///|
/// Objective used by the rolling-horizon dispatcher.
pub(all) enum PlanningObjective {
  ProtectHeadway
  MinimizeDelay
  ProtectPriority
  Balanced
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Weights are deliberately integer-valued so a plan is reproducible across
/// MoonBit backends and can be explained in an audit record.
pub(all) struct DispatchWeights {
  conflict_weight : Int
  delay_weight : Int
  priority_weight : Int
  passenger_weight : Int
  objective : PlanningObjective
} derive(Debug, Eq, ToJson, FromJson)

///|
/// One selected or rejected candidate in a rolling plan.
pub(all) struct PlanItem {
  conflict_id : String
  train_id : String
  action : DispatchAction
  before_conflict_count : Int
  after_conflict_count : Int
  score : Int
  selected : Bool
  reason : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A bounded plan result. It is a recommendation artifact, never a control
/// command, and keeps rejected candidates for operator review.
pub(all) struct RollingPlan {
  schedule_id : String
  at_min : Int
  horizon_min : Int
  objective : PlanningObjective
  initial_conflict_count : Int
  predicted_conflict_count : Int
  initial_cost : Int
  predicted_cost : Int
  selected_count : Int
  items : Array[PlanItem]
  feasible : Bool
  explanation : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn default_dispatch_weights() -> DispatchWeights {
  {
    conflict_weight: 100,
    delay_weight: 5,
    priority_weight: 3,
    passenger_weight: 2,
    objective: Balanced,
  }
}

///|
pub fn planning_objective_label(objective : PlanningObjective) -> String {
  match objective {
    ProtectHeadway => "protect_headway"
    MinimizeDelay => "minimize_delay"
    ProtectPriority => "protect_priority"
    Balanced => "balanced"
  }
}

///|
/// Construct a rolling plan from current realtime state. Candidates are
/// evaluated one at a time and accepted only when they reduce the weighted
/// cost or provide a safe resolution for a critical conflict.
pub fn build_rolling_plan(
  schedule : Schedule,
  runtimes : Array[TrainRuntime],
  at_min : Int,
  horizon_min? : Int = 30,
  weights? : DispatchWeights = default_dispatch_weights(),
) -> RollingPlan {
  let horizon = max_int(1, horizon_min)
  let initial_conflicts = detect_realtime_conflicts(schedule, runtimes)
  let initial_cost = rolling_cost(
    schedule, initial_conflicts, runtimes, weights,
  )
  let recommendations = suggest_dispatches(
    schedule, initial_conflicts, runtimes,
  )
  let items = []
  let selected_trains = []
  let mut working_schedule = schedule
  let mut predicted_conflicts = initial_conflicts
  let mut predicted_cost = initial_cost
  for recommendation in recommendations {
    let action = recommendation.primary
    let before_count = predicted_conflicts.length()
    let candidate_schedule = apply_dispatch_action(working_schedule, action)
    let candidate_conflicts = detect_realtime_conflicts(
      candidate_schedule, runtimes,
    )
    let candidate_cost = rolling_cost(
      candidate_schedule, candidate_conflicts, runtimes, weights,
    )
    let duplicate_train = selected_trains.contains(action.train_id)
    let improves = candidate_cost < predicted_cost
    let resolves_critical = before_count > 0 &&
      candidate_conflicts.length() < before_count &&
      action.safe
    let selected = !duplicate_train && (improves || resolves_critical)
    if selected {
      selected_trains.push(action.train_id)
      working_schedule = candidate_schedule
      predicted_conflicts = candidate_conflicts
      predicted_cost = candidate_cost
    }
    items.push({
      conflict_id: recommendation.conflict_id,
      train_id: action.train_id,
      action,
      before_conflict_count: before_count,
      after_conflict_count: candidate_conflicts.length(),
      score: candidate_cost,
      selected,
      reason: plan_item_reason(
        selected, duplicate_train, improves, resolves_critical,
      ),
    })
  }
  {
    schedule_id: schedule.id,
    at_min,
    horizon_min: horizon,
    objective: weights.objective,
    initial_conflict_count: initial_conflicts.length(),
    predicted_conflict_count: predicted_conflicts.length(),
    initial_cost,
    predicted_cost,
    selected_count: selected_trains.length(),
    items,
    feasible: predicted_conflicts.length() <= initial_conflicts.length(),
    explanation: rolling_explanation(
      initial_conflicts,
      predicted_conflicts,
      selected_trains.length(),
    ),
  }
}

///|
/// Re-score a plan against a different policy without changing selected
/// actions. This is useful when a control room changes priorities at runtime.
pub fn rescore_rolling_plan(
  schedule : Schedule,
  plan : RollingPlan,
  runtimes : Array[TrainRuntime],
  weights : DispatchWeights,
) -> RollingPlan {
  let initial_conflicts = detect_realtime_conflicts(schedule, runtimes)
  let mut working = schedule
  let items = []
  for item in plan.items {
    if item.selected {
      working = apply_dispatch_action(working, item.action)
    }
    let conflicts = detect_realtime_conflicts(working, runtimes)
    items.push({
      conflict_id: item.conflict_id,
      train_id: item.train_id,
      action: item.action,
      before_conflict_count: item.before_conflict_count,
      after_conflict_count: conflicts.length(),
      score: rolling_cost(working, conflicts, runtimes, weights),
      selected: item.selected,
      reason: item.reason,
    })
  }
  let final_conflicts = detect_realtime_conflicts(working, runtimes)
  {
    schedule_id: plan.schedule_id,
    at_min: plan.at_min,
    horizon_min: plan.horizon_min,
    objective: weights.objective,
    initial_conflict_count: initial_conflicts.length(),
    predicted_conflict_count: final_conflicts.length(),
    initial_cost: rolling_cost(schedule, initial_conflicts, runtimes, weights),
    predicted_cost: rolling_cost(working, final_conflicts, runtimes, weights),
    selected_count: plan.selected_count,
    items,
    feasible: final_conflicts.length() <= initial_conflicts.length(),
    explanation: rolling_explanation(
      initial_conflicts,
      final_conflicts,
      plan.selected_count,
    ),
  }
}

///|
pub fn selected_plan_items(plan : RollingPlan) -> Array[PlanItem] {
  plan.items.filter(fn(item) { item.selected })
}

///|
pub fn rolling_plan_json(plan : RollingPlan) -> String {
  plan.to_json().stringify()
}

///|
pub fn rolling_plan_markdown(plan : RollingPlan) -> String {
  let builder = StringBuilder()
  builder <+ "# Rolling dispatch plan\n\n"
  builder <+ "- Schedule: \{plan.schedule_id}\n"
  builder <+ "- At: \{format_clock(plan.at_min)}\n"
  builder <+ "- Horizon: \{plan.horizon_min} min\n"
  builder <+ "- Objective: \{planning_objective_label(plan.objective)}\n"
  builder <+
    "- Conflicts: \{plan.initial_conflict_count} -> \{plan.predicted_conflict_count}\n"
  builder <+ "- Cost: \{plan.initial_cost} -> \{plan.predicted_cost}\n"
  builder <+ "- Feasible: \{plan.feasible}\n\n"
  builder <+
    "| Selected | Train | Action | Conflict | Before | After | Score | Reason |\n|---|---|---|---|---:|---:|---:|---|\n"
  for item in plan.items {
    builder <+
      "| \{item.selected} | \{item.train_id} | \{item.action.kind.label()} | \{item.conflict_id} | \{item.before_conflict_count} | \{item.after_conflict_count} | \{item.score} | \{item.reason} |\n"
  }
  builder <+ "\n{plan.explanation}\n"
  builder.to_string()
}

///|
pub fn rolling_plan_score(plan : RollingPlan) -> Int {
  plan.initial_cost - plan.predicted_cost
}

///|
fn rolling_cost(
  schedule : Schedule,
  conflicts : Array[Conflict],
  runtimes : Array[TrainRuntime],
  weights : DispatchWeights,
) -> Int {
  let conflict_cost = conflicts.fold(init=0, fn(total, conflict) {
    total + weights.conflict_weight * severity_cost(conflict.severity)
  })
  let delay_cost = runtimes.fold(init=0, fn(total, runtime) {
    total + max_int(0, runtime.delay_min) * weights.delay_weight
  })
  let priority_cost = schedule.trains.fold(init=0, fn(total, train) {
    let runtime = runtime_for_plan(runtimes, train.id)
    match runtime {
      Some(value) =>
        total +
        max_int(0, value.delay_min) *
        max_int(0, train.priority) *
        weights.priority_weight
      None => total
    }
  })
  match weights.objective {
    ProtectHeadway => conflict_cost + priority_cost / 2
    MinimizeDelay => delay_cost + conflict_cost / 2
    ProtectPriority => priority_cost + conflict_cost / 2
    Balanced => conflict_cost + delay_cost + priority_cost / 3
  }
}

///|
fn runtime_for_plan(
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
fn severity_cost(severity : String) -> Int {
  match severity {
    "critical" => 8
    "high" => 5
    "medium" => 3
    "low" => 1
    _ => 2
  }
}

///|
fn plan_item_reason(
  selected : Bool,
  duplicate_train : Bool,
  improves : Bool,
  resolves_critical : Bool,
) -> String {
  if selected && resolves_critical {
    "selected because it reduces the current conflict set"
  } else if selected && improves {
    "selected because weighted cost improves"
  } else if duplicate_train {
    "rejected because the train already has a selected action"
  } else {
    "retained as an operator-visible alternative"
  }
}

///|
fn rolling_explanation(
  before : Array[Conflict],
  after : Array[Conflict],
  selected_count : Int,
) -> String {
  if after.length() < before.length() {
    "\{selected_count} bounded action(s) reduce the detected conflict count"
  } else if after.length() == before.length() {
    "the plan preserves the current conflict count and requires operator review"
  } else {
    "the candidate plan increases conflicts and is not safe to apply"
  }
}
