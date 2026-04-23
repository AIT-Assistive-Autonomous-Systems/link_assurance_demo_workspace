#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/docker_start_foxglove_bridge.sh [OPTIONS]

Start or restart Foxglove bridge inside the split-demo station container.

Options:
  --station-name <name>   Station container name (default: la_station)
  --address <addr>        Foxglove bind address (default: 0.0.0.0)
  --port <port>           Foxglove port (default: 8765)
  -h, --help              Show this help

Example:
  ./scripts/docker_start_foxglove_bridge.sh --station-name la_station --port 8765
EOF
}

station_container_name="${LINK_ASSURANCE_STATION_CONTAINER:-la_station}"
foxglove_address="${LINK_ASSURANCE_FOXGLOVE_ADDRESS:-0.0.0.0}"
foxglove_port="${LINK_ASSURANCE_FOXGLOVE_PORT:-8765}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --station-name)
      [[ $# -ge 2 ]] || { log_error "Missing value for --station-name"; usage; exit 1; }
      station_container_name="$2"
      shift 2
      ;;
    --address)
      [[ $# -ge 2 ]] || { log_error "Missing value for --address"; usage; exit 1; }
      foxglove_address="$2"
      shift 2
      ;;
    --port)
      [[ $# -ge 2 ]] || { log_error "Missing value for --port"; usage; exit 1; }
      foxglove_port="$2"
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

if ! is_positive_int "$foxglove_port" || (( foxglove_port > 65535 )); then
  log_error "--port must be an integer between 1 and 65535"
  exit 1
fi

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

if ! "${docker_cmd[@]}" ps --format '{{.Names}}' | grep -Fxq "$station_container_name"; then
  log_error "Station container is not running: ${station_container_name}"
  exit 1
fi

log_info "Starting Foxglove bridge in container ${station_container_name} on ${foxglove_address}:${foxglove_port}."

"${docker_cmd[@]}" exec "$station_container_name" bash -lc "pkill -f '[f]oxglove_bridge' >/dev/null 2>&1 || true"

"${docker_cmd[@]}" exec -d "$station_container_name" bash -lc \
  "source /opt/ros/kilted/setup.bash && source /workspaces/ws_link_assurance_demo/install/setup.bash && ros2 run foxglove_bridge foxglove_bridge --ros-args -p address:=${foxglove_address} -p port:=${foxglove_port}"

sleep 1
if ! "${docker_cmd[@]}" exec "$station_container_name" bash -lc "pgrep -f '[f]oxglove_bridge' >/dev/null"; then
  log_error "Foxglove bridge did not stay running in ${station_container_name}. Check container logs."
  exit 1
fi

log_info "Foxglove bridge is running in ${station_container_name}."
log_info "Connect Foxglove Studio to ws://localhost:${foxglove_port}"
