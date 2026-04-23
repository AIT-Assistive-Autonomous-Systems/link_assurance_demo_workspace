#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/docker_split_demo_down.sh [OPTIONS]

Stop and remove split demo containers created by docker_split_demo_up.sh.

Options:
  --network <name>       Docker network name (default: link_assurance_split_net)
  --station-name <name>  Station container name (default: la_station)
  --agent-prefix <name>  Agent container prefix (default: la_agent)
  --router-name <name>   Router container name (default: la_zenoh_router)
  --keep-network         Keep network after removing containers
  -h, --help             Show this help
EOF
}

container_exists() {
  local name="$1"
  "${docker_cmd[@]}" container inspect "$name" >/dev/null 2>&1
}

network_name="${LINK_ASSURANCE_SPLIT_NETWORK:-link_assurance_split_net}"
station_container_name="${LINK_ASSURANCE_STATION_CONTAINER:-la_station}"
agent_container_prefix="${LINK_ASSURANCE_AGENT_CONTAINER_PREFIX:-la_agent}"
router_container_name="${LINK_ASSURANCE_ROUTER_CONTAINER:-la_zenoh_router}"
remove_network=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network)
      [[ $# -ge 2 ]] || { log_error "Missing value for --network"; usage; exit 1; }
      network_name="$2"
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
    --router-name)
      [[ $# -ge 2 ]] || { log_error "Missing value for --router-name"; usage; exit 1; }
      router_container_name="$2"
      shift 2
      ;;
    --keep-network)
      remove_network=0
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

if container_exists "$station_container_name"; then
  log_info "Removing station container: ${station_container_name}"
  "${docker_cmd[@]}" rm -f "$station_container_name" >/dev/null
fi

if container_exists "$router_container_name"; then
  log_info "Removing router container: ${router_container_name}"
  "${docker_cmd[@]}" rm -f "$router_container_name" >/dev/null
fi

mapfile -t agent_containers < <("${docker_cmd[@]}" ps -a --format '{{.Names}}' | grep -E "^${agent_container_prefix}_" || true)
for container_name in "${agent_containers[@]}"; do
  log_info "Removing agent container: ${container_name}"
  "${docker_cmd[@]}" rm -f "$container_name" >/dev/null
done

if (( remove_network )); then
  if "${docker_cmd[@]}" network inspect "$network_name" >/dev/null 2>&1; then
    log_info "Removing network: ${network_name}"
    "${docker_cmd[@]}" network rm "$network_name" >/dev/null || true
  fi
fi

log_info "Split demo teardown complete."
