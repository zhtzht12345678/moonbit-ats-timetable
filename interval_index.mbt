///|
/// The category of an interval indexed by the rolling-horizon query layer.
pub(all) enum IntervalKind {
  Movement
  Platform
  Route
  Turnback
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A normalized half-open operational interval. The end is exclusive for
/// overlap queries, which makes adjacent train movements safe by default.
pub(all) struct IndexedInterval {
  id : String
  train_id : String
  resource_id : String
  start_min : Int
  end_min : Int
  kind : IntervalKind
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A bucket contains interval indexes rather than copies of intervals. This
/// keeps the index cheap to rebuild for a live snapshot.
pub(all) struct IntervalBucket {
  start_min : Int
  interval_indexes : Array[Int]
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Immutable interval index used by conflict and dashboard query adapters.
pub(all) struct IntervalIndex {
  bucket_size_min : Int
  intervals : Array[IndexedInterval]
  buckets : Array[IntervalBucket]
  source_schedule_id : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// The result of a bounded index lookup, retaining the query window for
/// auditing and pagination adapters.
pub(all) struct IntervalQuery {
  resource_id : String
  start_min : Int
  end_min : Int
  matched_count : Int
  intervals : Array[IndexedInterval]
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A pair of candidate intervals that may require domain-specific conflict
/// evaluation. The index only narrows candidates; it does not replace the
/// safety checker in `conflicts.mbt`.
pub(all) struct IntervalCandidate {
  first : IndexedInterval
  second : IndexedInterval
  overlap_start_min : Int
  overlap_end_min : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Build a bucketed index for movements, platforms and route reservations.
/// A non-positive bucket size is normalized to five minutes.
pub fn build_interval_index(
  schedule : Schedule,
  bucket_size_min? : Int = 5,
) -> IntervalIndex {
  let bucket_size = max_int(1, bucket_size_min)
  let intervals = collect_intervals(schedule)
  intervals.sort_by(interval_before)
  let buckets = []
  for i in 0..<intervals.length() {
    let interval = intervals[i]
    index_interval_into_buckets(buckets, interval, i, bucket_size)
  }
  {
    bucket_size_min: bucket_size,
    intervals,
    buckets,
    source_schedule_id: schedule.id,
  }
}

///|
/// Query one resource in a half-open time range. Results are sorted by start,
/// then end, then train ID so repeated live queries remain deterministic.
pub fn query_interval_index(
  index : IntervalIndex,
  resource_id : String,
  start_min : Int,
  end_min : Int,
) -> IntervalQuery {
  let start = min_int(start_min, end_min)
  let end = max_int(start_min, end_min)
  let candidate_indexes = bucket_candidates(index, start, end)
  let seen = []
  let output = []
  for interval_index in candidate_indexes {
    if !seen.contains(interval_index) {
      seen.push(interval_index)
      let interval = index.intervals[interval_index]
      if interval.resource_id == resource_id &&
        intervals_overlap(interval.start_min, interval.end_min, start, end) {
        output.push(interval)
      }
    }
  }
  output.sort_by(interval_before)
  {
    resource_id,
    start_min: start,
    end_min: end,
    matched_count: output.length(),
    intervals: output,
  }
}

///|
/// Return candidate pairs on one resource. Pairs are generated only once,
/// even when their intervals span several buckets.
pub fn interval_candidates(
  index : IntervalIndex,
  resource_id : String,
  start_min : Int,
  end_min : Int,
) -> Array[IntervalCandidate] {
  let query = query_interval_index(index, resource_id, start_min, end_min)
  let candidates = []
  for i in 0..<query.intervals.length() {
    for j in (i + 1)..<query.intervals.length() {
      let first = query.intervals[i]
      let second = query.intervals[j]
      if first.train_id != second.train_id &&
        intervals_overlap(
          first.start_min,
          first.end_min,
          second.start_min,
          second.end_min,
        ) {
        candidates.push({
          first,
          second,
          overlap_start_min: max_int(first.start_min, second.start_min),
          overlap_end_min: min_int(first.end_min, second.end_min),
        })
      }
    }
  }
  candidates
}

///|
/// Query all resources touched during a time window. This is useful for a
/// dashboard where the resource list is not known in advance.
pub fn query_all_resources(
  index : IntervalIndex,
  start_min : Int,
  end_min : Int,
) -> Array[IntervalQuery] {
  let resources = []
  for interval in index.intervals {
    if !resources.contains(interval.resource_id) {
      resources.push(interval.resource_id)
    }
  }
  resources.sort()
  resources.map(fn(resource_id) {
    query_interval_index(index, resource_id, start_min, end_min)
  })
}

///|
/// Summarize index size and occupancy without exposing implementation details
/// of the bucket table to a renderer.
pub fn interval_index_summary(index : IntervalIndex) -> String {
  let occupied_buckets = index.buckets.count_if(fn(bucket) {
    bucket.interval_indexes.length() > 0
  })
  "schedule=\{index.source_schedule_id}, intervals=\{index.intervals.length()}, buckets=\{index.buckets.length()}, occupied=\{occupied_buckets}, bucket_min=\{index.bucket_size_min}"
}

///|
pub fn interval_query_json(query : IntervalQuery) -> String {
  query.to_json().stringify()
}

///|
/// Return an interval kind as a stable wire label.
pub fn IntervalKind::label(self : IntervalKind) -> String {
  match self {
    Movement => "movement"
    Platform => "platform"
    Route => "route"
    Turnback => "turnback"
  }
}

///|
/// Build a small report intended for capacity and conflict dashboards.
pub fn interval_index_markdown(index : IntervalIndex) -> String {
  let builder = StringBuilder()
  builder <+ "# Interval index\n\n"
  builder <+ "- Schedule: \{index.source_schedule_id}\n"
  builder <+ "- Intervals: \{index.intervals.length()}\n"
  builder <+ "- Buckets: \{index.buckets.length()}\n"
  builder <+ "- Bucket width: \{index.bucket_size_min} min\n\n"
  builder <+
    "| Resource | Movement | Platform | Route | Total |\n|---|---:|---:|---:|---:|\n"
  for
    resource in query_all_resources(
      index,
      min_interval(index),
      max_interval(index),
    ) {
    let movement = resource.intervals.count_if(fn(item) {
      item.kind == Movement
    })
    let platform = resource.intervals.count_if(fn(item) {
      item.kind == Platform
    })
    let route = resource.intervals.count_if(fn(item) { item.kind == Route })
    builder <+
      "| \{resource.resource_id} | \{movement} | \{platform} | \{route} | \{resource.matched_count} |\n"
  }
  builder.to_string()
}

///|
fn collect_intervals(schedule : Schedule) -> Array[IndexedInterval] {
  let output = []
  for train in schedule.trains {
    collect_train_movement_intervals(schedule, train, output)
    for stop in train.stops {
      let start = stop.arrival_min
      let end = max_int(start + 1, stop.departure_min)
      output.push({
        id: "platform:\{train.id}:\{stop.station_id}:\{stop.platform}",
        train_id: train.id,
        resource_id: "platform:\{stop.station_id}:\{stop.platform}",
        start_min: start,
        end_min: end,
        kind: Platform,
      })
    }
  }
  for reservation in schedule.reservations {
    output.push({
      id: reservation.id,
      train_id: reservation.train_id,
      resource_id: "route:\{reservation.resource_id}",
      start_min: reservation.entry_min,
      end_min: max_int(
        reservation.entry_min + 1,
        reservation.exit_min + reservation.release_margin_min,
      ),
      kind: Route,
    })
  }
  output
}

///|
fn collect_train_movement_intervals(
  schedule : Schedule,
  train : Train,
  output : Array[IndexedInterval],
) -> Unit {
  if train.stops.length() < 2 {
    return
  }
  for i in 0..<(train.stops.length() - 1) {
    let first = train.stops[i]
    let second = train.stops[i + 1]
    let resource = interval_segment_id(
      schedule,
      first.station_id,
      second.station_id,
    )
    output.push({
      id: "movement:\{train.id}:\{i}",
      train_id: train.id,
      resource_id: resource,
      start_min: first.departure_min,
      end_min: max_int(first.departure_min + 1, second.arrival_min),
      kind: Movement,
    })
  }
}

///|
fn interval_segment_id(
  schedule : Schedule,
  from_station : String,
  to_station : String,
) -> String {
  for segment in schedule.segments {
    if (
        segment.from_station == from_station && segment.to_station == to_station
      ) ||
      (segment.from_station == to_station && segment.to_station == from_station) {
      return "segment:\{segment.id}"
    }
  }
  "segment:\{from_station}->\{to_station}"
}

///|
fn interval_before(first : IndexedInterval, second : IndexedInterval) -> Int {
  if first.start_min != second.start_min {
    first.start_min - second.start_min
  } else if first.end_min != second.end_min {
    first.end_min - second.end_min
  } else {
    compare_strings(first.id, second.id)
  }
}

///|
fn index_interval_into_buckets(
  buckets : Array[IntervalBucket],
  interval : IndexedInterval,
  interval_index : Int,
  bucket_size : Int,
) -> Unit {
  let first_bucket = floor_bucket(interval.start_min, bucket_size)
  let last_bucket = floor_bucket(
    max_int(interval.start_min, interval.end_min - 1),
    bucket_size,
  )
  let mut current = first_bucket
  while current <= last_bucket {
    let bucket_index = bucket_position(buckets, current)
    match bucket_index {
      Some(index) => buckets[index].interval_indexes.push(interval_index)
      None => {
        let bucket = { start_min: current, interval_indexes: [interval_index] }
        insert_bucket(buckets, bucket)
      }
    }
    current += bucket_size
  }
}

///|
fn bucket_candidates(
  index : IntervalIndex,
  start_min : Int,
  end_min : Int,
) -> Array[Int] {
  let start = floor_bucket(start_min, index.bucket_size_min)
  let end = floor_bucket(max_int(start_min, end_min - 1), index.bucket_size_min)
  let output = []
  let mut current = start
  while current <= end {
    match bucket_position(index.buckets, current) {
      Some(bucket_index) =>
        output.append(index.buckets[bucket_index].interval_indexes[:])
      None => ()
    }
    current += index.bucket_size_min
  }
  output
}

///|
fn floor_bucket(value : Int, bucket_size : Int) -> Int {
  if value >= 0 {
    value / bucket_size * bucket_size
  } else {
    (value - bucket_size + 1) / bucket_size * bucket_size
  }
}

///|
fn bucket_position(buckets : Array[IntervalBucket], start_min : Int) -> Int? {
  for i in 0..<buckets.length() {
    if buckets[i].start_min == start_min {
      return Some(i)
    }
  }
  None
}

///|
fn insert_bucket(
  buckets : Array[IntervalBucket],
  bucket : IntervalBucket,
) -> Unit {
  let mut inserted = false
  for i in 0..<buckets.length() {
    if !inserted && bucket.start_min < buckets[i].start_min {
      buckets.insert(i, bucket)
      inserted = true
    }
  }
  if !inserted {
    buckets.push(bucket)
  }
}

///|
fn min_interval(index : IntervalIndex) -> Int {
  if index.intervals.length() == 0 {
    0
  } else {
    index.intervals[0].start_min
  }
}

///|
fn max_interval(index : IntervalIndex) -> Int {
  let mut output = 0
  for interval in index.intervals {
    if interval.end_min > output {
      output = interval.end_min
    }
  }
  output
}

///|
fn compare_strings(first : String, second : String) -> Int {
  if first < second {
    -1
  } else if first > second {
    1
  } else {
    0
  }
}
