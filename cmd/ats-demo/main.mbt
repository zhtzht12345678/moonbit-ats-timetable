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
    "moonbit-ats-timetable demo\n\n  moon run cmd/ats-demo -- --action <check|conflicts|diagram|xml|metrics|simulate|health> [--json]",
  )
}
