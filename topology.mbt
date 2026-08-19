///|
/// Search objective for a route-feasibility query.
pub(all) enum RouteObjective {
  MinimumRunTime
  MinimumDistance
  MinimumHops
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Explicit topology constraints used by a temporary route or turnback
/// planner. The lists are data-boundary values and do not mutate `Schedule`.
pub(all) struct RouteConstraint {
  avoid_stations : Array[String]
  avoid_segments : Array[String]
  maximum_hops : Int
  objective : RouteObjective
} derive(Debug, Eq, ToJson, FromJson)

///|
/// One directed traversal in a selected station path.
pub(all) struct PathLeg {
  segment_id : String
  from_station : String
  to_station : String
  run_min : Int
  distance_m : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A path result with enough information for display and dispatch scoring.
pub(all) struct StationPath {
  origin : String
  destination : String
  stations : Array[String]
  legs : Array[PathLeg]
  total_run_min : Int
  total_distance_m : Int
  feasible : Bool
  reason : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A path request that can be recorded alongside a dispatch or incident
/// decision.
pub(all) struct RoutePlan {
  request_id : String
  path : StationPath
  requested_at_min : Int
  reserve_margin_min : Int
  resource_ids : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Internal search state. The implementation is intentionally small and
/// deterministic so it can run in wasm and native without a graph dependency.
priv struct PathState {
  station_id : String
  stations : Array[String]
  legs : Array[PathLeg]
  cost : Int
  distance_m : Int
}

///|
/// Construct a route constraint with safe defaults.
pub fn route_constraint(
  avoid_stations? : Array[String] = [],
  avoid_segments? : Array[String] = [],
  maximum_hops? : Int = 64,
  objective? : RouteObjective = MinimumRunTime,
) -> RouteConstraint {
  {
    avoid_stations,
    avoid_segments,
    maximum_hops: max_int(1, maximum_hops),
    objective,
  }
}

///|
/// Find a deterministic route between two stations. The algorithm uses a
/// label-correcting queue rather than recursion, so malformed or cyclic
/// topology cannot overflow the call stack.
pub fn find_station_path(
  schedule : Schedule,
  origin : String,
  destination : String,
  constraint? : RouteConstraint = route_constraint(),
) -> StationPath {
  if schedule.station_by_id(origin) is None {
    return empty_path(origin, destination, "origin station is unknown")
  }
  if schedule.station_by_id(destination) is None {
    return empty_path(origin, destination, "destination station is unknown")
  }
  if constraint.avoid_stations.contains(origin) {
    return empty_path(origin, destination, "origin station is blocked")
  }
  if constraint.avoid_stations.contains(destination) {
    return empty_path(origin, destination, "destination station is blocked")
  }
  if origin == destination {
    return {
      origin,
      destination,
      stations: [origin],
      legs: [],
      total_run_min: 0,
      total_distance_m: 0,
      feasible: true,
      reason: "origin equals destination",
    }
  }
  let open = [
    { station_id: origin, stations: [origin], legs: [], cost: 0, distance_m: 0 },
  ]
  let best_costs : Map[String, Int] = Map([])
  best_costs[origin] = 0
  while open.length() > 0 {
    let state = open.remove(best_state_index(open))
    if state.station_id == destination {
      return path_from_state(origin, destination, state)
    }
    if state.legs.length() >= constraint.maximum_hops {
      continue
    }
    for segment in schedule.segments {
      match next_leg(segment, state.station_id) {
        Some(leg) =>
          if !constraint.avoid_segments.contains(segment.id) &&
            !constraint.avoid_stations.contains(leg.to_station) &&
            !state.stations.contains(leg.to_station) {
            let next_cost = path_cost(leg, constraint.objective)
            let accumulated = state.cost + next_cost
            let should_add = match best_costs.get(leg.to_station) {
              Some(previous) => accumulated < previous
              None => true
            }
            if should_add {
              best_costs[leg.to_station] = accumulated
              let stations = state.stations.copy()
              stations.push(leg.to_station)
              let legs = state.legs.copy()
              legs.push(leg)
              open.push({
                station_id: leg.to_station,
                stations,
                legs,
                cost: accumulated,
                distance_m: state.distance_m + leg.distance_m,
              })
            }
          }
        None => ()
      }
    }
  }
  empty_path(origin, destination, "no route satisfies the topology constraints")
}

///|
/// Build a route plan and collect the route resources used by its legs.
pub fn make_route_plan(
  schedule : Schedule,
  request_id~ : String,
  origin~ : String,
  destination~ : String,
  requested_at_min~ : Int,
  reserve_margin_min? : Int = 1,
  constraint? : RouteConstraint = route_constraint(),
) -> RoutePlan {
  let path = find_station_path(schedule, origin, destination, constraint~)
  let resources = []
  for leg in path.legs {
    resources.push("segment:\{leg.segment_id}")
    for segment in schedule.segments {
      if segment.id == leg.segment_id &&
        segment.throat_resource is Some(resource) {
        resources.push("route:\{resource}")
      }
    }
  }
  {
    request_id,
    path,
    requested_at_min,
    reserve_margin_min: max_int(0, reserve_margin_min),
    resource_ids: unique_strings(resources),
  }
}

///|
/// Return all stations reachable from an origin under a bounded hop count.
pub fn reachable_stations(
  schedule : Schedule,
  origin : String,
  maximum_hops? : Int = 64,
) -> Array[String] {
  if schedule.station_by_id(origin) is None {
    return []
  }
  let seen = [origin]
  let queue = [(origin, 0)]
  let mut cursor = 0
  let limit = max_int(0, maximum_hops)
  while cursor < queue.length() {
    let (station_id, hops) = queue[cursor]
    cursor += 1
    if hops < limit {
      for segment in schedule.segments {
        match next_leg(segment, station_id) {
          Some(leg) =>
            if !seen.contains(leg.to_station) {
              seen.push(leg.to_station)
              queue.push((leg.to_station, hops + 1))
            }
          None => ()
        }
      }
    }
  }
  seen.sort()
  seen
}

///|
/// Check a route plan against schedule geometry and the requested time.
pub fn route_plan_is_safe(schedule : Schedule, plan : RoutePlan) -> Bool {
  if !plan.path.feasible || plan.path.legs.length() == 0 {
    return plan.path.origin == plan.path.destination
  }
  if plan.requested_at_min < 0 || plan.reserve_margin_min < 0 {
    return false
  }
  let conflicts = detect_conflicts(schedule)
  for conflict in conflicts {
    if conflict.start_min <= plan.requested_at_min + plan.path.total_run_min &&
      conflict.end_min >= plan.requested_at_min &&
      (
        plan.resource_ids.contains(conflict.resource_id) ||
        conflict.kind == RouteConflict
      ) {
      return false
    }
  }
  true
}

///|
pub fn StationPath::to_json_text(self : StationPath) -> String {
  self.to_json().stringify()
}

///|
pub fn RoutePlan::to_json_text(self : RoutePlan) -> String {
  self.to_json().stringify()
}

///|
pub fn route_plan_markdown(plan : RoutePlan, safe? : Bool = false) -> String {
  let builder = StringBuilder()
  builder <+ "# Route plan \{plan.request_id}\n\n"
  builder <+ "- Origin: \{plan.path.origin}\n"
  builder <+ "- Destination: \{plan.path.destination}\n"
  builder <+ "- Feasible: \{plan.path.feasible}\n"
  builder <+ "- Safe for requested window: \{safe}\n"
  builder <+ "- Run time: \{plan.path.total_run_min} min\n"
  builder <+ "- Distance: \{plan.path.total_distance_m} m\n"
  builder <+ "- Reason: \{plan.path.reason}\n\n"
  builder <+
    "| # | From | To | Segment | Run (min) | Distance (m) |\n|---:|---|---|---|---:|---:|\n"
  for i, leg in plan.path.legs {
    builder <+
      "| \{i} | \{leg.from_station} | \{leg.to_station} | \{leg.segment_id} | \{leg.run_min} | \{leg.distance_m} |\n"
  }
  builder.to_string()
}

///|
fn empty_path(
  origin : String,
  destination : String,
  reason : String,
) -> StationPath {
  {
    origin,
    destination,
    stations: [],
    legs: [],
    total_run_min: 0,
    total_distance_m: 0,
    feasible: false,
    reason,
  }
}

///|
fn path_from_state(
  origin : String,
  destination : String,
  state : PathState,
) -> StationPath {
  {
    origin,
    destination,
    stations: state.stations,
    legs: state.legs,
    total_run_min: state.legs.fold(init=0, fn(total, leg) {
      total + leg.run_min
    }),
    total_distance_m: state.distance_m,
    feasible: true,
    reason: "route found",
  }
}

///|
fn next_leg(segment : LineSegment, station_id : String) -> PathLeg? {
  if segment.from_station == station_id {
    Some({
      segment_id: segment.id,
      from_station: segment.from_station,
      to_station: segment.to_station,
      run_min: segment.scheduled_run_min,
      distance_m: segment.distance_m,
    })
  } else if segment.to_station == station_id {
    Some({
      segment_id: segment.id,
      from_station: segment.to_station,
      to_station: segment.from_station,
      run_min: segment.scheduled_run_min,
      distance_m: segment.distance_m,
    })
  } else {
    None
  }
}

///|
fn path_cost(leg : PathLeg, objective : RouteObjective) -> Int {
  match objective {
    MinimumRunTime => leg.run_min
    MinimumDistance => max_int(1, leg.distance_m / 100)
    MinimumHops => 1
  }
}

///|
fn best_state_index(states : Array[PathState]) -> Int {
  let mut best = 0
  for i in 1..<states.length() {
    if state_before(states[i], states[best]) {
      best = i
    }
  }
  best
}

///|
fn state_before(first : PathState, second : PathState) -> Bool {
  first.cost < second.cost ||
  (first.cost == second.cost && first.station_id < second.station_id)
}

///|
fn unique_strings(values : Array[String]) -> Array[String] {
  let output = []
  for value in values {
    if !output.contains(value) {
      output.push(value)
    }
  }
  output.sort()
  output
}
