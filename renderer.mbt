///|
/// Build the stable String Diagram DTO. Time is the horizontal axis and
/// distance from the line origin is the vertical axis.
pub fn build_diagram_frame(
  schedule : Schedule,
  runtimes : Array[TrainRuntime],
  conflicts : Array[Conflict],
  options : RenderOptions,
  generated_at~ : String,
) -> DiagramFrame {
  let stations = []
  for order, station in schedule.stations {
    stations.push({
      station_id: station.id,
      label: station.name,
      distance_m: station.distance_m,
      order,
    })
  }
  let lines = []
  for train in schedule.trains {
    let runtime = find_runtime(train.id, runtimes)
    let status = match runtime {
      Some(value) => value.mode.label()
      None =>
        if train_is_finished(train, options.end_min) {
          "finished"
        } else {
          "planned"
        }
    }
    if options.include_finished || status != "finished" {
      lines.push({
        train_id: train.id,
        service_name: train.service_name,
        direction: train.direction,
        points: diagram_points(schedule, train, runtime),
        color: diagram_color(train, status),
        status,
      })
    }
  }
  {
    schedule_id: schedule.id,
    service_date: schedule.service_date,
    start_min: options.start_min,
    end_min: options.end_min,
    stations,
    lines,
    conflicts: if options.include_conflicts {
      conflicts
    } else {
      []
    },
    generated_at,
  }
}

///|
pub fn render_string_diagram_json(
  schedule : Schedule,
  runtimes : Array[TrainRuntime],
  conflicts : Array[Conflict],
  options : RenderOptions,
  generated_at~ : String,
) -> String {
  build_diagram_frame(schedule, runtimes, conflicts, options, generated_at~)
  .to_json()
  .stringify()
}

///|
pub fn render_string_diagram_ndjson(
  schedule : Schedule,
  runtimes : Array[TrainRuntime],
  conflicts : Array[Conflict],
  options : RenderOptions,
  generated_at~ : String,
) -> String {
  let frame = build_diagram_frame(
    schedule,
    runtimes,
    conflicts,
    options,
    generated_at~,
  )
  let builder = StringBuilder()
  builder.write_string(
    Json::object({
      "type": "frame".to_json(),
      "schedule_id": schedule.id.to_json(),
      "generated_at": generated_at.to_json(),
    }).stringify(),
  )
  builder.write_string("\n")
  for line in frame.lines {
    builder.write_string(
      Json::object({
        "type": "line".to_json(),
        "train_id": line.train_id.to_json(),
        "service_name": line.service_name.to_json(),
        "direction": line.direction.to_json(),
        "status": line.status.to_json(),
        "color": line.color.to_json(),
        "points": line.points.to_json(),
      }).stringify(),
    )
    builder.write_string("\n")
  }
  if options.include_conflicts {
    for conflict in frame.conflicts {
      builder.write_string(
        Json::object({
          "type": "conflict".to_json(),
          "id": conflict.id.to_json(),
          "kind": conflict.kind.to_json(),
          "severity": conflict.severity.to_json(),
          "resource_id": conflict.resource_id.to_json(),
        }).stringify(),
      )
      builder.write_string("\n")
    }
  }
  builder.to_string()
}

///|
fn diagram_points(
  schedule : Schedule,
  train : Train,
  runtime : TrainRuntime?,
) -> Array[DiagramPoint] {
  let delay = match runtime {
    Some(value) => value.delay_min
    None => 0
  }
  let points = []
  for i, stop in train.stops {
    points.push({
      time_min: stop.departure_min + delay,
      distance_m: station_distance(schedule, stop.station_id),
      station_id: stop.station_id,
      delay_min: delay,
    })
    if i + 1 < train.stops.length() {
      let next = train.stops[i + 1]
      let start_distance = station_distance(schedule, stop.station_id)
      let end_distance = station_distance(schedule, next.station_id)
      let start_time = stop.departure_min + delay
      let end_time = next.arrival_min + delay
      let middle_time = (start_time + end_time) / 2
      let middle_distance = (start_distance + end_distance) / 2
      points.push({
        time_min: middle_time,
        distance_m: middle_distance,
        station_id: "",
        delay_min: delay,
      })
    }
  }
  points
}

///|
fn station_distance(schedule : Schedule, station_id : String) -> Int {
  match schedule.station_by_id(station_id) {
    Some(station) => station.distance_m
    None => 0
  }
}

///|
fn find_runtime(
  train_id : String,
  runtimes : Array[TrainRuntime],
) -> TrainRuntime? {
  for runtime in runtimes {
    if runtime.train_id == train_id {
      return Some(runtime)
    }
  }
  None
}

///|
fn train_is_finished(train : Train, end_min : Int) -> Bool {
  match train.last_time() {
    Some(time) => time < end_min
    None => false
  }
}

///|
fn diagram_color(train : Train, status : String) -> String {
  if status == "cancelled" {
    "#8c8c8c"
  } else {
    match train.direction {
      Up => if train.priority >= 7 { "#c41d7f" } else { "#1677ff" }
      Down => if train.priority >= 7 { "#d4380d" } else { "#389e0d" }
      Loop => "#722ed1"
    }
  }
}

///|
/// An SVG path is provided as a display helper, while the canonical API
/// remains the JSON frame above. Clients can choose their own renderer.
pub fn render_string_diagram_svg(frame : DiagramFrame) -> String {
  let builder = StringBuilder()
  builder.write_string(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1200 720\" role=\"img\" aria-label=\"String Diagram\">\n",
  )
  builder.write_string(
    "  <rect width=\"1200\" height=\"720\" fill=\"#101820\" />\n",
  )
  for station in frame.stations {
    let y = 80 + station.order * 560 / max_int(1, frame.stations.length() - 1)
    builder.write_string(
      "  <line x1=\"40\" y1=\"\{y}\" x2=\"1160\" y2=\"\{y}\" stroke=\"#3a4a5a\" stroke-width=\"1\" />\n",
    )
    builder.write_string(
      "  <text x=\"12\" y=\"\{y - 4}\" fill=\"#d9e1e8\" font-size=\"12\">\{quote_xml(station.label)}</text>\n",
    )
  }
  for line in frame.lines {
    let path = svg_path(line.points, frame.start_min, frame.end_min)
    builder.write_string(
      "  <path d=\"\{path}\" fill=\"none\" stroke=\"\{line.color}\" stroke-width=\"2\" opacity=\"0.9\" />\n",
    )
  }
  for conflict in frame.conflicts {
    let x = time_x(conflict.start_min, frame.start_min, frame.end_min)
    builder.write_string(
      "  <line x1=\"\{x}\" y1=\"45\" x2=\"\{x}\" y2=\"680\" stroke=\"#ff4d4f\" stroke-width=\"1\" stroke-dasharray=\"5 4\" />\n",
    )
  }
  builder.write_string("</svg>\n")
  builder.to_string()
}

///|
fn svg_path(
  points : Array[DiagramPoint],
  start_min : Int,
  end_min : Int,
) -> String {
  let builder = StringBuilder()
  for i, point in points {
    let x = time_x(point.time_min, start_min, end_min)
    let y = 80 + point.distance_m % 560
    if i == 0 {
      builder.write_string("M\{x} \{y}")
    } else {
      builder.write_string(" L\{x} \{y}")
    }
  }
  builder.to_string()
}

///|
fn time_x(value : Int, start_min : Int, end_min : Int) -> Int {
  let width = max_int(1, end_min - start_min)
  40 + clamp_int((value - start_min) * 1120 / width, 0, 1120)
}

///|
/// Bundle monitor data and decisions into one JSON response for a dashboard
/// endpoint. The object stays intentionally flat at the top level so a web
/// client can stream it without schema-specific plumbing.
pub fn render_dispatch_bundle_json(
  schedule : Schedule,
  snapshot : MonitorSnapshot,
  conflicts : Array[Conflict],
  recommendations : Array[DispatchRecommendation],
) -> String {
  Json::object({
    "schedule": schedule.to_json(),
    "snapshot": snapshot.to_json(),
    "conflicts": conflicts.to_json(),
    "recommendations": recommendations.to_json(),
  }).stringify()
}

///|
pub fn render_conflict_csv(conflicts : Array[Conflict]) -> String {
  let builder = StringBuilder()
  builder.write_string(
    "id,kind,severity,resource_id,first_train_id,second_train_id,start,end,required,actual,message\n",
  )
  for conflict in conflicts {
    let values = [
      quote_json(conflict.id),
      quote_json(conflict.kind.to_json().stringify()),
      quote_json(conflict.severity),
      quote_json(conflict.resource_id),
      quote_json(conflict.first_train_id),
      quote_json(conflict.second_train_id),
      conflict.start_min.to_string(),
      conflict.end_min.to_string(),
      conflict.required_separation_min.to_string(),
      conflict.actual_separation_min.to_string(),
      quote_json(conflict.message),
    ]
    builder.write_string(csv_join(values))
    builder.write_string("\n")
  }
  builder.to_string()
}

///|
pub fn diagram_time_labels(
  start_min : Int,
  end_min : Int,
  step_min : Int,
) -> Array[String] {
  let labels = []
  let step = positive_or(step_min, 15)
  let mut time = start_min
  while time <= end_min {
    labels.push(format_clock(time))
    time += step
  }
  labels
}
