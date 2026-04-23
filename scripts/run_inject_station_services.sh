#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/common.sh"

source_ros
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}"

WATCHDOG_DELAY_S="${LINK_ASSURANCE_FAULT_WATCHDOG_DELAY_S:-5}"
AUTH_DELAY_S="${LINK_ASSURANCE_FAULT_AUTH_DELAY_S:-${LINK_ASSURANCE_FAULT_HSM_DELAY_S:-7}}"
INJECT_INTERVAL_S="${LINK_ASSURANCE_INJECT_INTERVAL_S:-2}"
WATCHDOG_SERVICE="/link_assurance_station/set_station_watchdog_healthy"
AUTH_SERVICE="/link_assurance_station/set_station_auth_token_present"
WATCHDOG_HEALTHY="${LINK_ASSURANCE_WATCHDOG_HEALTHY:-false}"
AUTH_PRESENT="${LINK_ASSURANCE_AUTH_PRESENT:-${LINK_ASSURANCE_HSM_PRESENT:-false}}"

if [[ "$WATCHDOG_HEALTHY" != "true" && "$WATCHDOG_HEALTHY" != "false" ]]; then
  log_error "LINK_ASSURANCE_WATCHDOG_HEALTHY must be true or false"
  exit 1
fi
if [[ "$AUTH_PRESENT" != "true" && "$AUTH_PRESENT" != "false" ]]; then
  log_error "LINK_ASSURANCE_AUTH_PRESENT must be true or false"
  exit 1
fi
if ! [[ "$INJECT_INTERVAL_S" =~ ^[0-9]+$ ]] || (( INJECT_INTERVAL_S < 1 )); then
  log_error "LINK_ASSURANCE_INJECT_INTERVAL_S must be an integer >= 1"
  exit 1
fi

call_watchdog() {
  local value="$1"
  ros2 service call "$WATCHDOG_SERVICE" std_srvs/srv/SetBool "{data: ${value}}" >/dev/null ||
    log_warn "Service call to ${WATCHDOG_SERVICE} failed."
}

call_auth() {
  local value="$1"
  ros2 service call "$AUTH_SERVICE" std_srvs/srv/SetBool "{data: ${value}}" >/dev/null ||
    log_warn "Service call to ${AUTH_SERVICE} failed."
}

cleanup() {
  log_info "Restoring station service healthy states."
  if wait_for_service "$WATCHDOG_SERVICE" 10; then
    call_watchdog true
  else
    log_warn "Service ${WATCHDOG_SERVICE} not available during cleanup."
  fi

  if wait_for_service "$AUTH_SERVICE" 10; then
    call_auth true
  else
    log_warn "Service ${AUTH_SERVICE} not available during cleanup."
  fi
}

on_signal() {
  log_info "Stop signal received; shutting down station service injector."
  exit 0
}

trap cleanup EXIT
trap on_signal INT TERM

log_info "Station service injector will run until interrupted and restore on exit."
log_info "Setting watchdog healthy=${WATCHDOG_HEALTHY} after ${WATCHDOG_DELAY_S}s."
log_info "Setting auth token present=${AUTH_PRESENT} after ${AUTH_DELAY_S}s."

start_ts="$SECONDS"
watchdog_active=0
auth_active=0
running_logged=0

while true; do
  elapsed=$((SECONDS - start_ts))

  if (( watchdog_active == 0 )) && (( elapsed >= WATCHDOG_DELAY_S )); then
    if wait_for_service "$WATCHDOG_SERVICE" 20; then
      call_watchdog "$WATCHDOG_HEALTHY"
      watchdog_active=1
      log_info "Watchdog injector active."
    else
      log_warn "Service ${WATCHDOG_SERVICE} not available; watchdog injector not activated yet."
    fi
  fi

  if (( auth_active == 0 )) && (( elapsed >= AUTH_DELAY_S )); then
    if wait_for_service "$AUTH_SERVICE" 20; then
      call_auth "$AUTH_PRESENT"
      auth_active=1
      log_info "Auth injector active."
    else
      log_warn "Service ${AUTH_SERVICE} not available; auth injector not activated yet."
    fi
  fi

  if (( watchdog_active == 1 )); then
    call_watchdog "$WATCHDOG_HEALTHY"
  fi
  if (( auth_active == 1 )); then
    call_auth "$AUTH_PRESENT"
  fi

  if (( running_logged == 0 )) && (( watchdog_active == 1 || auth_active == 1 )); then
    log_info "Station service injector running. Press Ctrl+C to stop and restore behavior."
    running_logged=1
  fi

  sleep "$INJECT_INTERVAL_S"
done
