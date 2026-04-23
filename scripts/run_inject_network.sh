#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/common.sh"

source_ros
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}"

require_command tc

usage() {
  cat <<'EOF'
Usage: ./scripts/run_inject_network.sh [OPTIONS]

Apply realistic network fault profiles using tc netem.
Runs until interrupted by default and restores network state on exit.

Options:
  --profile <name>      Fault profile to apply (default: wifi_congested)
  --iface <name>        Interface to apply qdisc on (default: LINK_ASSURANCE_TC_IFACE or lo)
  --start-delay <sec>   Delay before applying fault (default: 4)
  --duration <sec>      Auto-stop after N seconds (default: 0, run until Ctrl+C)
  --clear               Clear root qdisc on interface and exit
  --list                List available profiles and exit
  -h, --help            Show this help

Environment:
  LINK_ASSURANCE_NET_PROFILE          Default profile name
  LINK_ASSURANCE_TC_IFACE             Default network interface (safe default: lo)
  LINK_ASSURANCE_ALLOW_PRIMARY_IFACE  Set to 1 to allow applying on default route interface
  LINK_ASSURANCE_FAULT_START_DELAY_S  Default start delay
  LINK_ASSURANCE_FAULT_DURATION_S     Default duration (0 means run until interrupted)
  LINK_ASSURANCE_FAULT_SEED           Optional deterministic random seed for netem

Profile-specific optional overrides:
  LINK_ASSURANCE_FAULT_DELAY_MS       Used by profile=latency (default: 180)
  LINK_ASSURANCE_FAULT_JITTER_MS      Used by profile=latency (default: 35)
  LINK_ASSURANCE_FAULT_LOSS_PCT       Used by profile=outage (default: 100)
EOF
}

list_profiles() {
  cat <<'EOF'
Available profiles:
  latency         Legacy delay+jitter profile (high RTT + moderate jitter)
  wifi_congested  Typical congested Wi-Fi (delay variance, mild loss, slight reorder)
  wifi_edge       Weak Wi-Fi coverage (higher variance and loss)
  burst_loss      Bursty packet loss under congestion/interference
  reordering      Out-of-order delivery spikes with mild loss
  bufferbloat     Queue buildup under load (high delay + constrained link rate)
  outage          Full packet loss (tc-based disconnect simulation)
EOF
}

is_non_negative_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

PROFILE="${LINK_ASSURANCE_NET_PROFILE:-wifi_congested}"
IFACE="$(default_fault_interface)"
START_DELAY_S="${LINK_ASSURANCE_FAULT_START_DELAY_S:-4}"
DURATION_S="${LINK_ASSURANCE_FAULT_DURATION_S:-0}"
LIST_ONLY=0
CLEAR_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      if [[ $# -lt 2 ]]; then
        log_error "Missing value for --profile"
        usage
        exit 1
      fi
      PROFILE="$2"
      shift 2
      ;;
    --iface)
      if [[ $# -lt 2 ]]; then
        log_error "Missing value for --iface"
        usage
        exit 1
      fi
      IFACE="$2"
      shift 2
      ;;
    --start-delay)
      if [[ $# -lt 2 ]]; then
        log_error "Missing value for --start-delay"
        usage
        exit 1
      fi
      START_DELAY_S="$2"
      shift 2
      ;;
    --duration)
      if [[ $# -lt 2 ]]; then
        log_error "Missing value for --duration"
        usage
        exit 1
      fi
      DURATION_S="$2"
      shift 2
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --clear)
      CLEAR_ONLY=1
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

if (( LIST_ONLY )); then
  list_profiles
  exit 0
fi

if ! is_non_negative_int "$START_DELAY_S"; then
  log_error "--start-delay must be an integer >= 0"
  exit 1
fi

if ! is_non_negative_int "$DURATION_S"; then
  log_error "--duration must be an integer >= 0"
  exit 1
fi

if [[ -z "$IFACE" ]]; then
  log_error "Interface name cannot be empty"
  exit 1
fi

if (( CLEAR_ONLY )); then
  log_info "Clearing netem qdisc on interface ${IFACE}."
  clear_qdisc_root "$IFACE"
  log_info "Network fault state cleared on ${IFACE}."
  exit 0
fi

assert_safe_fault_interface "$IFACE"

PROFILE_DESC=""
NETEM_ARGS=()

case "$PROFILE" in
  latency)
    DELAY_MS="${LINK_ASSURANCE_FAULT_DELAY_MS:-180}"
    JITTER_MS="${LINK_ASSURANCE_FAULT_JITTER_MS:-35}"
    PROFILE_DESC="High base RTT with jitter; useful for remote/wide-area latency behavior."
    NETEM_ARGS=(delay "${DELAY_MS}ms" "${JITTER_MS}ms")
    ;;
  wifi_congested)
    PROFILE_DESC="Congested Wi-Fi: variable delay, mild random loss, occasional reordering."
    NETEM_ARGS=(delay 70ms 25ms distribution normal loss 1.5% 25% reorder 0.2% 50% duplicate 0.05%)
    ;;
  wifi_edge)
    PROFILE_DESC="Weak Wi-Fi edge: higher delay variance, increased loss, occasional reorder."
    NETEM_ARGS=(delay 120ms 45ms distribution normal loss 3% 35% reorder 0.5% 60% duplicate 0.1%)
    ;;
  burst_loss)
    PROFILE_DESC="Bursty packet drops under contention/interference."
    NETEM_ARGS=(delay 60ms 20ms distribution normal loss 6% 65%)
    ;;
  reordering)
    PROFILE_DESC="Out-of-order packets with light loss (driver/queue scheduling effects)."
    NETEM_ARGS=(delay 45ms 15ms distribution normal reorder 2% 60% gap 5 loss 0.5% 20%)
    ;;
  bufferbloat)
    PROFILE_DESC="Queue bloat under load: high queueing delay plus constrained effective link rate."
    NETEM_ARGS=(delay 220ms 90ms distribution normal rate 12mbit limit 3000)
    ;;
  outage)
    LOSS_PCT="${LINK_ASSURANCE_FAULT_LOSS_PCT:-100}"
    PROFILE_DESC="Complete packet loss to simulate link outage."
    NETEM_ARGS=(loss "${LOSS_PCT}%")
    ;;
  *)
    log_error "Unknown profile '${PROFILE}'."
    list_profiles
    exit 1
    ;;
esac

if [[ -n "${LINK_ASSURANCE_FAULT_SEED:-}" ]]; then
  NETEM_ARGS+=(seed "${LINK_ASSURANCE_FAULT_SEED}")
fi

qdisc_active=0

cleanup() {
  if [[ "$qdisc_active" -eq 1 ]]; then
    log_info "Restoring normal network behavior on ${IFACE}."
    clear_qdisc_root "$IFACE"
  fi
}

on_signal() {
  log_info "Stop signal received; shutting down network injector."
  exit 0
}

trap cleanup EXIT
trap on_signal INT TERM

log_info "Network injector will run until interrupted and restore network on exit."
log_info "Profile=${PROFILE}"
log_info "Description: ${PROFILE_DESC}"
log_info "Interface=${IFACE} start_delay=${START_DELAY_S}s duration=${DURATION_S}s"
log_info "Applying netem args: ${NETEM_ARGS[*]}"

if (( START_DELAY_S > 0 )); then
  sleep "$START_DELAY_S"
fi

clear_qdisc_root "$IFACE"
if ! sudo_if_needed tc qdisc add dev "$IFACE" root netem "${NETEM_ARGS[@]}"; then
  log_error "Failed to apply tc netem on ${IFACE}. Check CAP_NET_ADMIN/sudo permissions."
  exit 1
fi
qdisc_active=1

sudo_if_needed tc qdisc show dev "$IFACE" | sed 's/^/[INFO] tc: /'

if (( DURATION_S > 0 )); then
  log_info "Injector active for ${DURATION_S}s."
  sleep "$DURATION_S"
  log_info "Duration reached; stopping injector."
  exit 0
fi

log_info "Injector active. Press Ctrl+C to stop and restore network."
while true; do
  sleep 1
done
