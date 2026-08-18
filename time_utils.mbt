///|
/// Parse a non-negative decimal integer without depending on a locale.
/// The parser is intentionally strict because timetable numbers must not
/// silently accept a trailing unit or exponent.
fn parse_non_negative_int(raw : String) -> Int? {
  let value = raw.trim()
  if value == "" {
    return None
  }
  let mut result = 0
  let mut seen = false
  for ch in value {
    if ch >= '0' && ch <= '9' {
      seen = true
      result = result * 10 + ch.to_int() - '0'.to_int()
    } else {
      return None
    }
  }
  if seen {
    Some(result)
  } else {
    None
  }
}

///|
fn parse_signed_int(raw : String) -> Int? {
  let value = raw.trim()
  if value == "" {
    return None
  }
  if value.has_prefix("-") {
    parse_non_negative_int(value[1:].to_owned()).map(fn(x) { 0 - x })
  } else if value.has_prefix("+") {
    parse_non_negative_int(value[1:].to_owned())
  } else {
    parse_non_negative_int(value.to_owned())
  }
}

///|
/// Parse `HH:MM` into minutes after midnight. Hours may exceed 23 for
/// after-midnight operating plans, but minutes must remain in 0..59.
pub fn parse_clock(value : String) -> Int? {
  let parts = value
    .trim()
    .split(":")
    .map(fn(part) { part.to_owned() })
    .to_array()
  if parts.length() != 2 {
    return None
  }
  let hour = parse_non_negative_int(parts[0])
  let minute = parse_non_negative_int(parts[1])
  match (hour, minute) {
    (Some(h), Some(m)) if m < 60 => Some(h * 60 + m)
    _ => None
  }
}

///|
/// Format minutes after midnight as a zero-padded clock string.
pub fn format_clock(total_min : Int) -> String {
  let normalized = if total_min < 0 { 0 } else { total_min }
  let hour = normalized / 60
  let minute = normalized % 60
  let hour_text = if hour < 10 { "0\{hour}" } else { hour.to_string() }
  let minute_text = if minute < 10 { "0\{minute}" } else { minute.to_string() }
  "\{hour_text}:\{minute_text}"
}

///|
pub fn clamp_int(value : Int, low : Int, high : Int) -> Int {
  if value < low {
    low
  } else if value > high {
    high
  } else {
    value
  }
}

///|
fn min_int(left : Int, right : Int) -> Int {
  if left < right {
    left
  } else {
    right
  }
}

///|
fn max_int(left : Int, right : Int) -> Int {
  if left > right {
    left
  } else {
    right
  }
}

///|
fn abs_int(value : Int) -> Int {
  if value < 0 {
    0 - value
  } else {
    value
  }
}

///|
fn overlap_start(a_start : Int, b_start : Int) -> Int {
  max_int(a_start, b_start)
}

///|
fn overlap_end(a_end : Int, b_end : Int) -> Int {
  min_int(a_end, b_end)
}

///|
fn intervals_overlap(
  a_start : Int,
  a_end : Int,
  b_start : Int,
  b_end : Int,
) -> Bool {
  overlap_start(a_start, b_start) < overlap_end(a_end, b_end)
}

///|
fn positive_or(value : Int, fallback : Int) -> Int {
  if value > 0 {
    value
  } else {
    fallback
  }
}

///|
fn quote_xml(value : String) -> String {
  value
  .replace(old="&", new="&amp;")
  .replace(old="<", new="&lt;")
  .replace(old=">", new="&gt;")
  .replace(old="\"", new="&quot;")
  .replace(old="'", new="&apos;")
}

///|
fn quote_json(value : String) -> String {
  value
  .replace(old="\\", new="\\\\")
  .replace(old="\"", new="\\\"")
  .replace(old="\n", new="\\n")
  .replace(old="\r", new="\\r")
}

///|
fn csv_join(values : Array[String]) -> String {
  values.join(",")
}

///|
fn split_lines(value : String) -> Array[String] {
  value
  .replace(old="\r\n", new="\n")
  .replace(old="\r", new="\n")
  .split("\n")
  .map(fn(line) { line.to_owned() })
  .to_array()
}

///|
fn append_unique(values : Array[String], value : String) -> Unit {
  if !values.contains(value) {
    values.push(value)
  }
}

///|
fn sorted_ints(values : Array[Int]) -> Array[Int] {
  let output = values.copy()
  for i in 1..<output.length() {
    let current = output[i]
    let mut j = i
    while j > 0 && output[j - 1] > current {
      output[j] = output[j - 1]
      j -= 1
    }
    output[j] = current
  }
  output
}

///|
fn unique_sorted_ints(values : Array[Int]) -> Array[Int] {
  let output = []
  for value in sorted_ints(values) {
    if output.length() == 0 || output[output.length() - 1] != value {
      output.push(value)
    }
  }
  output
}

///|
fn train_pair_key(first : String, second : String) -> String {
  if first < second {
    "\{first}|\{second}"
  } else {
    "\{second}|\{first}"
  }
}

///|
fn conflict_id(
  kind : String,
  first : String,
  second : String,
  resource : String,
) -> String {
  "\{kind}:\{train_pair_key(first, second)}:\{resource}"
}

///|
fn action_rank(kind : ActionKind) -> Int {
  match kind {
    Hold => 0
    SlowDown => 1
    SpeedUp => 2
    Skip => 3
    KeepPlan => 4
    ManualReview => 5
  }
}

///|
fn severity_rank(value : String) -> Int {
  match value {
    "critical" => 0
    "high" => 1
    "medium" => 2
    "low" => 3
    _ => 4
  }
}

///|
fn severity_from_gap(required : Int, actual : Int) -> String {
  let gap = required - actual
  if gap >= required {
    "critical"
  } else if gap >= 3 {
    "high"
  } else if gap > 0 {
    "medium"
  } else {
    "low"
  }
}

///|
fn pad_right(value : String, width : Int) -> String {
  let mut output = value
  while output.length() < width {
    output = output + " "
  }
  output
}

///|
fn repeat_char(value : String, count : Int) -> String {
  let mut output = ""
  for _ in 0..<count {
    output = output + value
  }
  output
}
