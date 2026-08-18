///|
test "clock conversion keeps minute precision" {
  debug_inspect(parse_clock("06:05"), content="Some(365)")
  debug_inspect(parse_clock("27:59"), content="Some(1679)")
  debug_inspect(parse_clock("06:60"), content="None")
  inspect(format_clock(365), content="06:05")
}

///|
test "demo schedule is structurally valid" {
  let schedule = demo_schedule()
  inspect(validate_schedule(schedule).length(), content="0")
  inspect(schedule.station_by_id("C").unwrap().is_interchange, content="true")
  inspect(schedule.train_by_id("T101").unwrap().stops.length(), content="5")
}

///|
test "conflict detector finds headway platform and route evidence" {
  let conflicts = detect_conflicts(demo_schedule())
  inspect(conflicts.length() > 0, content="true")
  inspect(
    conflict_count_by_kind(conflicts, HeadwayConflict) > 0,
    content="true",
  )
  inspect(conflict_count_by_kind(conflicts, RouteConflict) > 0, content="true")
  inspect(conflict_summary(conflicts).contains("headway"), content="true")
}

///|
test "JSON and XML formats preserve the operational model" {
  let schedule = demo_schedule()
  let json_result = schedule_from_json_text(schedule.to_json_text())
  guard json_result is Ok(parsed_json) else { fail("JSON round trip failed") }
  inspect(parsed_json.id, content="demo-line-1")
  inspect(parsed_json.trains.length(), content="4")
  let xml_result = schedule_from_xml_text(schedule.to_xml_text())
  guard xml_result is Ok(parsed_xml) else { fail("XML round trip failed") }
  inspect(parsed_xml.stations.length(), content="5")
  inspect(parsed_xml.segments.length(), content="4")
  inspect(parsed_xml.trains.length(), content="4")
}

///|
test "dispatch policy returns a bounded preview" {
  let schedule = demo_schedule()
  let conflicts = detect_conflicts(schedule)
  let recommendations = suggest_dispatches(schedule, conflicts, [])
  inspect(recommendations.length() > 0, content="true")
  let preview = apply_dispatch_action(schedule, recommendations[0].primary)
  inspect(preview.version, content="2")
  inspect(preview.trains.length(), content="4")
}

///|
test "monitor raises freshness and telemetry alerts" {
  let schedule = demo_schedule()
  let monitor = Monitor::new(schedule)
  monitor.ingest_all(demo_telemetry())
  let snapshot = monitor.snapshot(80)
  inspect(snapshot.telemetry_count, content="7")
  inspect(snapshot.runtimes.length(), content="4")
  inspect(snapshot.alerts.length() > 0, content="true")
  inspect(
    monitor_alert_summary(snapshot.alerts).contains("alert"),
    content="true",
  )
}

///|
test "diagram renderer exposes lines and conflicts" {
  let schedule = demo_schedule()
  let conflicts = detect_conflicts(schedule)
  let frame = build_diagram_frame(
    schedule,
    [],
    conflicts,
    render_options(start_min=55, end_min=90),
    generated_at="test",
  )
  inspect(frame.lines.length(), content="4")
  inspect(frame.stations.length(), content="5")
  inspect(
    render_string_diagram_json(
      schedule,
      [],
      conflicts,
      render_options(start_min=55, end_min=90),
      generated_at="test",
    ).contains("\"lines\""),
    content="true",
  )
}

///|
test "metrics and replay are deterministic" {
  let schedule = demo_schedule()
  let report = simulate_demo()
  inspect(report.steps.length(), content="16")
  inspect(report.peak_delay_min, content="5")
  let metrics = analyze_schedule(schedule, [], 80)
  inspect(metrics.train_count, content="4")
  inspect(schedule_health_label(metrics), content="at-risk")
  let snapshot = replay_at(schedule, demo_telemetry(), 75)
  inspect(snapshot.runtimes.length(), content="4")
}
