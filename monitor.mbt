///|
/// Operational thresholds for real-time telemetry ingestion.
pub(all) struct MonitorConfig {
  stale_after_min : Int
  delay_growth_threshold_min : Int
  position_jump_threshold_m : Int
  max_event_age_min : Int
  alert_on_unknown_train : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn default_monitor_config() -> MonitorConfig {
  {
    stale_after_min: 3,
    delay_growth_threshold_min: 2,
    position_jump_threshold_m: 3000,
    max_event_age_min: 30,
    alert_on_unknown_train: true,
  }
}

///|
/// In-memory monitor state. It is deterministic and transport agnostic: an
/// adapter may call ingest from a WebSocket, file replay, or message bus.
pub(all) struct Monitor {
  schedule : Schedule
  config : MonitorConfig
  mut runtimes : Array[TrainRuntime]
  mut alerts : Array[MonitorAlert]
  mut telemetry_count : Int
} derive(Debug)

///|
pub fn Monitor::new(
  schedule : Schedule,
  config? : MonitorConfig = default_monitor_config(),
) -> Monitor {
  { schedule, config, runtimes: [], alerts: [], telemetry_count: 0 }
}

///|
pub fn Monitor::ingest(self : Monitor, event : TelemetryEvent) -> Unit {
  self.telemetry_count += 1
  if self.schedule.train_by_id(event.train_id) is None {
    if self.config.alert_on_unknown_train {
      self.alerts.push({
        id: "unknown:\{event.event_id}",
        kind: UnknownTrain,
        train_id: event.train_id,
        at_min: event.observed_min,
        severity: "high",
        message: "telemetry references a train not present in the active schedule",
        acknowledged: false,
      })
    }
    return
  }
  match runtime_index(self.runtimes, event.train_id) {
    Some(index) => {
      let previous = self.runtimes[index]
      if event.observed_min < previous.observed_min {
        self.alerts.push({
          id: "out-of-order:\{event.event_id}",
          kind: StaleData,
          train_id: event.train_id,
          at_min: event.observed_min,
          severity: "medium",
          message: "telemetry arrived older than the current runtime state",
          acknowledged: false,
        })
      } else {
        check_position_jump(self, previous, event)
        check_delay_growth(self, previous, event)
        self.runtimes[index] = {
          train_id: event.train_id,
          observed_min: event.observed_min,
          station_id: event.station_id,
          position_m: event.position_m,
          delay_min: event.delay_min,
          speed_kmh: event.speed_kmh,
          mode: event.mode,
          source: event.source,
          event_count: previous.event_count + 1,
        }
      }
    }
    None =>
      self.runtimes.push({
        train_id: event.train_id,
        observed_min: event.observed_min,
        station_id: event.station_id,
        position_m: event.position_m,
        delay_min: event.delay_min,
        speed_kmh: event.speed_kmh,
        mode: event.mode,
        source: event.source,
        event_count: 1,
      })
  }
}

///|
pub fn Monitor::ingest_all(
  self : Monitor,
  events : Array[TelemetryEvent],
) -> Unit {
  for event in events {
    self.ingest(event)
  }
}

///|
pub fn Monitor::snapshot(self : Monitor, at_min : Int) -> MonitorSnapshot {
  let live_runtimes = self.runtimes.copy()
  let live_alerts = self.alerts.copy()
  for train in self.schedule.trains {
    if runtime_index(live_runtimes, train.id) is None {
      let planned_time = match train.first_time() {
        Some(time) => time
        None => at_min
      }
      if at_min - planned_time > self.config.stale_after_min &&
        at_min >= planned_time {
        live_alerts.push({
          id: "missing:\{train.id}:\{at_min}",
          kind: StaleData,
          train_id: train.id,
          at_min,
          severity: "low",
          message: "no telemetry has been received for a planned train",
          acknowledged: false,
        })
      }
    }
  }
  for runtime in live_runtimes {
    if at_min - runtime.observed_min > self.config.stale_after_min {
      live_alerts.push({
        id: "stale:\{runtime.train_id}:\{at_min}",
        kind: StaleData,
        train_id: runtime.train_id,
        at_min,
        severity: "high",
        message: "latest telemetry is older than the configured freshness window",
        acknowledged: false,
      })
    }
  }
  {
    schedule_id: self.schedule.id,
    at_min,
    runtimes: live_runtimes,
    alerts: deduplicate_alerts(live_alerts),
    telemetry_count: self.telemetry_count,
    stale_after_min: self.config.stale_after_min,
  }
}

///|
pub fn Monitor::current_runtimes(self : Monitor) -> Array[TrainRuntime] {
  self.runtimes.copy()
}

///|
pub fn Monitor::current_alerts(self : Monitor) -> Array[MonitorAlert] {
  self.alerts.copy()
}

///|
pub fn Monitor::conflicts(self : Monitor, at_min : Int) -> Array[Conflict] {
  detect_realtime_conflicts(self.schedule, self.runtimes) +
  stale_conflicts(self.snapshot(at_min))
}

///|
pub fn Monitor::dispatch_plan(
  self : Monitor,
  at_min : Int,
  policy? : DispatchPolicy = default_dispatch_policy(),
) -> Array[DispatchRecommendation] {
  let snapshot = self.snapshot(at_min)
  let conflicts = detect_realtime_conflicts(self.schedule, snapshot.runtimes)
  suggest_dispatches(self.schedule, conflicts, snapshot.runtimes, policy~)
}

///|
fn runtime_index(runtimes : Array[TrainRuntime], train_id : String) -> Int? {
  for i, runtime in runtimes {
    if runtime.train_id == train_id {
      return Some(i)
    }
  }
  None
}

///|
fn check_position_jump(
  monitor : Monitor,
  previous : TrainRuntime,
  event : TelemetryEvent,
) -> Unit {
  if abs_int(event.position_m - previous.position_m) >
    monitor.config.position_jump_threshold_m &&
    event.observed_min == previous.observed_min {
    monitor.alerts.push({
      id: "jump:\{event.event_id}",
      kind: PositionJump,
      train_id: event.train_id,
      at_min: event.observed_min,
      severity: "high",
      message: "position changed too far without a time advance",
      acknowledged: false,
    })
  }
}

///|
fn check_delay_growth(
  monitor : Monitor,
  previous : TrainRuntime,
  event : TelemetryEvent,
) -> Unit {
  if event.delay_min - previous.delay_min >=
    monitor.config.delay_growth_threshold_min {
    monitor.alerts.push({
      id: "delay:\{event.event_id}",
      kind: DelayGrowth,
      train_id: event.train_id,
      at_min: event.observed_min,
      severity: if event.delay_min >= 10 {
        "high"
      } else {
        "medium"
      },
      message: "delay has increased beyond the configured growth threshold",
      acknowledged: false,
    })
  }
}

///|
fn deduplicate_alerts(alerts : Array[MonitorAlert]) -> Array[MonitorAlert] {
  let output = []
  let seen = []
  for alert in alerts {
    if !seen.contains(alert.id) {
      seen.push(alert.id)
      output.push(alert)
    }
  }
  output
}

///|
fn stale_conflicts(snapshot : MonitorSnapshot) -> Array[Conflict] {
  let output = []
  for alert in snapshot.alerts {
    if alert.kind is StaleData {
      output.push({
        id: "stale-conflict:\{alert.id}",
        kind: StaleTelemetry,
        severity: alert.severity,
        resource_id: "telemetry",
        first_train_id: alert.train_id,
        second_train_id: "",
        start_min: alert.at_min,
        end_min: alert.at_min + snapshot.stale_after_min,
        required_separation_min: snapshot.stale_after_min,
        actual_separation_min: 0,
        message: alert.message,
        evidence: "monitor freshness check",
      })
    }
  }
  output
}

///|
pub fn monitor_snapshot_json(snapshot : MonitorSnapshot) -> String {
  snapshot.to_json().stringify()
}

///|
pub fn monitor_alert_summary(alerts : Array[MonitorAlert]) -> String {
  if alerts.length() == 0 {
    return "no active alerts"
  }
  let mut high = 0
  let mut medium = 0
  let mut low = 0
  for alert in alerts {
    match alert.severity {
      "high" | "critical" => high += 1
      "medium" => medium += 1
      _ => low += 1
    }
  }
  "\{alerts.length()} alert(s): high=\{high}, medium=\{medium}, low=\{low}"
}
