#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/start_station_only.sh [OPTIONS]

Start only the station-side runtime (and visualization by default).
Suitable for split deployments where agents run separately.

Options:
  --station-id <id>         Station identifier (default: station)
  --agent-ids <csv>         Comma-separated expected agent IDs (default: agent_1)
  --station-config <path>   Station parameter YAML file
  --with-visualization      Start link_assurance_summary (default)
  --no-visualization        Do not start link_assurance_summary
  --domain-id <id>          ROS_DOMAIN_ID override (default: 42)
  --rmw <impl>              RMW implementation (default: rmw_zenoh_cpp)
  --localhost-only <bool>   ROS_LOCALHOST_ONLY (default: 0)
  -h, --help                Show this help

Environment defaults:
  LINK_ASSURANCE_STATION_ID
  LINK_ASSURANCE_AGENT_IDS
  LINK_ASSURANCE_STATION_CONFIG
  LINK_ASSURANCE_WITH_VISUALIZATION
  LINK_ASSURANCE_SHUTDOWN_TIMEOUT_S
  ROS_DOMAIN_ID
  RMW_IMPLEMENTATION
  ROS_LOCALHOST_ONLY

Example:
  ./scripts/start_station_only.sh --station-id station --agent-ids agent_1,agent_2
EOF
}

is_valid_runtime_id() {
  [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]
}

to_ros_string_array_literal() {
  local -a values=("$@")
  local joined=""
  local value=""

  for value in "${values[@]}"; do
    if [[ -n "$joined" ]]; then
      joined+=", "
    fi
    joined+="'${value}'"
  done

  printf '[%s]' "$joined"
}

station_id="${LINK_ASSURANCE_STATION_ID:-station}"
agent_ids_csv="${LINK_ASSURANCE_AGENT_IDS:-agent_1}"
station_config="${LINK_ASSURANCE_STATION_CONFIG:-${ROOT_DIR}/src/link_assurance/link_assurance_bringup/config/station_one_agent.yaml}"
with_visualization_raw="${LINK_ASSURANCE_WITH_VISUALIZATION:-1}"
with_visualization=""
ros_domain_id="${ROS_DOMAIN_ID:-42}"
rmw_impl="${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}"
ros_localhost_only_raw="${ROS_LOCALHOST_ONLY:-0}"
ros_localhost_only=""
shutdown_timeout_s="${LINK_ASSURANCE_SHUTDOWN_TIMEOUT_S:-10}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --station-id)
      [[ $# -ge 2 ]] || { log_error "Missing value for --station-id"; usage; exit 1; }
      station_id="$2"
      shift 2
      ;;
    --agent-ids)
      [[ $# -ge 2 ]] || { log_error "Missing value for --agent-ids"; usage; exit 1; }
      agent_ids_csv="$2"
      shift 2
      ;;
    --station-config)
      [[ $# -ge 2 ]] || { log_error "Missing value for --station-config"; usage; exit 1; }
      station_config="$2"
      shift 2
      ;;
    --with-visualization)
      with_visualization_raw="1"
      shift
      ;;
    --no-visualization)
      with_visualization_raw="0"
      shift
      ;;
    --domain-id)
      [[ $# -ge 2 ]] || { log_error "Missing value for --domain-id"; usage; exit 1; }
      ros_domain_id="$2"
      shift 2
      ;;
    --rmw)
      [[ $# -ge 2 ]] || { log_error "Missing value for --rmw"; usage; exit 1; }
      rmw_impl="$2"
      shift 2
      ;;
    --localhost-only)
      [[ $# -ge 2 ]] || { log_error "Missing value for --localhost-only"; usage; exit 1; }
      ros_localhost_only_raw="$2"
      shift 2
      ;;
    -h|--help)
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

if ! is_valid_runtime_id "$station_id"; then
  log_error "--station-id must match [A-Za-z][A-Za-z0-9_]*"
  exit 1
fi

if ! parse_csv_values "$agent_ids_csv" agent_ids; then
  log_error "--agent-ids must contain at least one ID"
  exit 1
fi

for agent_id in "${agent_ids[@]}"; do
  if ! is_valid_runtime_id "$agent_id"; then
    log_error "Invalid agent id '${agent_id}'. Expected [A-Za-z][A-Za-z0-9_]*"
    exit 1
  fi
done

if ! [[ -f "$station_config" ]]; then
  log_error "Station config file not found: $station_config"
  exit 1
fi

if ! is_non_negative_int "$ros_domain_id"; then
  log_error "--domain-id must be an integer >= 0"
  exit 1
fi

if ! is_positive_int "$shutdown_timeout_s"; then
  log_error "LINK_ASSURANCE_SHUTDOWN_TIMEOUT_S must be an integer >= 1"
  exit 1
fi

if ! with_visualization="$(normalize_bool "$with_visualization_raw")"; then
  log_error "Invalid visualization flag: $with_visualization_raw"
  exit 1
fi

if ! ros_localhost_only="$(normalize_bool "$ros_localhost_only_raw")"; then
  log_error "Invalid --localhost-only value: $ros_localhost_only_raw"
  exit 1
fi

source_ros
export RMW_IMPLEMENTATION="$rmw_impl"
export ROS_DOMAIN_ID="$ros_domain_id"
export ROS_LOCALHOST_ONLY="$ros_localhost_only"

ros_agent_ids="$(to_ros_string_array_literal "${agent_ids[@]}")"

log_info "Starting station-only runtime."
log_info "station_id=${station_id} agent_ids=${agent_ids_csv}"
log_info "RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION} ROS_DOMAIN_ID=${ROS_DOMAIN_ID} ROS_LOCALHOST_ONLY=${ROS_LOCALHOST_ONLY}"

cd "$ROOT_DIR"

station_pid=""
station_pgid=""
viz_pid=""
viz_pgid=""
shutting_down=0

start_process() {
  local process_name="$1"
  shift

  setsid "$@" &
  local child_pid="$!"
  local child_pgid
  child_pgid="$(ps -o pgid= -p "$child_pid" | tr -d '[:space:]')"

  case "$process_name" in
    station)
      station_pid="$child_pid"
      station_pgid="$child_pgid"
      ;;
    visualization)
      viz_pid="$child_pid"
      viz_pgid="$child_pgid"
      ;;
  esac
}

is_running() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1
}

signal_process() {
  local pid="$1"
  local pgid="$2"
  local sig="$3"

  if ! is_running "$pid"; then
    return
  fi

  if [[ -n "$pgid" ]]; then
    kill -"$sig" -"$pgid" >/dev/null 2>&1 || true
  else
    kill -"$sig" "$pid" >/dev/null 2>&1 || true
  fi
}

any_running() {
  is_running "$station_pid" || is_running "$viz_pid"
}

wait_until_stopped() {
  local timeout_s="$1"
  local deadline=$((SECONDS + timeout_s))

  while any_running; do
    if (( SECONDS >= deadline )); then
      return 1
    fi
    sleep 0.2
  done

  return 0
}

shutdown_children() {
  if (( shutting_down )); then
    return
  fi
  shutting_down=1

  signal_process "$station_pid" "$station_pgid" INT
  signal_process "$viz_pid" "$viz_pgid" INT

  if ! wait_until_stopped "$shutdown_timeout_s"; then
    log_warn "Processes still running after ${shutdown_timeout_s}s, sending SIGTERM..."
    signal_process "$station_pid" "$station_pgid" TERM
    signal_process "$viz_pid" "$viz_pgid" TERM

    if ! wait_until_stopped 3; then
      log_error "Processes did not stop cleanly, sending SIGKILL."
      signal_process "$station_pid" "$station_pgid" KILL
      signal_process "$viz_pid" "$viz_pgid" KILL
    fi
  fi
}

on_interrupt() {
  local signal_name="$1"

  if (( shutting_down )); then
    return
  fi

  trap - INT TERM
  log_warn "Received ${signal_name}; stopping station runtime..."
  shutdown_children
  wait "$station_pid" >/dev/null 2>&1 || true
  if [[ -n "$viz_pid" ]]; then
    wait "$viz_pid" >/dev/null 2>&1 || true
  fi
  exit 130
}

trap 'on_interrupt SIGINT' INT
trap 'on_interrupt SIGTERM' TERM

start_process station \
  ros2 run link_assurance_station link_assurance_station_node \
  --ros-args \
  --params-file "$station_config" \
  -p "station_id:=${station_id}" \
  -p "agent_ids:=${ros_agent_ids}"

if [[ "$with_visualization" == "1" ]]; then
  start_process visualization ros2 run link_assurance_visualization link_assurance_summary
fi

if [[ -n "$viz_pid" ]]; then
  if wait -n "$station_pid" "$viz_pid"; then
    first_status=0
  else
    first_status=$?
  fi
else
  if wait "$station_pid"; then
    first_status=0
  else
    first_status=$?
  fi
fi

if (( shutting_down == 0 )); then
  log_warn "A station-side process exited; shutting down remaining processes."
  shutdown_children
fi

wait "$station_pid" >/dev/null 2>&1 || true
if [[ -n "$viz_pid" ]]; then
  wait "$viz_pid" >/dev/null 2>&1 || true
fi

trap - INT TERM
exit "$first_status"
