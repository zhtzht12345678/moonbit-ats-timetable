///|
fn main {
  let args = @env.args()
  let action = option_value(args, "--action").unwrap_or("help")
  let schedule = @ats.demo_schedule()
  if action == "check" {
    println(@ats.validation_report_json(schedule))
  } else if action == "conflicts" {
    let conflicts = @ats.detect_conflicts(schedule)
    println(@ats.conflict_summary(conflicts))
    for conflict in conflicts {
      println(
        "\{conflict.severity} \{conflict.kind.to_json().stringify()} \{conflict.first_train_id}/\{conflict.second_train_id} @ \{conflict.resource_id}: \{conflict.message}",
      )
    }
  } else if action == "diagram" {
    let conflicts = @ats.detect_conflicts(schedule)
    let options = @ats.render_options(start_min=55, end_min=90)
    println(
      @ats.render_string_diagram_json(
        schedule,
        [],
        conflicts,
        options,
        generated_at="demo",
      ),
    )
  } else if action == "xml" {
    println(@ats.Schedule::to_xml_text(schedule))
  } else if action == "metrics" {
    let metrics = @ats.analyze_schedule(schedule, [], 80)
    println(@ats.schedule_metrics_markdown(metrics))
  } else if action == "simulate" {
    let report = @ats.simulate_demo()
    println(@ats.simulation_summary(report))
    if option_value(args, "--json") is Some(_) {
      println(@ats.simulation_json(report))
    }
  } else if action == "health" {
    println(@ats.health_dashboard_json(schedule, [], 80))
  } else if action == "operations" {
    let report = @ats.operations_report(schedule, [], demo_runtimes(), 80)
    if option_value(args, "--json") is Some(_) {
      println(@ats.operations_report_json(report))
    } else {
      println(@ats.operations_report_markdown(report))
    }
  } else if action == "quality" {
    let dashboard = @ats.assess_service_quality(
      schedule,
      demo_runtimes(),
      [],
      80,
    )
    if option_value(args, "--json") is Some(_) {
      println(@ats.QualityDashboard::to_json_text(dashboard))
    } else {
      println(@ats.QualityDashboard::to_markdown(dashboard))
    }
  } else if action == "scenario" {
    let scenario = @ats.incident(
      id="demo-speed-restriction",
      kind=@ats.SpeedRestriction,
      severity=@ats.Warning,
      target_id="BC",
      start_min=65,
      end_min=80,
      value=2,
      reason="demonstration of a bounded scenario assessment",
    )
    let assessment = @ats.assess_incident(schedule, scenario)
    println(@ats.scenario_assessment_json(assessment))
  } else if action == "plan" {
    let plan = @ats.build_rolling_plan(schedule, demo_runtimes(), 80)
    println(@ats.rolling_plan_markdown(plan))
  } else if action == "recovery" {
    let plan = @ats.build_recovery_plan(schedule, demo_runtimes(), 80)
    println(@ats.RecoveryPlan::to_markdown(plan))
  } else {
    print_usage()
  }
}

///|
fn option_value(args : Array[String], wanted : String) -> String? {
  for i in 0..<args.length() {
    if args[i] == wanted && i + 1 < args.length() {
      return Some(args[i + 1])
    }
  }
  None
}

///|
fn print_usage() -> Unit {
  println(
    "moonbit-ats-timetable demo\n\n  moon run cmd/ats-demo -- --action <check|conflicts|diagram|xml|metrics|simulate|health|operations|quality|scenario|plan|recovery> [--json]",
  )
}

///|
fn demo_runtimes() -> Array[@ats.TrainRuntime] {
  @ats.demo_telemetry().map(fn(event) {
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
