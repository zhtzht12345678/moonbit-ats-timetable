///|
/// Acceptance tests focus on data-boundary behavior and deterministic output.
/// They intentionally exercise the same public paths used by the CLI adapters.

///|
test "empty schedule remains queryable" {
  let schedule = schedule(
    id="empty",
    service_date="2026-08-19",
    line_name="empty-line",
    stations=[],
    segments=[],
    trains=[],
  )
  let index = build_interval_index(schedule, bucket_size_min=0)
  inspect(index.bucket_size_min, content="1")
  inspect(query_all_resources(index, 100, 0).length(), content="0")
  let quality = assess_service_quality(schedule, [], [], 100)
  inspect(quality_band_label(quality.band), content="unknown")
  inspect(quality.to_json_text().contains("empty"), content="true")
}

///|
test "invalid geometry is reported without throwing" {
  let malformed = schedule(
    id="malformed",
    service_date="2026-08-19",
    line_name="broken-line",
    stations=[station(id="A", name="A", distance_m=30, platform_count=0)],
    segments=[
      segment(
        id="bad",
        from_station="A",
        to_station="missing",
        distance_m=0,
        min_run_min=8,
        scheduled_run_min=3,
        max_run_min=2,
        headway_min=0,
      ),
    ],
    trains=[
      train(id="broken-train", service_name="broken", direction=Up, stops=[
        stop_time(
          station_id="missing",
          arrival_min=-5,
          departure_min=-6,
          platform=0,
        ),
      ]),
    ],
  )
  let issues = validate_schedule(malformed)
  inspect(issues.length() > 0, content="true")
  inspect(issues[0].severity == "error", content="true")
  let path = find_station_path(malformed, "A", "missing")
  inspect(path.feasible, content="false")
}

///|
test "passenger boundary values are clamped" {
  let load = passenger_load(
    train_id="T",
    station_id="A",
    boardings=-10,
    alightings=-3,
    onboard_before=-8,
    capacity=0,
  )
  inspect(load.boardings, content="0")
  inspect(load.alightings, content="0")
  inspect(load.onboard_before, content="0")
  inspect(load.capacity, content="1")
  inspect(passenger_load_percent(load), content="0")
  let dwell = estimate_dwell(
    scheduled_dwell_min=-4,
    boardings=100,
    alightings=100,
    boarding_rate=0,
    alighting_rate=0,
    door_clearance_min=-2,
    minimum_dwell_min=1,
    maximum_dwell_min=3,
  )
  inspect(dwell.estimated_dwell_min, content="3")
  inspect(dwell.capped, content="true")
}

///|
test "time parsing rejects malformed and accepts extended clocks" {
  debug_inspect(parse_clock(""), content="None")
  debug_inspect(parse_clock("1"), content="None")
  debug_inspect(parse_clock("24:00"), content="Some(1440)")
  debug_inspect(parse_clock("48:01"), content="Some(2881)")
  debug_inspect(parse_clock("12:99"), content="None")
  inspect(format_clock(-1), content="00:00")
  inspect(format_clock(1440), content="24:00")
}

///|
test "half-open interval queries keep adjacent movements separate" {
  let schedule = demo_schedule()
  let index = build_interval_index(schedule, bucket_size_min=1)
  let exact = query_interval_index(index, "segment:AB", 60, 63)
  let adjacent = query_interval_index(index, "segment:AB", 63, 64)
  inspect(exact.start_min, content="60")
  inspect(adjacent.end_min, content="64")
  inspect(interval_index_summary(index).contains("intervals="), content="true")
  inspect(
    interval_index_markdown(index).contains("Interval index"),
    content="true",
  )
}

///|
test "reversed interval windows are normalized" {
  let index = build_interval_index(demo_schedule(), bucket_size_min=5)
  let query = query_interval_index(index, "platform:A:1", 100, 50)
  inspect(query.start_min, content="50")
  inspect(query.end_min, content="100")
  let resources = query_all_resources(index, 100, 50)
  inspect(resources.length() > 0, content="true")
  let candidates = interval_candidates(index, "platform:C:2", 50, 100)
  inspect(candidates.length() >= 0, content="true")
}

///|
test "topology handles identity, unknown nodes and blocked nodes" {
  let schedule = demo_schedule()
  let identity = find_station_path(schedule, "C", "C")
  inspect(identity.feasible, content="true")
  inspect(identity.total_run_min, content="0")
  let unknown = find_station_path(schedule, "missing", "C")
  inspect(unknown.feasible, content="false")
  let blocked = find_station_path(
    schedule,
    "A",
    "E",
    constraint=route_constraint(avoid_stations=["C"]),
  )
  inspect(blocked.feasible, content="false")
  let reachable = reachable_stations(schedule, "A", maximum_hops=1)
  inspect(reachable.contains("B"), content="true")
  inspect(reachable.contains("E"), content="false")
}

///|
test "route plan keeps requested margins non-negative" {
  let plan = make_route_plan(
    demo_schedule(),
    request_id="boundary",
    origin="A",
    destination="E",
    requested_at_min=-20,
    reserve_margin_min=-4,
  )
  inspect(plan.reserve_margin_min, content="0")
  inspect(plan.path.feasible, content="true")
  inspect(route_plan_is_safe(demo_schedule(), plan), content="false")
  inspect(plan.to_json_text().contains("boundary"), content="true")
}

///|
test "resource catalogue normalizes and exposes critical resources" {
  let catalogue = build_resource_catalogue(
    demo_schedule(),
    start_min=100,
    end_min=50,
  )
  inspect(catalogue.start_min, content="50")
  inspect(catalogue.end_min, content="100")
  inspect(catalogue.resources.length() > 0, content="true")
  inspect(
    resource_catalogue_json(catalogue).contains("resources"),
    content="true",
  )
  inspect(
    resource_catalogue_markdown(catalogue).contains("Resource catalogue"),
    content="true",
  )
  let ids = critical_resource_ids(catalogue, threshold_percent=0)
  inspect(ids.length() >= 0, content="true")
}

///|
test "scenario assessment distinguishes cancellation and blackout" {
  let schedule = demo_schedule()
  let cancellation = incident(
    id="cancel",
    kind=TrainCancellation,
    severity=Warning,
    target_id="T101",
    start_min=70,
    end_min=60,
    reason="boundary test",
  )
  inspect(cancellation.start_min, content="60")
  let assessment = assess_incident(schedule, cancellation)
  inspect(assessment.cancelled_train_count, content="1")
  let blackout = incident(
    id="blackout",
    kind=DataBlackout,
    severity=Advisory,
    target_id="T102",
    start_min=60,
    end_min=75,
  )
  let portfolio = assess_incidents(schedule, [cancellation, blackout])
  inspect(portfolio.assessments.length(), content="2")
  inspect(least_disruptive_incident(portfolio) is Some(_), content="true")
  inspect(
    scenario_portfolio_json(portfolio).contains("blackout"),
    content="true",
  )
}

///|
test "operations and quality reports retain audit evidence" {
  let schedule = demo_schedule()
  let loads = [
    passenger_load(
      train_id="T101",
      station_id="C",
      boardings=90,
      alightings=5,
      onboard_before=80,
      capacity=100,
      period=Peak,
    ),
    passenger_load(
      train_id="T102",
      station_id="C",
      boardings=20,
      alightings=50,
      onboard_before=70,
      capacity=100,
      period=OffPeak,
    ),
  ]
  let operations = operations_report(schedule, loads, demo_runtimes(), 80)
  inspect(operations.passenger_observation_count, content="2")
  inspect(
    operations.to_json().stringify().contains("station_performance"),
    content="true",
  )
  let quality = assess_service_quality(schedule, demo_runtimes(), loads, 80)
  inspect(quality.train_count, content="4")
  inspect(quality.observed_train_count, content="4")
  inspect(quality.to_markdown().contains("Train evidence"), content="true")
}

///|
test "quality scorer does not treat stale data as punctual" {
  let schedule = demo_schedule()
  let runtime = telemetry(
    event_id="old",
    train_id="T101",
    observed_min=10,
    position_m=0,
    delay_min=0,
    mode=Running,
    station_id=Some("A"),
  )
  let monitor = Monitor::new(schedule)
  monitor.ingest(runtime)
  let quality = assess_service_quality(
    schedule,
    monitor.current_runtimes(),
    [],
    100,
  )
  let first = quality.trains[0]
  inspect(first.observed, content="false")
  inspect(quality_band_label(first.band), content="poor")
  inspect(quality.notes.length() > 0, content="true")
}

///|
test "dispatch plan remains deterministic across rescoring" {
  let schedule = demo_schedule()
  let plan = build_rolling_plan(schedule, demo_runtimes(), 80)
  let rescored = rescore_rolling_plan(
    schedule,
    plan,
    demo_runtimes(),
    default_dispatch_weights(),
  )
  inspect(
    rolling_plan_score(plan),
    content=rolling_plan_score(rescored).to_string(),
  )
  inspect(
    selected_plan_items(rescored).length() <= plan.items.length(),
    content="true",
  )
  inspect(rolling_plan_json(rescored).contains("items"), content="true")
}

///|
test "benchmark dimensions are clamped and reproducible" {
  let definition = benchmark_definition(
    name="edge",
    station_count=1,
    train_count=0,
    iterations=0,
  )
  inspect(definition.station_count, content="2")
  inspect(definition.train_count, content="1")
  inspect(definition.iterations, content="1")
  let first = run_benchmark_workload(definition)
  let second = run_benchmark_workload(definition)
  inspect(first.checksum, content=second.checksum.to_string())
  inspect(first.passenger_observations, content="0")
  inspect(
    benchmark_workload_markdown(first).contains("Checksum"),
    content="true",
  )
}

///|
test "recovery candidates keep transfer and conflict evidence" {
  let schedule = demo_schedule()
  let candidates = build_recovery_candidates(schedule, demo_runtimes())
  inspect(candidates.length() > 0, content="true")
  inspect(candidates[0].conflicts_after >= 0, content="true")
  inspect(
    recovery_candidate_json(candidates[0]).contains("prerequisites"),
    content="true",
  )
  let plan = build_recovery_plan(schedule, demo_runtimes(), 80)
  inspect(plan.schedule_id, content="demo-line-1")
  inspect(
    selected_recovery_candidates(plan).length(),
    content=plan.selected_count.to_string(),
  )
  inspect(plan.to_markdown().contains("Service recovery plan"), content="true")
}

///|
test "recovery policy clamps candidate fan-out" {
  let policy = recovery_policy(
    minimum_delay_min=-2,
    maximum_hold_min=-1,
    maximum_speedup_min=100,
    minimum_platform_buffer_min=-4,
    maximum_candidates_per_train=100,
    allow_skip=false,
    allow_short_turn=false,
    require_transfer_protection=true,
  )
  inspect(policy.minimum_delay_min, content="0")
  inspect(policy.maximum_hold_min, content="0")
  inspect(policy.maximum_speedup_min, content="100")
  inspect(policy.maximum_candidates_per_train, content="12")
  inspect(
    recovery_policy(
      minimum_delay_min=2,
      maximum_hold_min=2,
      maximum_speedup_min=1,
      minimum_platform_buffer_min=1,
      maximum_candidates_per_train=2,
      allow_skip=false,
      allow_short_turn=false,
      require_transfer_protection=true,
    ).allow_skip,
    content="false",
  )
}

///|
test "synthetic benchmark stays valid at a small dimension" {
  let schedule = synthetic_benchmark_schedule(3, 2)
  inspect(validate_schedule(schedule).length(), content="0")
  inspect(schedule.stations.length(), content="3")
  inspect(schedule.trains.length(), content="2")
  inspect(schedule.to_xml_text().contains("<schedule"), content="true")
  let result = benchmark_result(
    benchmark_definition(name="tiny", station_count=3, train_count=2),
    run_benchmark_workload(
      benchmark_definition(name="tiny", station_count=3, train_count=2),
    ),
    0,
  )
  inspect(result.operations_per_ms, content="0")
}

///|
test "serialization rejects incomplete payloads" {
  let invalid_json = schedule_from_json_text("{}")
  guard invalid_json is Err(_) else { fail("empty object must be rejected") }
  let invalid_xml = schedule_from_xml_text("<not-a-schedule />")
  guard invalid_xml is Err(_) else { fail("unknown XML root must be rejected") }
  let valid_xml = schedule_from_xml_text(demo_schedule().to_xml_text())
  guard valid_xml is Ok(parsed) else { fail("demo XML must parse") }
  inspect(parsed.version, content="1")
}

///|
fn demo_runtimes() -> Array[TrainRuntime] {
  demo_telemetry().map(fn(event) {
    {
      train_id: event.train_id,
      observed_min: event.observed_min,
      station_id: event.station_id,
      position_m: event.position_m,
      delay_min: event.delay_min,
      speed_kmh: event.speed_kmh,
      mode: event.mode,
      source: event.source,
      event_count: 1,
    }
  })
}
