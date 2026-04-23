#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/start_agent_only.sh [OPTIONS]

Start exactly one agent runtime instance.
Suitable for split deployments where station and agents run separately.

Options:
  --node-id <id>          Agent node identifier (default: agent_1)
  --station-id <id>       Station identifier to target (default: station)
  --ros-node-name <name>  ROS node name (default: link_assurance_agent_<node_id>)
  --agent-config <path>   Agent parameter YAML file
  --domain-id <id>        ROS_DOMAIN_ID override (default: 42)
  --rmw <impl>            RMW implementation (default: rmw_zenoh_cpp)
  --localhost-only <bool> ROS_LOCALHOST_ONLY (default: 0)
  --with-bt               Also start the BT showcase node for this agent
  -h, --help              Show this help

Environment defaults:
  LINK_ASSURANCE_NODE_ID
  LINK_ASSURANCE_STATION_ID
  LINK_ASSURANCE_AGENT_ROS_NODE_NAME
  LINK_ASSURANCE_AGENT_CONFIG
  LINK_ASSURANCE_SHUTDOWN_TIMEOUT_S
  ROS_DOMAIN_ID
  RMW_IMPLEMENTATION
  ROS_LOCALHOST_ONLY

Example:
  ./scripts/start_agent_only.sh --node-id agent_2 --station-id station
EOF
}

is_valid_runtime_id() {
  [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]
}

node_id="${LINK_ASSURANCE_NODE_ID:-agent_1}"
station_id="${LINK_ASSURANCE_STATION_ID:-station}"
ros_node_name="${LINK_ASSURANCE_AGENT_ROS_NODE_NAME:-}"
agent_config="${LINK_ASSURANCE_AGENT_CONFIG:-${ROOT_DIR}/src/link_assurance/link_assurance_bringup/config/agent_default.yaml}"
ros_domain_id="${ROS_DOMAIN_ID:-42}"
rmw_impl="${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}"
ros_localhost_only_raw="${ROS_LOCALHOST_ONLY:-0}"
ros_localhost_only=""
shutdown_timeout_s="${LINK_ASSURANCE_SHUTDOWN_TIMEOUT_S:-10}"
with_bt=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node-id)
      [[ $# -ge 2 ]] || { log_error "Missing value for --node-id"; usage; exit 1; }
      node_id="$2"
      shift 2
      ;;
    --station-id)
      [[ $# -ge 2 ]] || { log_error "Missing value for --station-id"; usage; exit 1; }
      station_id="$2"
      shift 2
      ;;
    --ros-node-name)
      [[ $# -ge 2 ]] || { log_error "Missing value for --ros-node-name"; usage; exit 1; }
      ros_node_name="$2"
      shift 2
      ;;
    --agent-config)
      [[ $# -ge 2 ]] || { log_error "Missing value for --agent-config"; usage; exit 1; }
      agent_config="$2"
      shift 2
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
    --with-bt)
      with_bt=1
      shift
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

if ! is_valid_runtime_id "$node_id"; then
  log_error "--node-id must match [A-Za-z][A-Za-z0-9_]*"
  exit 1
fi

if ! is_valid_runtime_id "$station_id"; then
  log_error "--station-id must match [A-Za-z][A-Za-z0-9_]*"
  exit 1
fi

if [[ -z "$ros_node_name" ]]; then
  ros_node_name="link_assurance_agent_${node_id}"
fi

if ! is_valid_runtime_id "$ros_node_name"; then
  log_error "--ros-node-name must match [A-Za-z][A-Za-z0-9_]*"
  exit 1
fi

if ! [[ -f "$agent_config" ]]; then
  log_error "Agent config file not found: $agent_config"
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

if ! ros_localhost_only="$(normalize_bool "$ros_localhost_only_raw")"; then
  log_error "Invalid --localhost-only value: $ros_localhost_only_raw"
  exit 1
fi

source_ros
export RMW_IMPLEMENTATION="$rmw_impl"
export ROS_DOMAIN_ID="$ros_domain_id"
export ROS_LOCALHOST_ONLY="$ros_localhost_only"

log_info "Starting agent-only runtime."
log_info "node_id=${node_id} station_id=${station_id} ros_node_name=${ros_node_name}"
log_info "RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION} ROS_DOMAIN_ID=${ROS_DOMAIN_ID} ROS_LOCALHOST_ONLY=${ROS_LOCALHOST_ONLY}"

cd "$ROOT_DIR"

launch_pid=""
launch_pgid=""
bt_pid=""
shutting_down=0

is_launch_running() {
  [[ -n "$launch_pid" ]] && kill -0 "$launch_pid" >/dev/null 2>&1
}

is_bt_running() {
  [[ -n "$bt_pid" ]] && kill -0 "$bt_pid" >/dev/null 2>&1
}

signal_launch() {
  local signal_name="$1"

  if ! is_launch_running; then
    return
  fi

  if [[ -n "$launch_pgid" ]]; then
    kill -"${signal_name}" -"${launch_pgid}" >/dev/null 2>&1 || true
  else
    kill -"${signal_name}" "$launch_pid" >/dev/null 2>&1 || true
  fi
}

wait_for_launch_exit() {
  local timeout_s="$1"
  local deadline=$((SECONDS + timeout_s))

  while is_launch_running; do
    if (( SECONDS >= deadline )); then
      return 1
    fi
    sleep 0.2
  done

  return 0
}

on_interrupt() {
  local signal_name="$1"

  if (( shutting_down )); then
    return
  fi
  shutting_down=1
  trap - INT TERM

  if ! is_launch_running; then
    return
  fi

  log_warn "Received ${signal_name}; stopping agent process..."
  signal_launch INT

  if wait_for_launch_exit "$shutdown_timeout_s"; then
    return
  fi

  log_warn "Agent still running after ${shutdown_timeout_s}s, escalating to SIGTERM..."
  signal_launch TERM

  if wait_for_launch_exit 3; then
    return
  fi

  log_error "Agent did not stop cleanly, sending SIGKILL."
  signal_launch KILL

  if is_bt_running; then
    kill -KILL "$bt_pid" >/dev/null 2>&1 || true
  fi
}

trap 'on_interrupt SIGINT' INT
trap 'on_interrupt SIGTERM' TERM

setsid ros2 run link_assurance_agent link_assurance_agent_node \
  --ros-args \
  --params-file "$agent_config" \
  -r "__ns:=/link_assurance/agents/${node_id}" \
  -r "__node:=${ros_node_name}" \
  -p "node_id:=${node_id}" \
  -p "station_id:=${station_id}" &

launch_pid="$!"
launch_pgid="$(ps -o pgid= -p "$launch_pid" | tr -d '[:space:]')"

if (( with_bt )); then
  log_info "Starting BT showcase for agent ${node_id}"
  ros2 run link_assurance_bt bt_showcase_node \
    --ros-args \
    -r "__ns:=/link_assurance/agents/${node_id}" &
  bt_pid="$!"
fi

if wait "$launch_pid"; then
  launch_status=0
else
  launch_status=$?
fi

if is_bt_running; then
  kill -INT "$bt_pid" >/dev/null 2>&1 || true
  wait "$bt_pid" 2>/dev/null || true
fi

trap - INT TERM
exit "$launch_status"
