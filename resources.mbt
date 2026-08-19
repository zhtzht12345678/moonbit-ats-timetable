///|
/// Operational resource classes used by the OCC resource view.
pub(all) enum RailResourceKind {
  Block
  Platform
  Throat
  Turnback
  Junction
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A resource declaration inferred from the schedule and its reservations.
pub(all) struct RailResource {
  id : String
  kind : RailResourceKind
  label : String
  capacity : Int
  station_id : String?
  segment_id : String?
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A resource occupation window. `release_min` includes the conservative
/// release margin used by route and block calculations.
pub(all) struct ResourceWindow {
  id : String
  train_id : String
  resource_id : String
  kind : RailResourceKind
  entry_min : Int
  exit_min : Int
  release_min : Int
  route_name : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Aggregated resource pressure over a selected horizon.
pub(all) struct ResourceLoad {
  resource_id : String
  kind : RailResourceKind
  capacity : Int
  window_count : Int
  train_count : Int
  occupied_min : Int
  peak_concurrent : Int
  utilization_percent : Int
  status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Resource overlap evidence kept separate from the broader `Conflict` model
/// so tooling can inspect a resource matrix without interpreting safety rules.
pub(all) struct ResourceConflict {
  resource_id : String
  first_window_id : String
  second_window_id : String
  first_train_id : String
  second_train_id : String
  start_min : Int
  end_min : Int
  overlap_min : Int
  severity : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Complete resource catalogue for one schedule snapshot.
pub(all) struct ResourceCatalogue {
  schedule_id : String
  resources : Array[RailResource]
  windows : Array[ResourceWindow]
  loads : Array[ResourceLoad]
  conflicts : Array[ResourceConflict]
  start_min : Int
  end_min : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Return the stable label for a resource kind.
pub fn RailResourceKind::label(self : RailResourceKind) -> String {
  match self {
    Block => "block"
    Platform => "platform"
    Throat => "throat"
    Turnback => "turnback"
    Junction => "junction"
  }
}

///|
/// Infer resources and occupation windows from a schedule.
pub fn build_resource_catalogue(
  schedule : Schedule,
  start_min? : Int = 0,
  end_min? : Int = 1440,
) -> ResourceCatalogue {
  let start = min_int(start_min, end_min)
  let end = max_int(start_min, end_min)
  let resources = collect_resources(schedule)
  let windows = collect_resource_windows(schedule)
  let loads = summarize_resource_loads(resources, windows, start, end)
  let conflicts = detect_resource_overlaps(windows, start, end)
  {
    schedule_id: schedule.id,
    resources,
    windows,
    loads,
    conflicts,
    start_min: start,
    end_min: end,
  }
}

///|
/// Build the same catalogue using a selected interval index. This path is
/// useful for applications that already maintain the index for queries.
pub fn build_resource_catalogue_from_index(
  schedule : Schedule,
  index : IntervalIndex,
  start_min : Int,
  end_min : Int,
) -> ResourceCatalogue {
  let base = build_resource_catalogue(schedule, start_min~, end_min~)
  let indexed_windows = []
  for interval in index.intervals {
    if intervals_overlap(
        interval.start_min,
        interval.end_min,
        start_min,
        end_min,
      ) {
      indexed_windows.push({
        id: interval.id,
        train_id: interval.train_id,
        resource_id: interval.resource_id,
        kind: interval_kind_to_resource_kind(interval.kind),
        entry_min: interval.start_min,
        exit_min: interval.end_min,
        release_min: interval.end_min,
        route_name: interval.kind.label(),
      })
    }
  }
  let windows = if indexed_windows.length() > 0 {
    indexed_windows
  } else {
    base.windows
  }
  {
    schedule_id: base.schedule_id,
    resources: base.resources,
    windows,
    loads: summarize_resource_loads(base.resources, windows, start_min, end_min),
    conflicts: detect_resource_overlaps(windows, start_min, end_min),
    start_min: min_int(start_min, end_min),
    end_min: max_int(start_min, end_min),
  }
}

///|
/// Query occupation windows for one resource in a half-open horizon.
pub fn resource_windows_in(
  catalogue : ResourceCatalogue,
  resource_id : String,
  start_min : Int,
  end_min : Int,
) -> Array[ResourceWindow] {
  let output = catalogue.windows.filter(fn(window) {
    window.resource_id == resource_id &&
    intervals_overlap(window.entry_min, window.release_min, start_min, end_min)
  })
  output.sort_by(resource_window_before)
  output
}

///|
/// Return the resources whose pressure is at or above the selected threshold.
pub fn critical_resource_ids(
  catalogue : ResourceCatalogue,
  threshold_percent? : Int = 100,
) -> Array[String] {
  let threshold = max_int(0, threshold_percent)
  let output = []
  for load in catalogue.loads {
    if load.utilization_percent >= threshold || load.status == "critical" {
      output.push(load.resource_id)
    }
  }
  output
}

///|
/// Count unique trains occupying a resource in the selected horizon.
pub fn resource_train_count(
  catalogue : ResourceCatalogue,
  resource_id : String,
  start_min : Int,
  end_min : Int,
) -> Int {
  let trains = []
  for window in resource_windows_in(catalogue, resource_id, start_min, end_min) {
    if !trains.contains(window.train_id) {
      trains.push(window.train_id)
    }
  }
  trains.length()
}

///|
/// Export the catalogue for a resource heat-map or a diagnostic snapshot.
pub fn resource_catalogue_json(catalogue : ResourceCatalogue) -> String {
  catalogue.to_json().stringify()
}

///|
pub fn resource_conflicts_json(conflicts : Array[ResourceConflict]) -> String {
  conflicts.to_json().stringify()
}

///|
/// Human-readable resource report with separate load and overlap sections.
pub fn resource_catalogue_markdown(catalogue : ResourceCatalogue) -> String {
  let builder = StringBuilder()
  builder <+ "# Resource catalogue\n\n"
  builder <+ "Schedule: \{catalogue.schedule_id}\n\n"
  builder <+
    "| Resource | Kind | Windows | Trains | Peak | Utilization (%) | Status |\n|---|---|---:|---:|---:|---:|---|\n"
  for load in catalogue.loads {
    builder <+
      "| \{load.resource_id} | \{load.kind.label()} | \{load.window_count} | \{load.train_count} | \{load.peak_concurrent} | \{load.utilization_percent} | \{load.status} |\n"
  }
  builder <+ "\n## Overlaps\n\n"
  if catalogue.conflicts.length() == 0 {
    builder <+ "No resource overlaps in the selected horizon.\n"
  } else {
    builder <+ "| Resource | Trains | Window | Severity |\n|---|---|---|---|\n"
    for conflict in catalogue.conflicts {
      builder <+
        "| \{conflict.resource_id} | \{conflict.first_train_id}/\{conflict.second_train_id} | \{conflict.start_min}-\{conflict.end_min} | \{conflict.severity} |\n"
    }
  }
  builder.to_string()
}

///|
fn collect_resources(schedule : Schedule) -> Array[RailResource] {
  let output = []
  for segment in schedule.segments {
    push_resource(output, {
      id: "segment:\{segment.id}",
      kind: Block,
      label: "\{segment.from_station}-\{segment.to_station}",
      capacity: 1,
      station_id: None,
      segment_id: Some(segment.id),
    })
    if segment.throat_resource is Some(resource_id) {
      push_resource(output, {
        id: "route:\{resource_id}",
        kind: Throat,
        label: resource_id,
        capacity: 1,
        station_id: None,
        segment_id: Some(segment.id),
      })
    }
  }
  for station in schedule.stations {
    for platform in 1..<=max_int(1, station.platform_count) {
      push_resource(output, {
        id: "platform:\{station.id}:\{platform}",
        kind: Platform,
        label: "\{station.name} / \{platform}",
        capacity: 1,
        station_id: Some(station.id),
        segment_id: None,
      })
    }
  }
  for reservation in schedule.reservations {
    if reservation.route_name.contains("turnback") {
      push_resource(output, {
        id: "turnback:\{reservation.resource_id}",
        kind: Turnback,
        label: reservation.route_name,
        capacity: 1,
        station_id: None,
        segment_id: None,
      })
    }
  }
  output.sort_by(resource_before)
  output
}

///|
fn push_resource(
  resources : Array[RailResource],
  resource : RailResource,
) -> Unit {
  if resources.all(fn(item) { item.id != resource.id }) {
    resources.push(resource)
  }
}

///|
fn collect_resource_windows(schedule : Schedule) -> Array[ResourceWindow] {
  let output = []
  for train in schedule.trains {
    if train.stops.length() >= 2 {
      for i in 0..<(train.stops.length() - 1) {
        let first = train.stops[i]
        let second = train.stops[i + 1]
        let segment = resource_segment(
          schedule,
          first.station_id,
          second.station_id,
        )
        let entry = first.departure_min
        let exit = max_int(entry + 1, second.arrival_min)
        output.push({
          id: "block:\{train.id}:\{i}",
          train_id: train.id,
          resource_id: "segment:\{segment.id}",
          kind: Block,
          entry_min: entry,
          exit_min: exit,
          release_min: exit,
          route_name: "block",
        })
      }
    }
    for stop in train.stops {
      output.push({
        id: "platform:\{train.id}:\{stop.station_id}:\{stop.platform}",
        train_id: train.id,
        resource_id: "platform:\{stop.station_id}:\{stop.platform}",
        kind: Platform,
        entry_min: stop.arrival_min,
        exit_min: max_int(stop.arrival_min + 1, stop.departure_min),
        release_min: max_int(stop.arrival_min + 1, stop.departure_min),
        route_name: "platform",
      })
    }
  }
  for reservation in schedule.reservations {
    let release = max_int(reservation.entry_min + 1, reservation.exit_min)
    output.push({
      id: reservation.id,
      train_id: reservation.train_id,
      resource_id: "route:\{reservation.resource_id}",
      kind: if reservation.route_name.contains("turnback") {
        Turnback
      } else {
        Throat
      },
      entry_min: reservation.entry_min,
      exit_min: reservation.exit_min,
      release_min: release + max_int(0, reservation.release_margin_min),
      route_name: reservation.route_name,
    })
  }
  output
}

///|
fn summarize_resource_loads(
  resources : Array[RailResource],
  windows : Array[ResourceWindow],
  start_min : Int,
  end_min : Int,
) -> Array[ResourceLoad] {
  let output = []
  for resource in resources {
    let selected = windows.filter(fn(window) {
      window.resource_id == resource.id &&
      intervals_overlap(
        window.entry_min,
        window.release_min,
        start_min,
        end_min,
      )
    })
    let trains = []
    for window in selected {
      if !trains.contains(window.train_id) {
        trains.push(window.train_id)
      }
    }
    let occupied = selected.fold(init=0, fn(total, window) {
      total +
      overlap_duration(window.entry_min, window.release_min, start_min, end_min)
    })
    let peak = peak_concurrent(selected, start_min, end_min)
    let horizon = max_int(1, end_min - start_min)
    let utilization = percentage(
      occupied,
      horizon * max_int(1, resource.capacity),
    )
    output.push({
      resource_id: resource.id,
      kind: resource.kind,
      capacity: resource.capacity,
      window_count: selected.length(),
      train_count: trains.length(),
      occupied_min: occupied,
      peak_concurrent: peak,
      utilization_percent: utilization,
      status: resource_pressure_status(peak, resource.capacity, utilization),
    })
  }
  output
}

///|
fn detect_resource_overlaps(
  windows : Array[ResourceWindow],
  start_min : Int,
  end_min : Int,
) -> Array[ResourceConflict] {
  let output = []
  for i in 0..<windows.length() {
    for j in (i + 1)..<windows.length() {
      let first = windows[i]
      let second = windows[j]
      if first.resource_id == second.resource_id &&
        first.train_id != second.train_id &&
        intervals_overlap(
          first.entry_min,
          first.release_min,
          start_min,
          end_min,
        ) &&
        intervals_overlap(
          second.entry_min,
          second.release_min,
          start_min,
          end_min,
        ) &&
        intervals_overlap(
          first.entry_min,
          first.release_min,
          second.entry_min,
          second.release_min,
        ) {
        let overlap_start = max_int(
          max_int(first.entry_min, second.entry_min),
          start_min,
        )
        let overlap_end = min_int(
          min_int(first.release_min, second.release_min),
          end_min,
        )
        let overlap = max_int(0, overlap_end - overlap_start)
        output.push({
          resource_id: first.resource_id,
          first_window_id: first.id,
          second_window_id: second.id,
          first_train_id: first.train_id,
          second_train_id: second.train_id,
          start_min: overlap_start,
          end_min: overlap_end,
          overlap_min: overlap,
          severity: if first.kind == Throat || first.kind == Turnback {
            "critical"
          } else {
            "high"
          },
          message: "resource occupation windows overlap",
        })
      }
    }
  }
  output.sort_by(resource_conflict_before)
  output
}

///|
fn peak_concurrent(
  windows : Array[ResourceWindow],
  start_min : Int,
  end_min : Int,
) -> Int {
  let mut best = 0
  let mut minute = start_min
  while minute < end_min {
    let active = windows.count_if(fn(window) {
      window.entry_min <= minute && window.release_min > minute
    })
    if active > best {
      best = active
    }
    minute += 1
  }
  best
}

///|
fn resource_pressure_status(
  peak : Int,
  capacity : Int,
  utilization : Int,
) -> String {
  if peak > capacity || utilization >= 120 {
    "critical"
  } else if utilization >= 85 {
    "busy"
  } else {
    "normal"
  }
}

///|
fn resource_segment(
  schedule : Schedule,
  from_station : String,
  to_station : String,
) -> LineSegment {
  for segment in schedule.segments {
    if (
        segment.from_station == from_station && segment.to_station == to_station
      ) ||
      (segment.from_station == to_station && segment.to_station == from_station) {
      return segment
    }
  }
  segment(
    id="\{from_station}->\{to_station}",
    from_station~,
    to_station~,
    distance_m=1,
    min_run_min=1,
    scheduled_run_min=1,
    max_run_min=1,
    headway_min=1,
  )
}

///|
fn interval_kind_to_resource_kind(kind : IntervalKind) -> RailResourceKind {
  match kind {
    Movement => Block
    Platform => Platform
    Route => Throat
    Turnback => Turnback
  }
}

///|
fn overlap_duration(
  first_start : Int,
  first_end : Int,
  second_start : Int,
  second_end : Int,
) -> Int {
  max_int(
    0,
    min_int(first_end, second_end) - max_int(first_start, second_start),
  )
}

///|
fn resource_before(first : RailResource, second : RailResource) -> Int {
  compare_strings(first.id, second.id)
}

///|
fn resource_window_before(
  first : ResourceWindow,
  second : ResourceWindow,
) -> Int {
  if first.entry_min != second.entry_min {
    first.entry_min - second.entry_min
  } else {
    compare_strings(first.id, second.id)
  }
}

///|
fn resource_conflict_before(
  first : ResourceConflict,
  second : ResourceConflict,
) -> Int {
  if first.start_min != second.start_min {
    first.start_min - second.start_min
  } else {
    compare_strings(first.resource_id, second.resource_id)
  }
}
