#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/common.sh"

source_ros
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}"

DISCONNECT_MODE="${LINK_ASSURANCE_DISCONNECT_MODE:-router_pause}"
FAULT_START_DELAY_S="${LINK_ASSURANCE_FAULT_START_DELAY_S:-4}"
DURATION_S="${LINK_ASSURANCE_FAULT_DURATION_S:-0}"
ROUTER_PID_OVERRIDE="${LINK_ASSURANCE_ROUTER_PID:-}"
ROUTER_PID=""
router_paused=0

resolve_router_pid() {
  local candidate_pid="$1"
  local candidate_comm=""
  local child_pid=""

  if [[ -z "$candidate_pid" ]]; then
    return 1
  fi

  candidate_comm="$(ps -o comm= -p "$candidate_pid" 2>/dev/null | tr -d '[:space:]')"
  if [[ "$candidate_comm" == "rmw_zenohd" ]]; then
    ROUTER_PID="$candidate_pid"
    return 0
  fi

  child_pid="$(pgrep -P "$candidate_pid" -n -x rmw_zenohd || true)"
  if [[ -n "$child_pid" ]]; then
    ROUTER_PID="$child_pid"
    return 0
  fi

  return 1
}

if ! [[ "$FAULT_START_DELAY_S" =~ ^[0-9]+$ ]]; then
  log_error "LINK_ASSURANCE_FAULT_START_DELAY_S must be an integer >= 0"
  exit 1
fi

if ! [[ "$DURATION_S" =~ ^[0-9]+$ ]]; then
  log_error "LINK_ASSURANCE_FAULT_DURATION_S must be an integer >= 0"
  exit 1
fi

if [[ "$DISCONNECT_MODE" != "router_pause" && "$DISCONNECT_MODE" != "tc" ]]; then
  log_error "LINK_ASSURANCE_DISCONNECT_MODE must be 'router_pause' or 'tc'"
  exit 1
fi

if [[ -n "$ROUTER_PID_OVERRIDE" ]] && ! [[ "$ROUTER_PID_OVERRIDE" =~ ^[0-9]+$ ]]; then
  log_error "LINK_ASSURANCE_ROUTER_PID must be a numeric PID when set"
  exit 1
fi

if [[ "$DISCONNECT_MODE" == "tc" ]]; then
  exec "${ROOT_DIR}/scripts/run_inject_network.sh" --profile outage
fi

cleanup() {
  if [[ "$router_paused" -eq 1 && -n "$ROUTER_PID" ]]; then
    log_info "Resuming Zenoh router process ${ROUTER_PID}."
    kill -CONT "$ROUTER_PID" >/dev/null 2>&1 || true
  fi
}

on_signal() {
  log_info "Stop signal received; shutting down disconnect injector."
  exit 0
}

trap cleanup EXIT
trap on_signal INT TERM

log_info "Disconnect injector will run until interrupted and restore connectivity on exit."
log_info "Mode=router_pause: pausing rmw_zenohd after ${FAULT_START_DELAY_S}s."

sleep "$FAULT_START_DELAY_S"

if [[ -n "$ROUTER_PID_OVERRIDE" ]]; then
  resolve_router_pid "$ROUTER_PID_OVERRIDE" || true
else
  ROUTER_PID="$(pgrep -n -x rmw_zenohd || true)"
fi

if [[ -z "$ROUTER_PID" ]]; then
  log_error "Could not find rmw_zenohd process. Start Zenoh router first or set LINK_ASSURANCE_DISCONNECT_MODE=tc."
  exit 1
fi

log_info "Targeting rmw_zenohd process ${ROUTER_PID}."

if ! kill -STOP "$ROUTER_PID"; then
  log_error "Failed to pause rmw_zenohd (pid ${ROUTER_PID})."
  exit 1
fi
router_paused=1

log_info "Disconnect injector active. Press Ctrl+C to stop and restore network."

if (( DURATION_S > 0 )); then
  sleep "$DURATION_S"
  log_info "Duration reached; stopping disconnect injector."
  exit 0
fi

while true; do sleep 1; done
