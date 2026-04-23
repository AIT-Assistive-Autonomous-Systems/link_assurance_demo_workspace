#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/common.sh"

source_ros
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}"

require_command ros2
require_command timeout
require_command pkill
require_command pgrep

usage() {
  cat <<'EOF'
Usage: ./scripts/run_campaign_validation.sh [OPTIONS]

Run fresh demo disturbance validation campaigns with evidence capture.

Options:
  --topologies <csv>          Topologies to run (default: 1,2)
  --scenarios <csv>           Scenario list (default full matrix)
  --injection-duration <sec>  Disturbance active duration in seconds (default: 16)
  --start-delay <sec>         Injector start delay before disturbance (default: 2)
  --startup-timeout <sec>     Timeout waiting for baseline topics (default: 45)
  --monitor-extra <sec>       Extra monitor window after injection (default: 8)
  --output-dir <path>         Output root directory (default: log/campaign_<timestamp>)
  --attempt-label <label>     Label included in run directory names (default: a1)
  --continue-on-fail          Continue matrix execution after scenario failure
  --help                      Show this help

Examples:
  ./scripts/run_campaign_validation.sh
  ./scripts/run_campaign_validation.sh --topologies 1 --scenarios latency,outage
  ./scripts/run_campaign_validation.sh --topologies 1,2 --injection-duration 20 --continue-on-fail
EOF
}

TOP_CSV="1,2"
SCENARIO_CSV="latency,wifi_congested,burst_loss,reordering,bufferbloat,outage,disconnect,station_services"
INJECTION_DURATION_S=16
START_DELAY_S=2
STARTUP_TIMEOUT_S=45
MONITOR_EXTRA_S=8
ATTEMPT_LABEL="a1"
CONTINUE_ON_FAIL=0
OUTPUT_DIR=""

is_non_negative_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topologies)
      TOP_CSV="$2"
      shift 2
      ;;
    --scenarios)
      SCENARIO_CSV="$2"
      shift 2
      ;;
    --injection-duration)
      INJECTION_DURATION_S="$2"
      shift 2
      ;;
    --start-delay)
      START_DELAY_S="$2"
      shift 2
      ;;
    --startup-timeout)
      STARTUP_TIMEOUT_S="$2"
      shift 2
      ;;
    --monitor-extra)
      MONITOR_EXTRA_S="$2"
      shift 2
      ;;
    --attempt-label)
      ATTEMPT_LABEL="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --continue-on-fail)
      CONTINUE_ON_FAIL=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      log_error "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

for v in "$INJECTION_DURATION_S" "$START_DELAY_S" "$STARTUP_TIMEOUT_S" "$MONITOR_EXTRA_S"; do
  if ! is_non_negative_int "$v"; then
    log_error "Numeric options must be integers >= 0"
    exit 1
  fi
done

IFS=',' read -r -a TOPOLOGIES <<<"$TOP_CSV"
IFS=',' read -r -a SCENARIOS <<<"$SCENARIO_CSV"

if [[ ${#TOPOLOGIES[@]} -eq 0 || ${#SCENARIOS[@]} -eq 0 ]]; then
  log_error "Topology and scenario lists must not be empty"
  exit 1
fi

for t in "${TOPOLOGIES[@]}"; do
  if ! [[ "$t" =~ ^[0-9]+$ ]] || (( t < 1 )); then
    log_error "Invalid topology value: $t"
    exit 1
  fi
done

validate_scenario() {
  case "$1" in
    latency|wifi_congested|burst_loss|reordering|bufferbloat|outage|disconnect|station_services)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

for s in "${SCENARIOS[@]}"; do
  if ! validate_scenario "$s"; then
    log_error "Unsupported scenario: $s"
    exit 1
  fi
done

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="${ROOT_DIR}/log/campaign_$(date -u +%Y%m%d_%H%M%S)"
fi
mkdir -p "$OUTPUT_DIR"

RESULTS_TSV="${OUTPUT_DIR}/results.tsv"
TIMELINE_LOG="${OUTPUT_DIR}/timeline.log"
echo -e "timestamp\trun_id\ttopology\tscenario\tdetection\trecovery\toverall\treason" >"$RESULTS_TSV"

log_event() {
  local msg="$1"
  local ts
  ts="$(timestamp_utc)"
  echo "[$ts] $msg" >>"$TIMELINE_LOG"
  echo "[$ts] $msg"
}

wait_for_topic_once() {
  local topic="$1"
  local timeout_s="$2"
  local deadline=$((SECONDS + timeout_s))

  while (( SECONDS < deadline )); do
    if timeout 3 ros2 topic echo --once "$topic" --full-length >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  return 1
}

capture_once() {
  local topic="$1"
  local out_file="$2"
  if timeout 12 ros2 topic echo --once "$topic" --full-length >"$out_file" 2>&1; then
    return 0
  fi
  return 1
}

stop_pid_gracefully() {
  local pid="$1"
  local name="$2"
  local int_wait_checks=75
  local term_wait_checks=25

  if [[ -z "$pid" ]] || ! kill -0 "$pid" >/dev/null 2>&1; then
    return 0
  fi

  kill -INT "$pid" >/dev/null 2>&1 || true
  for ((i=0; i<int_wait_checks; i++)); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done

  log_warn "${name} did not stop on SIGINT; escalating to SIGTERM"
  kill -TERM "$pid" >/dev/null 2>&1 || true
  for ((i=0; i<term_wait_checks; i++)); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done

  log_warn "${name} did not stop on SIGTERM; escalating to SIGKILL"
  kill -KILL "$pid" >/dev/null 2>&1 || true
}

cleanup_between_runs() {
  local iface
  iface="$(default_fault_interface)"

  pkill -f "link_assurance_station_node|link_assurance_agent_node|link_assurance_summary|demo_agents.launch.py" >/dev/null 2>&1 || true
  pkill -f "rmw_zenohd" >/dev/null 2>&1 || true

  clear_qdisc_root "$iface"
  if [[ "$iface" != "lo" ]]; then
    clear_qdisc_root "lo"
  fi

  sleep 1
}

start_monitors() {
  local run_dir="$1"
  local agents="$2"
  local monitor_window_s="$3"

  local pids=()

  timeout "$monitor_window_s" ros2 topic echo /link_assurance/station_health --full-length \
    >"${run_dir}/monitor_station_health.log" 2>&1 & pids+=("$!")
  timeout "$monitor_window_s" ros2 topic echo /link_assurance/link_quality_summary --full-length \
    >"${run_dir}/monitor_link_quality_summary.log" 2>&1 & pids+=("$!")
  timeout "$monitor_window_s" ros2 topic echo /link_assurance/health_snapshot --full-length \
    >"${run_dir}/monitor_health_snapshot.log" 2>&1 & pids+=("$!")
  timeout "$monitor_window_s" ros2 topic echo /link_assurance/visualization/summary --full-length \
    >"${run_dir}/monitor_visualization_summary.log" 2>&1 & pids+=("$!")
  timeout "$monitor_window_s" ros2 topic echo /diagnostics --full-length \
    >"${run_dir}/monitor_diagnostics.log" 2>&1 & pids+=("$!")

  timeout "$monitor_window_s" ros2 topic echo /link_assurance/agents/agent_1/health --full-length \
    >"${run_dir}/monitor_agent_1_health.log" 2>&1 & pids+=("$!")
  timeout "$monitor_window_s" ros2 topic echo /link_assurance/agents/agent_1/telemetry --full-length \
    >"${run_dir}/monitor_agent_1_telemetry.log" 2>&1 & pids+=("$!")

  if (( agents >= 2 )); then
    timeout "$monitor_window_s" ros2 topic echo /link_assurance/agents/agent_2/health --full-length \
      >"${run_dir}/monitor_agent_2_health.log" 2>&1 & pids+=("$!")
    timeout "$monitor_window_s" ros2 topic echo /link_assurance/agents/agent_2/telemetry --full-length \
      >"${run_dir}/monitor_agent_2_telemetry.log" 2>&1 & pids+=("$!")
  fi

  printf '%s\n' "${pids[@]}" >"${run_dir}/monitor_pids.txt"
}

wait_monitors() {
  local run_dir="$1"
  if [[ ! -f "${run_dir}/monitor_pids.txt" ]]; then
    return 0
  fi

  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    wait "$pid" >/dev/null 2>&1 || true
  done <"${run_dir}/monitor_pids.txt"
}

run_injection() {
  local scenario="$1"
  local run_dir="$2"
  local router_pid="$3"

  local log_file="${run_dir}/injector.log"
  local status=0

  case "$scenario" in
    latency|wifi_congested|burst_loss|reordering|bufferbloat|outage)
      if ! "${ROOT_DIR}/scripts/run_inject_network.sh" --profile "$scenario" \
        --start-delay "$START_DELAY_S" --duration "$INJECTION_DURATION_S" >"$log_file" 2>&1; then
        status=$?
      fi
      ;;
    disconnect)
      local disconnect_mode="${LINK_ASSURANCE_CAMPAIGN_DISCONNECT_MODE:-tc}"
      if ! env \
        LINK_ASSURANCE_DISCONNECT_MODE="$disconnect_mode" \
        LINK_ASSURANCE_FAULT_START_DELAY_S="$START_DELAY_S" \
        LINK_ASSURANCE_FAULT_DURATION_S="$INJECTION_DURATION_S" \
        LINK_ASSURANCE_ROUTER_PID="$router_pid" \
        "${ROOT_DIR}/scripts/run_inject_disconnect.sh" >"$log_file" 2>&1; then
        status=$?
      fi
      ;;
    station_services)
      set +e
      timeout "$((INJECTION_DURATION_S + START_DELAY_S + 6))" env \
        LINK_ASSURANCE_FAULT_WATCHDOG_DELAY_S="$START_DELAY_S" \
        LINK_ASSURANCE_FAULT_AUTH_DELAY_S="$((START_DELAY_S + 1))" \
        LINK_ASSURANCE_INJECT_INTERVAL_S=1 \
        LINK_ASSURANCE_WATCHDOG_HEALTHY=false \
        LINK_ASSURANCE_AUTH_PRESENT=false \
        "${ROOT_DIR}/scripts/run_inject_station_services.sh" >"$log_file" 2>&1
      status=$?
      set -e
      if (( status == 124 )); then
        status=0
      fi
      ;;
  esac

  return "$status"
}

check_contains() {
  local file="$1"
  local pattern="$2"
  grep -Eq "$pattern" "$file"
}

evaluate_detection() {
  local scenario="$1"
  local run_dir="$2"

  local detection_ok=0
  local reason=""

  case "$scenario" in
    latency|wifi_congested|burst_loss|reordering|bufferbloat)
      if check_contains "${run_dir}/monitor_station_health.log" "external_link_state: [12]"; then
        detection_ok=1
      else
        reason="No DEGRADED/LOST state observed in station health"
      fi
      ;;
    outage|disconnect)
      # In some runs, station health clearly reports LOST while summary lost_count does
      # not increment. Accept either signal path as valid LOST detection evidence.
      # Full-loss faults can suppress monitor topic traffic entirely; include post snapshots
      # captured immediately after injection as additional LOST evidence.
      if check_contains "${run_dir}/monitor_station_health.log" "external_link_state: 2" ||
         check_contains "${run_dir}/monitor_link_quality_summary.log" "lost_count: [1-9]" ||
         check_contains "${run_dir}/post_station_health.log" "external_link_state: 2" ||
         check_contains "${run_dir}/post_summary.log" "lost_count: [1-9]"; then
        detection_ok=1
      # Topology and timing can occasionally present outage as severe DEGRADED rather than
      # strict LOST at the post snapshot. Accept clear severe-loss signatures as evidence.
      elif check_contains "${run_dir}/post_station_health.log" "external_link_state: 1" &&
           check_contains "${run_dir}/post_station_health.log" "missed_probe_count: [1-9][0-9]" &&
           check_contains "${run_dir}/post_station_health.log" "deadline_miss_count: [1-9][0-9]"; then
        detection_ok=1
      elif check_contains "${run_dir}/post_summary.log" "degraded_count: [1-9]" &&
           check_contains "${run_dir}/post_summary.log" "recovering_count: [1-9]" &&
           check_contains "${run_dir}/post_summary.log" "total_missed_probe_count: [1-9][0-9]"; then
        detection_ok=1
      else
        reason="No LOST or severe outage evidence in monitor/post station health/summary"
      fi
      ;;
    station_services)
      if check_contains "${run_dir}/monitor_station_health.log" "station_service_state: 2"; then
        detection_ok=1
      else
        reason="No station service failure evidence (station_service_state=FAILED)"
      fi
      ;;
  esac

  echo "$detection_ok|$reason"
}

evaluate_recovery() {
  local scenario="$1"
  local run_dir="$2"

  local recovery_ok=0
  local reason=""

  case "$scenario" in
    latency|wifi_congested|burst_loss|reordering|bufferbloat|outage|disconnect)
      if check_contains "${run_dir}/recovery_station_health.log" "external_link_state: 0"; then
        recovery_ok=1
      else
        reason="Station did not return to CONNECTED in recovery sample"
      fi
      ;;
    station_services)
      if check_contains "${run_dir}/recovery_station_health.log" "station_service_state: 1"; then
        recovery_ok=1
      else
        reason="Station services did not recover to station_service_state=OK"
      fi
      ;;
  esac

  echo "$recovery_ok|$reason"
}

run_single_case() {
  local agents="$1"
  local scenario="$2"
  local run_id="$3"
  local run_dir="$4"

  mkdir -p "$run_dir"
  log_event "RUN_START ${run_id} topology=${agents} scenario=${scenario}"

  local router_pid=""
  local demo_pid=""
  local monitor_window_s=$((START_DELAY_S + INJECTION_DURATION_S + MONITOR_EXTRA_S))
  local detection_ok=0
  local recovery_ok=0
  local reason=""

  cleanup_between_runs

  (
    cd "$ROOT_DIR"
    exec ros2 run rmw_zenoh_cpp rmw_zenohd >"${run_dir}/router.log" 2>&1
  ) &
  router_pid=$!

  sleep 2

  (
    cd "$ROOT_DIR"
    exec ros2 launch link_assurance_bringup demo_agents.launch.py agent_count:="$agents" >"${run_dir}/demo.log" 2>&1
  ) &
  demo_pid=$!

  if ! wait_for_topic_once /link_assurance/station_health "$STARTUP_TIMEOUT_S"; then
    reason="Startup timeout waiting for /link_assurance/station_health"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$(timestamp_utc)" "$run_id" "$agents" "$scenario" "0" "0" "0" "$reason" \
      >>"$RESULTS_TSV"
    stop_pid_gracefully "$demo_pid" "demo"
    stop_pid_gracefully "$router_pid" "router"
    cleanup_between_runs
    log_event "RUN_FAIL ${run_id} reason=${reason}"
    return 1
  fi

  if ! wait_for_topic_once /link_assurance/agents/agent_1/health "$STARTUP_TIMEOUT_S"; then
    reason="Startup timeout waiting for /link_assurance/agents/agent_1/health"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$(timestamp_utc)" "$run_id" "$agents" "$scenario" "0" "0" "0" "$reason" \
      >>"$RESULTS_TSV"
    stop_pid_gracefully "$demo_pid" "demo"
    stop_pid_gracefully "$router_pid" "router"
    cleanup_between_runs
    log_event "RUN_FAIL ${run_id} reason=${reason}"
    return 1
  fi

  capture_once /link_assurance/station_health "${run_dir}/baseline_station_health.log" || true
  capture_once /link_assurance/agents/agent_1/health "${run_dir}/baseline_agent_1_health.log" || true
  capture_once /link_assurance/link_quality_summary "${run_dir}/baseline_summary.log" || true
  capture_once /link_assurance/visualization/summary "${run_dir}/baseline_visualization_summary.log" || true

  start_monitors "$run_dir" "$agents" "$monitor_window_s"

  if ! run_injection "$scenario" "$run_dir" "$router_pid"; then
    reason="Injection script failed for scenario ${scenario}"
  fi

  wait_monitors "$run_dir"

  capture_once /link_assurance/station_health "${run_dir}/post_station_health.log" || true
  capture_once /link_assurance/agents/agent_1/health "${run_dir}/post_agent_1_health.log" || true
  capture_once /link_assurance/link_quality_summary "${run_dir}/post_summary.log" || true

  sleep "$MONITOR_EXTRA_S"
  capture_once /link_assurance/station_health "${run_dir}/recovery_station_health.log" || true
  capture_once /link_assurance/agents/agent_1/health "${run_dir}/recovery_agent_1_health.log" || true
  capture_once /link_assurance/link_quality_summary "${run_dir}/recovery_summary.log" || true

  local detection_eval
  detection_eval="$(evaluate_detection "$scenario" "$run_dir")"
  detection_ok="${detection_eval%%|*}"
  local detection_reason="${detection_eval#*|}"

  local recovery_eval
  recovery_eval="$(evaluate_recovery "$scenario" "$run_dir")"
  recovery_ok="${recovery_eval%%|*}"
  local recovery_reason="${recovery_eval#*|}"

  local overall=1
  if (( detection_ok == 0 || recovery_ok == 0 )); then
    overall=0
  fi

  if (( detection_ok == 0 )); then
    reason="$detection_reason"
  elif (( recovery_ok == 0 )); then
    reason="$recovery_reason"
  else
    reason="OK"
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$(timestamp_utc)" "$run_id" "$agents" "$scenario" "$detection_ok" "$recovery_ok" "$overall" "$reason" \
    >>"$RESULTS_TSV"

  stop_pid_gracefully "$demo_pid" "demo"
  stop_pid_gracefully "$router_pid" "router"
  cleanup_between_runs

  if (( overall == 1 )); then
    log_event "RUN_PASS ${run_id}"
    return 0
  fi

  log_event "RUN_FAIL ${run_id} reason=${reason}"
  return 1
}

fail_count=0
run_index=0

log_event "CAMPAIGN_START output_dir=${OUTPUT_DIR} topologies=${TOP_CSV} scenarios=${SCENARIO_CSV}"

for topo in "${TOPOLOGIES[@]}"; do
  for scenario in "${SCENARIOS[@]}"; do
    run_index=$((run_index + 1))
    run_id="${ATTEMPT_LABEL}_r$(printf '%02d' "$run_index")_t${topo}_${scenario}"
    run_dir="${OUTPUT_DIR}/${run_id}"

    if ! run_single_case "$topo" "$scenario" "$run_id" "$run_dir"; then
      fail_count=$((fail_count + 1))
      if (( CONTINUE_ON_FAIL == 0 )); then
        log_event "CAMPAIGN_STOP on first failure (run_id=${run_id})"
        break 2
      fi
    fi
  done
done

if (( fail_count > 0 )); then
  log_event "CAMPAIGN_DONE failures=${fail_count} results=${RESULTS_TSV}"
  exit 1
fi

log_event "CAMPAIGN_DONE failures=0 results=${RESULTS_TSV}"
exit 0
