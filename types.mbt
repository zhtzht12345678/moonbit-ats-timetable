///|
/// Travel direction used by a timetable. `Loop` is useful for circular lines
/// where an external route identifier is required to disambiguate movement.
pub(all) enum Direction {
  Up
  Down
  Loop
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Operational state of a train at the time a snapshot is taken.
pub(all) enum TrainMode {
  Planned
  Running
  Holding
  Skipping
  Finished
  Cancelled
  Unknown
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A station position in metres from the line origin.
pub(all) struct Station {
  id : String
  name : String
  distance_m : Int
  platform_count : Int
  is_interchange : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Static constraints for one adjacent pair of stations.
pub(all) struct LineSegment {
  id : String
  from_station : String
  to_station : String
  distance_m : Int
  min_run_min : Int
  scheduled_run_min : Int
  max_run_min : Int
  headway_min : Int
  throat_resource : String?
} derive(Debug, Eq, ToJson, FromJson)

///|
/// One scheduled stop or pass-through point for a train.
pub(all) struct StopTime {
  station_id : String
  arrival_min : Int
  departure_min : Int
  platform : Int
  stop_kind : String
  minimum_dwell_min : Int
  passenger_dwell_min : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A train movement described by its ordered station calls.
pub(all) struct Train {
  id : String
  service_name : String
  direction : Direction
  priority : Int
  length_m : Int
  max_speed_kmh : Int
  stops : Array[StopTime]
  notes : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// An interlocking or throat reservation attached to a train path.
pub(all) struct RouteReservation {
  id : String
  train_id : String
  resource_id : String
  entry_min : Int
  exit_min : Int
  release_margin_min : Int
  route_name : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A complete, exchangeable operating plan.
pub(all) struct Schedule {
  id : String
  service_date : String
  timezone : String
  line_name : String
  stations : Array[Station]
  segments : Array[LineSegment]
  trains : Array[Train]
  reservations : Array[RouteReservation]
  version : Int
  notes : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A single structured validation result. Validation is deliberately data
/// oriented so an OCC adapter can show all problems in one screen.
pub(all) struct ValidationIssue {
  code : String
  severity : String
  path : String
  message : String
  hint : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Error class emitted by the safety checker.
pub(all) enum ConflictKind {
  HeadwayConflict
  PlatformConflict
  RouteConflict
  InvalidGeometry
  StaleTelemetry
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A normalized conflict between two scheduled or observed movements.
pub(all) struct Conflict {
  id : String
  kind : ConflictKind
  severity : String
  resource_id : String
  first_train_id : String
  second_train_id : String
  start_min : Int
  end_min : Int
  required_separation_min : Int
  actual_separation_min : Int
  message : String
  evidence : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A timestamped observation from an ATS/TMS adapter.
pub(all) struct TelemetryEvent {
  event_id : String
  train_id : String
  observed_min : Int
  station_id : String?
  position_m : Int
  delay_min : Int
  speed_kmh : Int
  mode : TrainMode
  source : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Latest known runtime state for one train.
pub(all) struct TrainRuntime {
  train_id : String
  observed_min : Int
  station_id : String?
  position_m : Int
  delay_min : Int
  speed_kmh : Int
  mode : TrainMode
  source : String
  event_count : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Action category suggested to the dispatcher. Suggestions never directly
/// actuate a train or signalling system.
pub(all) enum ActionKind {
  Hold
  Skip
  SpeedUp
  SlowDown
  KeepPlan
  ManualReview
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A candidate dispatch operation with explicit operational guardrails.
pub(all) struct DispatchAction {
  kind : ActionKind
  train_id : String
  station_id : String?
  resource_id : String?
  delta_min : Int
  score : Int
  safe : Bool
  reason : String
  prerequisites : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
/// The selected action plus alternatives retained for an auditable decision.
pub(all) struct DispatchRecommendation {
  conflict_id : String
  primary : DispatchAction
  alternatives : Array[DispatchAction]
  expected_recovery_min : Int
  impact_summary : String
  policy_version : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Monitor alert severity and category.
pub(all) enum AlertKind {
  DelayGrowth
  StaleData
  PositionJump
  UnknownTrain
  Recovered
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A monitor alert generated while merging telemetry.
pub(all) struct MonitorAlert {
  id : String
  kind : AlertKind
  train_id : String
  at_min : Int
  severity : String
  message : String
  acknowledged : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Stable read model consumed by a dashboard or an event stream publisher.
pub(all) struct MonitorSnapshot {
  schedule_id : String
  at_min : Int
  runtimes : Array[TrainRuntime]
  alerts : Array[MonitorAlert]
  telemetry_count : Int
  stale_after_min : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A line segment in String Diagram coordinates.
pub(all) struct DiagramLine {
  train_id : String
  service_name : String
  direction : Direction
  points : Array[DiagramPoint]
  color : String
  status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A station label in the diagram coordinate system.
pub(all) struct DiagramStation {
  station_id : String
  label : String
  distance_m : Int
  order : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A compact point list makes the JSON renderer usable by Canvas, SVG, or
/// a custom WebGL front end without prescribing a browser framework.
pub(all) struct DiagramPoint {
  time_min : Int
  distance_m : Int
  station_id : String
  delay_min : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
/// JSON-friendly representation of a complete diagram frame.
pub(all) struct DiagramFrame {
  schedule_id : String
  service_date : String
  start_min : Int
  end_min : Int
  stations : Array[DiagramStation]
  lines : Array[DiagramLine]
  conflicts : Array[Conflict]
  generated_at : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Rendering controls shared by JSON and SVG adapters.
pub(all) struct RenderOptions {
  start_min : Int
  end_min : Int
  include_finished : Bool
  include_conflicts : Bool
  scale_time : Int
  scale_distance : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A deterministic simulation sample used by examples and regression tests.
pub(all) struct SimulationStep {
  at_min : Int
  runtimes : Array[TrainRuntime]
  conflicts : Array[Conflict]
  recommendations : Array[DispatchRecommendation]
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A complete replay result.
pub(all) struct SimulationReport {
  schedule_id : String
  steps : Array[SimulationStep]
  conflict_count : Int
  recommendation_count : Int
  peak_delay_min : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn station(
  id~ : String,
  name~ : String,
  distance_m~ : Int,
  platform_count? : Int = 2,
  is_interchange? : Bool = false,
) -> Station {
  { id, name, distance_m, platform_count, is_interchange }
}

///|
pub fn segment(
  id~ : String,
  from_station~ : String,
  to_station~ : String,
  distance_m~ : Int,
  min_run_min~ : Int,
  scheduled_run_min~ : Int,
  max_run_min~ : Int,
  headway_min~ : Int,
  throat_resource? : String? = None,
) -> LineSegment {
  {
    id,
    from_station,
    to_station,
    distance_m,
    min_run_min,
    scheduled_run_min,
    max_run_min,
    headway_min,
    throat_resource,
  }
}

///|
pub fn stop_time(
  station_id~ : String,
  arrival_min~ : Int,
  departure_min~ : Int,
  platform? : Int = 1,
  stop_kind? : String = "normal",
  minimum_dwell_min? : Int = 1,
  passenger_dwell_min? : Int = 1,
) -> StopTime {
  {
    station_id,
    arrival_min,
    departure_min,
    platform,
    stop_kind,
    minimum_dwell_min,
    passenger_dwell_min,
  }
}

///|
pub fn train(
  id~ : String,
  service_name~ : String,
  direction~ : Direction,
  stops~ : Array[StopTime],
  priority? : Int = 5,
  length_m? : Int = 120,
  max_speed_kmh? : Int = 80,
  notes? : String = "",
) -> Train {
  {
    id,
    service_name,
    direction,
    priority,
    length_m,
    max_speed_kmh,
    stops,
    notes,
  }
}

///|
pub fn route_reservation(
  id~ : String,
  train_id~ : String,
  resource_id~ : String,
  entry_min~ : Int,
  exit_min~ : Int,
  release_margin_min? : Int = 1,
  route_name? : String = "",
) -> RouteReservation {
  {
    id,
    train_id,
    resource_id,
    entry_min,
    exit_min,
    release_margin_min,
    route_name,
  }
}

///|
pub fn schedule(
  id~ : String,
  service_date~ : String,
  line_name~ : String,
  stations~ : Array[Station],
  segments~ : Array[LineSegment],
  trains~ : Array[Train],
  reservations? : Array[RouteReservation] = [],
  timezone? : String = "Asia/Shanghai",
  version? : Int = 1,
  notes? : String = "",
) -> Schedule {
  {
    id,
    service_date,
    timezone,
    line_name,
    stations,
    segments,
    trains,
    reservations,
    version,
    notes,
  }
}

///|
pub fn telemetry(
  event_id~ : String,
  train_id~ : String,
  observed_min~ : Int,
  position_m~ : Int,
  delay_min~ : Int,
  mode~ : TrainMode,
  station_id? : String? = None,
  speed_kmh? : Int = 0,
  source? : String = "simulator",
) -> TelemetryEvent {
  {
    event_id,
    train_id,
    observed_min,
    station_id,
    position_m,
    delay_min,
    speed_kmh,
    mode,
    source,
  }
}

///|
pub fn render_options(
  start_min~ : Int,
  end_min~ : Int,
  include_finished? : Bool = true,
  include_conflicts? : Bool = true,
  scale_time? : Int = 4,
  scale_distance? : Int = 1,
) -> RenderOptions {
  {
    start_min,
    end_min,
    include_finished,
    include_conflicts,
    scale_time,
    scale_distance,
  }
}

///|
pub fn Station::is_valid(self : Station) -> Bool {
  self.id.trim() != "" &&
  self.name.trim() != "" &&
  self.distance_m >= 0 &&
  self.platform_count > 0
}

///|
pub fn StopTime::is_dwell_valid(self : StopTime) -> Bool {
  self.arrival_min >= 0 &&
  self.departure_min >= self.arrival_min &&
  self.platform > 0 &&
  self.minimum_dwell_min >= 0 &&
  self.passenger_dwell_min >= 0
}

///|
pub fn LineSegment::is_valid(self : LineSegment) -> Bool {
  self.distance_m > 0 &&
  self.min_run_min > 0 &&
  self.scheduled_run_min >= self.min_run_min &&
  self.max_run_min >= self.scheduled_run_min &&
  self.headway_min > 0
}

///|
pub fn Train::first_time(self : Train) -> Int? {
  self.stops.get(0).map(fn(stop) { stop.departure_min })
}

///|
pub fn Train::last_time(self : Train) -> Int? {
  self.stops.get(self.stops.length() - 1).map(fn(stop) { stop.arrival_min })
}

///|
pub fn Schedule::station_by_id(self : Schedule, id : String) -> Station? {
  for station in self.stations {
    if station.id == id {
      return Some(station)
    }
  }
  None
}

///|
pub fn Schedule::train_by_id(self : Schedule, id : String) -> Train? {
  for train in self.trains {
    if train.id == id {
      return Some(train)
    }
  }
  None
}

///|
pub fn Direction::label(self : Direction) -> String {
  match self {
    Up => "up"
    Down => "down"
    Loop => "loop"
  }
}

///|
pub fn TrainMode::label(self : TrainMode) -> String {
  match self {
    Planned => "planned"
    Running => "running"
    Holding => "holding"
    Skipping => "skipping"
    Finished => "finished"
    Cancelled => "cancelled"
    Unknown => "unknown"
  }
}

///|
pub fn ActionKind::label(self : ActionKind) -> String {
  match self {
    Hold => "hold"
    Skip => "skip"
    SpeedUp => "speed_up"
    SlowDown => "slow_down"
    KeepPlan => "keep_plan"
    ManualReview => "manual_review"
  }
}
