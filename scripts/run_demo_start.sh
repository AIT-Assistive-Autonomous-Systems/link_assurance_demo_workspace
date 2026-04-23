#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/run_demo_start.sh [NUM_AGENTS]
       ./scripts/run_demo_start.sh --agents NUM_AGENTS
       ./scripts/run_demo_start.sh --agents NUM_AGENTS --with-bt

Starts the link assurance demo stack.

Options:
  --agents <count>  Number of agents to launch (legacy flag).
  --with-bt         Launch demo with BT showcase node enabled.

Environment:
  LINK_ASSURANCE_AGENT_COUNT  Default agent count when --agents is not provided.
EOF
}

agent_count="${LINK_ASSURANCE_AGENT_COUNT:-1}"
agent_count_set=0
with_bt=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agents)
      if [[ $# -lt 2 ]]; then
        log_error "Missing value for --agents"
        usage
        exit 1
      fi
      if (( agent_count_set )); then
        log_error "Agent count specified more than once"
        usage
        exit 1
      fi
      agent_count="$2"
      agent_count_set=1
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
    ''|*[!0-9]*)
      log_error "Unknown argument: $1"
      usage
      exit 1
      ;;
    *)
      if (( agent_count_set )); then
        log_error "Agent count specified more than once"
        usage
        exit 1
      fi
      agent_count="$1"
      agent_count_set=1
      shift
      ;;
  esac
done

if ! [[ "$agent_count" =~ ^[0-9]+$ ]] || (( agent_count < 1 )); then
  log_error "NUM_AGENTS must be an integer >= 1"
  exit 1
fi

shutdown_timeout_s="${LINK_ASSURANCE_SHUTDOWN_TIMEOUT_S:-10}"
if ! [[ "$shutdown_timeout_s" =~ ^[0-9]+$ ]] || (( shutdown_timeout_s < 1 )); then
  log_error "LINK_ASSURANCE_SHUTDOWN_TIMEOUT_S must be an integer >= 1"
  exit 1
fi

source_ros
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}"

launch_file="demo_agents.launch.py"
launch_mode="standard"
if (( with_bt )); then
  launch_file="demo_bt_showcase.launch.py"
  launch_mode="with BT showcase"
fi

log_info "Starting link assurance demo (${launch_mode}) with ${agent_count} agent(s)."

cd "${ROOT_DIR}"

launch_pid=""
launch_pgid=""
shutting_down=0

is_launch_running() {
  [[ -n "${launch_pid}" ]] && kill -0 "${launch_pid}" >/dev/null 2>&1
}

signal_launch() {
  local signal_name="$1"

  if ! is_launch_running; then
    return
  fi

  if [[ -n "${launch_pgid}" ]]; then
    kill -"${signal_name}" -"${launch_pgid}" >/dev/null 2>&1 || true
  else
    kill -"${signal_name}" "${launch_pid}" >/dev/null 2>&1 || true
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

  log_warn "Received ${signal_name}; stopping launch process group..."
  signal_launch INT

  if wait_for_launch_exit "$shutdown_timeout_s"; then
    return
  fi

  log_warn "Launch still running after ${shutdown_timeout_s}s, escalating to SIGTERM..."
  signal_launch TERM

  if wait_for_launch_exit 3; then
    return
  fi

  log_error "Launch did not stop cleanly, sending SIGKILL to process group."
  signal_launch KILL
}

trap 'on_interrupt SIGINT' INT
trap 'on_interrupt SIGTERM' TERM

setsid ros2 launch link_assurance_bringup "${launch_file}" agent_count:="${agent_count}" &
launch_pid="$!"
launch_pgid="$(ps -o pgid= -p "${launch_pid}" | tr -d '[:space:]')"

if wait "${launch_pid}"; then
  launch_status=0
else
  launch_status=$?
fi

trap - INT TERM
exit "${launch_status}"