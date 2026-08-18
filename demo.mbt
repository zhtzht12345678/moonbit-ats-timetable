///|
/// A compact but non-trivial metro line fixture used by the CLI, tests, and
/// documentation. The fixture is synthetic and contains no operational data.
pub fn demo_schedule() -> Schedule {
  let stations = [
    station(id="A", name="南环", distance_m=0, platform_count=2),
    station(id="B", name="科创园", distance_m=1200, platform_count=2),
    station(
      id="C",
      name="中央公园",
      distance_m=2400,
      platform_count=4,
      is_interchange=true,
    ),
    station(id="D", name="会展中心", distance_m=3600, platform_count=2),
    station(id="E", name="北港", distance_m=5000, platform_count=2),
  ]
  let segments = [
    segment(
      id="AB",
      from_station="A",
      to_station="B",
      distance_m=1200,
      min_run_min=2,
      scheduled_run_min=3,
      max_run_min=4,
      headway_min=3,
    ),
    segment(
      id="BC",
      from_station="B",
      to_station="C",
      distance_m=1200,
      min_run_min=3,
      scheduled_run_min=4,
      max_run_min=5,
      headway_min=4,
      throat_resource=Some("C-WEST"),
    ),
    segment(
      id="CD",
      from_station="C",
      to_station="D",
      distance_m=1200,
      min_run_min=2,
      scheduled_run_min=3,
      max_run_min=4,
      headway_min=3,
      throat_resource=Some("C-EAST"),
    ),
    segment(
      id="DE",
      from_station="D",
      to_station="E",
      distance_m=1400,
      min_run_min=3,
      scheduled_run_min=4,
      max_run_min=5,
      headway_min=4,
    ),
  ]
  let trains = [
    train(id="T101", service_name="快车 101", direction=Up, priority=8, stops=[
      stop_time(
        station_id="A",
        arrival_min=60,
        departure_min=60,
        stop_kind="origin",
      ),
      stop_time(station_id="B", arrival_min=63, departure_min=64),
      stop_time(
        station_id="C",
        arrival_min=68,
        departure_min=69,
        platform=2,
        stop_kind="transfer",
      ),
      stop_time(station_id="D", arrival_min=72, departure_min=73),
      stop_time(
        station_id="E",
        arrival_min=78,
        departure_min=78,
        stop_kind="terminal",
      ),
    ]),
    train(id="T102", service_name="普车 102", direction=Up, priority=5, stops=[
      stop_time(
        station_id="A",
        arrival_min=62,
        departure_min=62,
        stop_kind="origin",
      ),
      stop_time(station_id="B", arrival_min=65, departure_min=66),
      stop_time(
        station_id="C",
        arrival_min=70,
        departure_min=71,
        platform=2,
        stop_kind="transfer",
      ),
      stop_time(station_id="D", arrival_min=74, departure_min=75),
      stop_time(
        station_id="E",
        arrival_min=80,
        departure_min=80,
        stop_kind="terminal",
      ),
    ]),
    train(id="T201", service_name="下行 201", direction=Down, priority=6, stops=[
      stop_time(
        station_id="E",
        arrival_min=64,
        departure_min=64,
        stop_kind="origin",
      ),
      stop_time(station_id="D", arrival_min=68, departure_min=69),
      stop_time(
        station_id="C",
        arrival_min=72,
        departure_min=73,
        platform=1,
        stop_kind="transfer",
      ),
      stop_time(station_id="B", arrival_min=76, departure_min=77),
      stop_time(
        station_id="A",
        arrival_min=81,
        departure_min=81,
        stop_kind="terminal",
      ),
    ]),
    train(id="T301", service_name="下行 301", direction=Down, priority=4, stops=[
      stop_time(
        station_id="E",
        arrival_min=67,
        departure_min=67,
        stop_kind="origin",
      ),
      stop_time(station_id="D", arrival_min=71, departure_min=72),
      stop_time(
        station_id="C",
        arrival_min=75,
        departure_min=76,
        platform=1,
        stop_kind="transfer",
      ),
      stop_time(station_id="B", arrival_min=79, departure_min=80),
      stop_time(
        station_id="A",
        arrival_min=84,
        departure_min=84,
        stop_kind="terminal",
      ),
    ]),
  ]
  let reservations = [
    route_reservation(
      id="R101",
      train_id="T101",
      resource_id="C-WEST",
      entry_min=67,
      exit_min=70,
      release_margin_min=2,
      route_name="west-to-platform-2",
    ),
    route_reservation(
      id="R102",
      train_id="T102",
      resource_id="C-WEST",
      entry_min=69,
      exit_min=72,
      release_margin_min=2,
      route_name="west-to-platform-2",
    ),
    route_reservation(
      id="R201",
      train_id="T201",
      resource_id="C-EAST",
      entry_min=71,
      exit_min=74,
      release_margin_min=2,
      route_name="east-to-platform-1",
    ),
    route_reservation(
      id="R301",
      train_id="T301",
      resource_id="C-EAST",
      entry_min=74,
      exit_min=77,
      release_margin_min=2,
      route_name="east-to-platform-1",
    ),
  ]
  schedule(
    id="demo-line-1",
    service_date="2026-08-18",
    line_name="MoonBit 环线示范线",
    stations~,
    segments~,
    trains~,
    reservations~,
    notes="Synthetic OCC training fixture; not operational data.",
  )
}

///|
pub fn demo_telemetry() -> Array[TelemetryEvent] {
  [
    telemetry(
      event_id="e-001",
      train_id="T101",
      observed_min=63,
      position_m=1200,
      delay_min=0,
      station_id=Some("B"),
      speed_kmh=0,
      mode=Running,
    ),
    telemetry(
      event_id="e-002",
      train_id="T102",
      observed_min=65,
      position_m=1200,
      delay_min=2,
      station_id=Some("B"),
      speed_kmh=0,
      mode=Running,
    ),
    telemetry(
      event_id="e-003",
      train_id="T201",
      observed_min=72,
      position_m=2400,
      delay_min=1,
      station_id=Some("C"),
      speed_kmh=0,
      mode=Holding,
    ),
    telemetry(
      event_id="e-004",
      train_id="T301",
      observed_min=75,
      position_m=2400,
      delay_min=4,
      station_id=Some("C"),
      speed_kmh=0,
      mode=Running,
    ),
    telemetry(
      event_id="e-005",
      train_id="T102",
      observed_min=68,
      position_m=2000,
      delay_min=5,
      station_id=None,
      speed_kmh=45,
      mode=Running,
    ),
    telemetry(
      event_id="e-006",
      train_id="T102",
      observed_min=68,
      position_m=6500,
      delay_min=5,
      station_id=None,
      speed_kmh=45,
      mode=Running,
    ),
    telemetry(
      event_id="e-007",
      train_id="T999",
      observed_min=68,
      position_m=0,
      delay_min=0,
      station_id=None,
      speed_kmh=0,
      mode=Unknown,
    ),
  ]
}

///|
pub fn simulate_demo() -> SimulationReport {
  simulate(
    demo_schedule(),
    demo_telemetry(),
    start_min=60,
    end_min=90,
    step_min=2,
  )
}

///|
pub fn simulate(
  schedule : Schedule,
  events : Array[TelemetryEvent],
  start_min~ : Int,
  end_min~ : Int,
  step_min~ : Int,
) -> SimulationReport {
  let monitor = Monitor::new(schedule)
  let steps = []
  let mut time = start_min
  let step = positive_or(step_min, 1)
  while time <= end_min {
    for event in events {
      if event.observed_min == time {
        monitor.ingest(event)
      }
    }
    let snapshot = monitor.snapshot(time)
    let conflicts = monitor.conflicts(time)
    let recommendations = suggest_dispatches(
      schedule,
      conflicts,
      snapshot.runtimes,
    )
    steps.push({
      at_min: time,
      runtimes: snapshot.runtimes,
      conflicts,
      recommendations,
    })
    time += step
  }
  let conflict_count = steps.fold(init=0, fn(total, step) {
    total + step.conflicts.length()
  })
  let recommendation_count = steps.fold(init=0, fn(total, step) {
    total + step.recommendations.length()
  })
  let peak_delay_min = peak_delay(steps)
  {
    schedule_id: schedule.id,
    steps,
    conflict_count,
    recommendation_count,
    peak_delay_min,
  }
}

///|
fn peak_delay(steps : Array[SimulationStep]) -> Int {
  let mut peak = 0
  for step in steps {
    for runtime in step.runtimes {
      if runtime.delay_min > peak {
        peak = runtime.delay_min
      }
    }
  }
  peak
}

///|
pub fn simulation_summary(report : SimulationReport) -> String {
  "\{report.schedule_id}: \{report.steps.length()} step(s), \{report.conflict_count} conflict observation(s), \{report.recommendation_count} recommendation(s), peak delay \{report.peak_delay_min} min"
}

///|
pub fn simulation_json(report : SimulationReport) -> String {
  report.to_json().stringify()
}

///|
pub fn replay_at(
  schedule : Schedule,
  events : Array[TelemetryEvent],
  at_min : Int,
) -> MonitorSnapshot {
  let monitor = Monitor::new(schedule)
  for event in events {
    if event.observed_min <= at_min {
      monitor.ingest(event)
    }
  }
  monitor.snapshot(at_min)
}
