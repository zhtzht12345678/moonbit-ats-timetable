///|
/// Serialize a validated or partially edited schedule to canonical JSON.
/// ToJson is derived on the public model, so external adapters can use the
/// same types without depending on this convenience wrapper.
pub fn Schedule::to_json_text(self : Schedule) -> String {
  self.to_json().stringify()
}

///|
/// Parse a JSON schedule and keep the original error text for an import UI.
pub fn schedule_from_json_text(text : String) -> Result[Schedule, String] {
  try {
    let json = @json.parse(text)
    let schedule : Schedule = @json.from_json(json)
    Ok(schedule)
  } catch {
    error => Err(error.to_string())
  }
}

///|
pub fn schedule_validation_from_json_text(
  text : String,
) -> Result[Array[ValidationIssue], String] {
  schedule_from_json_text(text).map(fn(schedule) { validate_schedule(schedule) })
}

///|
/// Export an intentionally small XML vocabulary. The format is designed for
/// interchange with a converter rather than to claim compatibility with any
/// vendor-specific ATS schema.
pub fn Schedule::to_xml_text(self : Schedule) -> String {
  let builder = StringBuilder()
  builder.write_string(
    "<schedule id=\"\{quote_xml(self.id)}\" service_date=\"\{quote_xml(self.service_date)}\" timezone=\"\{quote_xml(self.timezone)}\" line_name=\"\{quote_xml(self.line_name)}\" version=\"\{self.version}\">\n",
  )
  builder.write_string("  <stations>\n")
  for station in self.stations {
    builder.write_string(
      "    <station id=\"\{quote_xml(station.id)}\" name=\"\{quote_xml(station.name)}\" distance_m=\"\{station.distance_m}\" platform_count=\"\{station.platform_count}\" interchange=\"\{station.is_interchange}\" />\n",
    )
  }
  builder.write_string("  </stations>\n")
  builder.write_string("  <segments>\n")
  for segment in self.segments {
    let resource = match segment.throat_resource {
      Some(value) => quote_xml(value)
      None => ""
    }
    builder.write_string(
      "    <segment id=\"\{quote_xml(segment.id)}\" from=\"\{quote_xml(segment.from_station)}\" to=\"\{quote_xml(segment.to_station)}\" distance_m=\"\{segment.distance_m}\" min_run_min=\"\{segment.min_run_min}\" scheduled_run_min=\"\{segment.scheduled_run_min}\" max_run_min=\"\{segment.max_run_min}\" headway_min=\"\{segment.headway_min}\" throat_resource=\"\{resource}\" />\n",
    )
  }
  builder.write_string("  </segments>\n")
  builder.write_string("  <trains>\n")
  for train in self.trains {
    builder.write_string(
      "    <train id=\"\{quote_xml(train.id)}\" service_name=\"\{quote_xml(train.service_name)}\" direction=\"\{train.direction.label()}\" priority=\"\{train.priority}\" length_m=\"\{train.length_m}\" max_speed_kmh=\"\{train.max_speed_kmh}\" notes=\"\{quote_xml(train.notes)}\">\n",
    )
    for stop in train.stops {
      builder.write_string(
        "      <stop station_id=\"\{quote_xml(stop.station_id)}\" arrival_min=\"\{stop.arrival_min}\" departure_min=\"\{stop.departure_min}\" platform=\"\{stop.platform}\" stop_kind=\"\{quote_xml(stop.stop_kind)}\" minimum_dwell_min=\"\{stop.minimum_dwell_min}\" passenger_dwell_min=\"\{stop.passenger_dwell_min}\" />\n",
      )
    }
    builder.write_string("    </train>\n")
  }
  builder.write_string("  </trains>\n")
  builder.write_string("  <reservations>\n")
  for reservation in self.reservations {
    builder.write_string(
      "    <reservation id=\"\{quote_xml(reservation.id)}\" train_id=\"\{quote_xml(reservation.train_id)}\" resource_id=\"\{quote_xml(reservation.resource_id)}\" entry_min=\"\{reservation.entry_min}\" exit_min=\"\{reservation.exit_min}\" release_margin_min=\"\{reservation.release_margin_min}\" route_name=\"\{quote_xml(reservation.route_name)}\" />\n",
    )
  }
  builder.write_string("  </reservations>\n")
  builder.write_string("  <notes>\{quote_xml(self.notes)}</notes>\n")
  builder.write_string("</schedule>\n")
  builder.to_string()
}

///|
/// Import the line-oriented XML subset emitted by to_xml_text. Unknown tags
/// are skipped, which lets an upstream converter keep vendor extensions in
/// the same document without breaking the core importer.
pub fn schedule_from_xml_text(text : String) -> Result[Schedule, String] {
  let mut id = "xml-schedule"
  let mut service_date = ""
  let mut timezone = "Asia/Shanghai"
  let mut line_name = ""
  let mut version = 1
  let mut notes = ""
  let stations = []
  let segments = []
  let trains = []
  let reservations = []
  let mut current_train : Train? = None
  for raw_line in split_lines(text) {
    let line = raw_line.trim().to_owned()
    if line.has_prefix("<schedule") {
      id = xml_attr_or(line, "id", id)
      service_date = xml_attr_or(line, "service_date", service_date)
      timezone = xml_attr_or(line, "timezone", timezone)
      line_name = xml_attr_or(line, "line_name", line_name)
      version = xml_attr_int_or(line, "version", version)
    } else if line.has_prefix("<station ") || line.has_prefix("<station/>") {
      stations.push({
        id: xml_attr_or(line, "id", ""),
        name: xml_attr_or(line, "name", ""),
        distance_m: xml_attr_int_or(line, "distance_m", 0),
        platform_count: xml_attr_int_or(line, "platform_count", 2),
        is_interchange: xml_attr_bool_or(line, "interchange", false),
      })
    } else if line.has_prefix("<segment ") || line.has_prefix("<segment/>") {
      let resource = xml_attr_or(line, "throat_resource", "")
      let resource_value : String? = if resource == "" {
        None
      } else {
        Some(resource)
      }
      segments.push({
        id: xml_attr_or(line, "id", ""),
        from_station: xml_attr_or(line, "from", ""),
        to_station: xml_attr_or(line, "to", ""),
        distance_m: xml_attr_int_or(line, "distance_m", 1),
        min_run_min: xml_attr_int_or(line, "min_run_min", 1),
        scheduled_run_min: xml_attr_int_or(line, "scheduled_run_min", 1),
        max_run_min: xml_attr_int_or(line, "max_run_min", 1),
        headway_min: xml_attr_int_or(line, "headway_min", 3),
        throat_resource: resource_value,
      })
    } else if (line.has_prefix("<train ") || line.has_prefix("<train>")) &&
      !line.has_prefix("</train") {
      current_train = Some({
        id: xml_attr_or(line, "id", ""),
        service_name: xml_attr_or(line, "service_name", ""),
        direction: parse_direction(xml_attr_or(line, "direction", "up")),
        priority: xml_attr_int_or(line, "priority", 5),
        length_m: xml_attr_int_or(line, "length_m", 120),
        max_speed_kmh: xml_attr_int_or(line, "max_speed_kmh", 80),
        stops: [],
        notes: xml_attr_or(line, "notes", ""),
      })
    } else if line.has_prefix("<stop") {
      if current_train is Some(train) {
        train.stops.push({
          station_id: xml_attr_or(line, "station_id", ""),
          arrival_min: xml_attr_int_or(line, "arrival_min", 0),
          departure_min: xml_attr_int_or(line, "departure_min", 0),
          platform: xml_attr_int_or(line, "platform", 1),
          stop_kind: xml_attr_or(line, "stop_kind", "normal"),
          minimum_dwell_min: xml_attr_int_or(line, "minimum_dwell_min", 1),
          passenger_dwell_min: xml_attr_int_or(line, "passenger_dwell_min", 1),
        })
        current_train = Some(train)
      }
    } else if line.has_prefix("</train") {
      if current_train is Some(train) {
        trains.push(train)
        current_train = None
      }
    } else if line.has_prefix("<reservation ") ||
      line.has_prefix("<reservation/>") {
      reservations.push({
        id: xml_attr_or(line, "id", ""),
        train_id: xml_attr_or(line, "train_id", ""),
        resource_id: xml_attr_or(line, "resource_id", ""),
        entry_min: xml_attr_int_or(line, "entry_min", 0),
        exit_min: xml_attr_int_or(line, "exit_min", 0),
        release_margin_min: xml_attr_int_or(line, "release_margin_min", 1),
        route_name: xml_attr_or(line, "route_name", ""),
      })
    } else if line.has_prefix("<notes>") {
      notes = xml_text_value(line, "notes")
    }
  }
  if current_train is Some(train) {
    trains.push(train)
  }
  let result = schedule(
    id~,
    service_date~,
    line_name~,
    stations~,
    segments~,
    trains~,
    reservations~,
    timezone~,
    version~,
    notes~,
  )
  let errors = validation_errors(validate_schedule(result))
  if errors.length() > 0 {
    Err(validation_summary(errors))
  } else {
    Ok(result)
  }
}

///|
fn xml_attr_or(line : String, name : String, fallback : String) -> String {
  match xml_attr(line, name) {
    Some(value) => value
    None => fallback
  }
}

///|
fn xml_attr_int_or(line : String, name : String, fallback : Int) -> Int {
  match xml_attr(line, name) {
    Some(value) =>
      match parse_signed_int(value) {
        Some(number) => number
        None => fallback
      }
    None => fallback
  }
}

///|
fn xml_attr_bool_or(line : String, name : String, fallback : Bool) -> Bool {
  match xml_attr(line, name) {
    Some(value) =>
      match value.to_lower() {
        "true" | "1" | "yes" => true
        "false" | "0" | "no" => false
        _ => fallback
      }
    None => fallback
  }
}

///|
fn xml_attr(line : String, wanted : String) -> String? {
  for token_view in line.split(" ") {
    let token = token_view.to_owned()
    let pieces = token.split("\"").map(fn(part) { part.to_owned() }).to_array()
    if pieces.length() >= 2 && pieces[0] == wanted + "=" {
      return Some(unescape_xml(pieces[1]))
    }
  }
  None
}

///|
fn xml_text_value(line : String, tag : String) -> String {
  let prefix = "<\{tag}>"
  let suffix = "</\{tag}>"
  if line.has_prefix(prefix) && line.has_suffix(suffix) {
    let start = prefix.length()
    let finish = line.length() - suffix.length()
    line[start:finish].to_owned()
  } else {
    ""
  }
}

///|
fn unescape_xml(value : String) -> String {
  value
  .replace(old="&quot;", new="\"")
  .replace(old="&apos;", new="'")
  .replace(old="&lt;", new="<")
  .replace(old="&gt;", new=">")
  .replace(old="&amp;", new="&")
}

///|
fn parse_direction(value : String) -> Direction {
  match value.to_lower() {
    "down" => Down
    "loop" => Loop
    _ => Up
  }
}
