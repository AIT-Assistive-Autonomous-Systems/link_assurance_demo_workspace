#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/docker_inject_network.sh [OPTIONS]

Run network injection against exactly one split-demo container.

Targets:
  - station (maps to station container)
  - agent id (maps to <agent-prefix>_<agent-id>)

Options:
  --target <id>         Target identifier: station or an agent id
  --container <name>    Explicit container name (overrides --target)
  --station-name <name> Station container name (default: la_station)
  --agent-prefix <name> Agent container prefix (default: la_agent)
  --profile <name>      Fault profile (default: wifi_congested)
  --iface <name>        Interface in container (default: eth0)
  --start-delay <sec>   Delay before applying fault (default: 4)
  --duration <sec>      Duration (default: 0, run until Ctrl+C)
  --agent-id <id>       Deprecated alias for --target <id>
  -h, --help            Show this help

Examples:
  ./scripts/docker_inject_network.sh --target agent_2 --profile bufferbloat --duration 20
  ./scripts/docker_inject_network.sh --target station --profile outage --duration 10
  ./scripts/docker_inject_network.sh --container la_agent_agent_3 --profile wifi_edge --duration 10
EOF
}

is_valid_runtime_id() {
  [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]
}

sanitize_name_component() {
  local value="$1"
  value="${value//[^A-Za-z0-9_.-]/_}"
  echo "$value"
}

container_running() {
  local name="$1"
  "${docker_cmd[@]}" ps --format '{{.Names}}' | grep -Fxq "$name"
}

target_id=""
container_name=""
station_container_name="${LINK_ASSURANCE_STATION_CONTAINER:-la_station}"
agent_container_prefix="${LINK_ASSURANCE_AGENT_CONTAINER_PREFIX:-la_agent}"
profile="${LINK_ASSURANCE_NET_PROFILE:-wifi_congested}"
iface="${LINK_ASSURANCE_TC_IFACE:-eth0}"
start_delay_s="${LINK_ASSURANCE_FAULT_START_DELAY_S:-4}"
duration_s="${LINK_ASSURANCE_FAULT_DURATION_S:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      [[ $# -ge 2 ]] || { log_error "Missing value for --target"; usage; exit 1; }
      target_id="$2"
      shift 2
      ;;
    --agent-id)
      [[ $# -ge 2 ]] || { log_error "Missing value for --agent-id"; usage; exit 1; }
      target_id="$2"
      shift 2
      ;;
    --container)
      [[ $# -ge 2 ]] || { log_error "Missing value for --container"; usage; exit 1; }
      container_name="$2"
      shift 2
      ;;
    --station-name)
      [[ $# -ge 2 ]] || { log_error "Missing value for --station-name"; usage; exit 1; }
      station_container_name="$2"
      shift 2
      ;;
    --agent-prefix)
      [[ $# -ge 2 ]] || { log_error "Missing value for --agent-prefix"; usage; exit 1; }
      agent_container_prefix="$2"
      shift 2
      ;;
    --profile)
      [[ $# -ge 2 ]] || { log_error "Missing value for --profile"; usage; exit 1; }
      profile="$2"
      shift 2
      ;;
    --iface)
      [[ $# -ge 2 ]] || { log_error "Missing value for --iface"; usage; exit 1; }
      iface="$2"
      shift 2
      ;;
    --start-delay)
      [[ $# -ge 2 ]] || { log_error "Missing value for --start-delay"; usage; exit 1; }
      start_delay_s="$2"
      shift 2
      ;;
    --duration)
      [[ $# -ge 2 ]] || { log_error "Missing value for --duration"; usage; exit 1; }
      duration_s="$2"
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

require_command docker

docker_cmd=(docker)
if ! docker info >/dev/null 2>&1; then
  if sudo docker info >/dev/null 2>&1; then
    docker_cmd=(sudo docker)
  fi
fi

if ! "${docker_cmd[@]}" info >/dev/null 2>&1; then
  log_error "Docker daemon is not reachable. Start Docker or reopen the devcontainer with docker socket access."
  exit 1
fi

if [[ -z "$container_name" ]]; then
  if [[ -z "$target_id" ]]; then
    log_error "Specify either --container or --target"
    usage
    exit 1
  fi

  if [[ "$target_id" == "station" || "$target_id" == "$station_container_name" ]]; then
    container_name="$station_container_name"
  else
    if ! is_valid_runtime_id "$target_id"; then
      log_error "--target must be 'station' or match [A-Za-z][A-Za-z0-9_]* for agent ids"
      exit 1
    fi

    safe_agent="$(sanitize_name_component "$target_id")"
    container_name="${agent_container_prefix}_${safe_agent}"
  fi
fi

if ! is_non_negative_int "$start_delay_s"; then
  log_error "--start-delay must be an integer >= 0"
  exit 1
fi

if ! is_non_negative_int "$duration_s"; then
  log_error "--duration must be an integer >= 0"
  exit 1
fi

if ! container_running "$container_name"; then
  log_error "Container is not running: ${container_name}"
  exit 1
fi

log_info "Injecting network fault into container ${container_name}."
log_info "profile=${profile} iface=${iface} start_delay=${start_delay_s}s duration=${duration_s}s"

inject_env_args=()
if [[ -n "${LINK_ASSURANCE_ALLOW_PRIMARY_IFACE:-}" ]]; then
  inject_env_args+=( -e "LINK_ASSURANCE_ALLOW_PRIMARY_IFACE=${LINK_ASSURANCE_ALLOW_PRIMARY_IFACE}" )
elif [[ "$iface" != "lo" ]]; then
  log_info "Enabling primary interface injection override for container-targeted fault on '${iface}'."
  inject_env_args+=( -e "LINK_ASSURANCE_ALLOW_PRIMARY_IFACE=1" )
fi

inject_exec_pid=""
was_interrupted=0

stop_remote_injection() {
  if ! container_running "$container_name"; then
    return
  fi

  # Best-effort interrupt of any active in-container injector instance.
  "${docker_cmd[@]}" exec "$container_name" bash -lc "pkill -INT -f '[r]un_inject_network.sh' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true

  # Ensure qdisc cleanup in case interrupt did not reach the remote process.
  "${docker_cmd[@]}" exec "$container_name" \
    ./scripts/run_inject_network.sh \
      --iface "$iface" \
      --clear >/dev/null 2>&1 || true
}

on_interrupt() {
  local signal_name="$1"
  was_interrupted=1
  log_warn "Received ${signal_name}; stopping remote network injection..."

  stop_remote_injection

  if [[ -n "$inject_exec_pid" ]] && kill -0 "$inject_exec_pid" >/dev/null 2>&1; then
    kill -INT "$inject_exec_pid" >/dev/null 2>&1 || true
  fi
}

trap 'on_interrupt SIGINT' INT
trap 'on_interrupt SIGTERM' TERM

"${docker_cmd[@]}" exec "${inject_env_args[@]}" -e LINK_ASSURANCE_TC_IFACE="$iface" "$container_name" \
  ./scripts/run_inject_network.sh \
    --profile "$profile" \
    --iface "$iface" \
    --start-delay "$start_delay_s" \
    --duration "$duration_s" &
inject_exec_pid="$!"

if wait "$inject_exec_pid"; then
  inject_rc=0
else
  inject_rc=$?
fi

trap - INT TERM

if (( was_interrupted )); then
  # Keep behavior predictable for user-triggered interrupt.
  exit 130
fi

exit "$inject_rc"
