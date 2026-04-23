#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/docker_split_demo_up.sh [OPTIONS]

Start split demo emulation in local containers:
- 1 station container
- 1 container per agent

Options:
  --station-id <id>       Station identifier (default: station)
  --agent-ids <csv>       Comma-separated agent IDs (default: agent_1,agent_2)
  --image <tag>           Docker image tag (default: link-assurance-split:latest)
  --workspace-source <p>  Host-visible workspace path for bind mount
                          (default: LINK_ASSURANCE_DOCKER_WORKSPACE_SOURCE or current workspace path)
  --network <name>        Docker network name (default: link_assurance_split_net)
  --station-name <name>   Station container name (default: la_station)
  --agent-prefix <name>   Agent container prefix (default: la_agent)
  --router-name <name>    Router container name for Zenoh mode (default: la_zenoh_router)
  --with-foxglove         Start Foxglove bridge in station container (default)
  --no-foxglove           Do not start Foxglove bridge in station container
  --foxglove-port <port>  Host/container Foxglove bridge port (default: 8765)
  --domain-id <id>        ROS_DOMAIN_ID (default: 42)
  --rmw <impl>            RMW implementation (default: rmw_zenoh_cpp)
  --localhost-only <bool> ROS_LOCALHOST_ONLY (default: 0)
  --build                 Build image before startup
  --no-recreate           Fail if target containers already exist
  --no-visualization      Disable visualization in station container
  --with-bt               Also start the BT showcase node inside each agent container
  -h, --help              Show this help

Examples:
  ./scripts/docker_split_demo_up.sh --agent-ids agent_1,agent_2,agent_3 --build
  ./scripts/docker_split_demo_up.sh --station-id station --agent-ids agent_a,agent_b --no-visualization
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

container_exists() {
  local name="$1"
  "${docker_cmd[@]}" container inspect "$name" >/dev/null 2>&1
}

remove_container_if_exists() {
  local name="$1"
  if container_exists "$name"; then
    log_info "Removing existing container: ${name}"
    "${docker_cmd[@]}" rm -f "$name" >/dev/null
  fi
}

workspace_mount_visible() {
  "${docker_cmd[@]}" run --rm \
    -v "${workspace_source}:/workspace:ro" \
    "$runtime_image" \
    test -f /workspace/scripts/start_station_only.sh
}

build_workspace_runtime_image() {
  local packaged_tag="${image_tag}-workspace"
  local dockerfile_tmp
  dockerfile_tmp="$(mktemp /tmp/la-split-runtime.XXXXXX.Dockerfile)"

  cat >"${dockerfile_tmp}" <<EOF
FROM ${image_tag}
COPY . /workspaces/ws_link_assurance_demo
WORKDIR /workspaces/ws_link_assurance_demo
USER ubuntu
EOF

  log_info "Building workspace runtime image ${packaged_tag} (bind mount fallback mode)."
  if ! "${docker_cmd[@]}" build -f "${dockerfile_tmp}" -t "${packaged_tag}" "${ROOT_DIR}"; then
    rm -f "${dockerfile_tmp}"
    log_error "Failed to build packaged workspace runtime image."
    return 1
  fi

  rm -f "${dockerfile_tmp}"
  runtime_image="${packaged_tag}"
  use_bind_mount=0
}

build_custom_image() {
  log_info "Building image ${image_tag} from .devcontainer/Dockerfile"
  if ! "${docker_cmd[@]}" build -f "${ROOT_DIR}/.devcontainer/Dockerfile" -t "$image_tag" "$ROOT_DIR"; then
    log_error "Docker image build failed."
    log_error "If running inside an unprivileged nested container, rebuild this devcontainer with host docker socket mounted."
    log_error "Current config already includes the socket mount; restart/reopen the devcontainer to apply it."
    return 1
  fi
}

station_id="${LINK_ASSURANCE_STATION_ID:-station}"
agent_ids_csv="${LINK_ASSURANCE_AGENT_IDS:-agent_1,agent_2}"
image_tag="${LINK_ASSURANCE_SPLIT_IMAGE:-link-assurance-split:latest}"
workspace_source="${LINK_ASSURANCE_DOCKER_WORKSPACE_SOURCE:-${ROOT_DIR}}"
network_name="${LINK_ASSURANCE_SPLIT_NETWORK:-link_assurance_split_net}"
station_container_name="${LINK_ASSURANCE_STATION_CONTAINER:-la_station}"
agent_container_prefix="${LINK_ASSURANCE_AGENT_CONTAINER_PREFIX:-la_agent}"
router_container_name="${LINK_ASSURANCE_ROUTER_CONTAINER:-la_zenoh_router}"
with_foxglove_raw="${LINK_ASSURANCE_WITH_FOXGLOVE:-1}"
with_foxglove=""
foxglove_port="${LINK_ASSURANCE_FOXGLOVE_PORT:-8765}"
ros_domain_id="${ROS_DOMAIN_ID:-42}"
rmw_impl="${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}"
ros_localhost_only_raw="${ROS_LOCALHOST_ONLY:-0}"
ros_localhost_only=""
recreate_containers=1
with_visualization=1
build_image=0
runtime_image=""
use_bind_mount=1
with_bt=0

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
    --image)
      [[ $# -ge 2 ]] || { log_error "Missing value for --image"; usage; exit 1; }
      image_tag="$2"
      shift 2
      ;;
    --workspace-source)
      [[ $# -ge 2 ]] || { log_error "Missing value for --workspace-source"; usage; exit 1; }
      workspace_source="$2"
      shift 2
      ;;
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
    --with-foxglove)
      with_foxglove_raw="1"
      shift
      ;;
    --no-foxglove)
      with_foxglove_raw="0"
      shift
      ;;
    --foxglove-port)
      [[ $# -ge 2 ]] || { log_error "Missing value for --foxglove-port"; usage; exit 1; }
      foxglove_port="$2"
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
    --build)
      build_image=1
      shift
      ;;
    --no-recreate)
      recreate_containers=0
      shift
      ;;
    --no-visualization)
      with_visualization=0
      shift
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

runtime_image="${image_tag}"

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

if ! is_non_negative_int "$ros_domain_id"; then
  log_error "--domain-id must be an integer >= 0"
  exit 1
fi

if ! ros_localhost_only="$(normalize_bool "$ros_localhost_only_raw")"; then
  log_error "Invalid --localhost-only value: $ros_localhost_only_raw"
  exit 1
fi

if ! with_foxglove="$(normalize_bool "$with_foxglove_raw")"; then
  log_error "Invalid foxglove flag value: $with_foxglove_raw"
  exit 1
fi

if ! is_positive_int "$foxglove_port" || (( foxglove_port > 65535 )); then
  log_error "--foxglove-port must be an integer between 1 and 65535"
  exit 1
fi

if [[ ! -f "${ROOT_DIR}/install/setup.bash" ]]; then
  log_error "Workspace overlay not found at install/setup.bash. Run ./scripts/build.sh first."
  exit 1
fi

if (( build_image )); then
  build_custom_image
else
  if ! "${docker_cmd[@]}" image inspect "$image_tag" >/dev/null 2>&1; then
    log_info "Image ${image_tag} not found locally; attempting pull."
    if ! "${docker_cmd[@]}" pull "$image_tag" >/dev/null 2>&1; then
      log_warn "Unable to pull ${image_tag}; falling back to local build."
      build_custom_image
    fi
  fi
fi

if ! workspace_mount_visible; then
  log_warn "Workspace source '${workspace_source}' is not visible to the Docker daemon for bind mount usage."
  log_warn "Falling back to packaged runtime image mode (no bind mount)."
  build_workspace_runtime_image
fi

if ! "${docker_cmd[@]}" network inspect "$network_name" >/dev/null 2>&1; then
  log_info "Creating network ${network_name}"
  "${docker_cmd[@]}" network create "$network_name" >/dev/null
fi

all_containers=("$station_container_name")
if [[ "$rmw_impl" == "rmw_zenoh_cpp" ]]; then
  all_containers+=("$router_container_name")
fi
for agent_id in "${agent_ids[@]}"; do
  safe_agent="$(sanitize_name_component "$agent_id")"
  all_containers+=("${agent_container_prefix}_${safe_agent}")
done

for container_name in "${all_containers[@]}"; do
  if container_exists "$container_name"; then
    if (( recreate_containers )); then
      remove_container_if_exists "$container_name"
    else
      log_error "Container '${container_name}' already exists. Use --no-recreate only with new names or remove existing containers."
      exit 1
    fi
  fi
done

log_info "Starting split containers: station + ${#agent_ids[@]} agent(s)."
log_info "RMW_IMPLEMENTATION=${rmw_impl} ROS_DOMAIN_ID=${ros_domain_id} ROS_LOCALHOST_ONLY=${ros_localhost_only}"
if (( use_bind_mount == 1 )); then
  log_info "Workspace mode: bind mount (${workspace_source} -> /workspaces/ws_link_assurance_demo)."
else
  log_info "Workspace mode: packaged image (${runtime_image})."
fi

if [[ "$rmw_impl" == "rmw_zenoh_cpp" ]]; then
  log_info "Starting dedicated Zenoh router container: ${router_container_name}"
  router_config_override="routing/router/peers_failover_brokering=true"
  "${docker_cmd[@]}" run -d \
    --name "$router_container_name" \
    --network "$network_name" \
    -e "ZENOH_CONFIG_OVERRIDE=${router_config_override}" \
    "$runtime_image" \
    bash -lc 'source /opt/ros/kilted/setup.bash && ros2 run rmw_zenoh_cpp rmw_zenohd' >/dev/null

  # Give discovery infrastructure a short head start before station/agents boot.
  sleep 2
fi

station_cmd=(
  ./scripts/start_station_only.sh
  --station-id "$station_id"
  --agent-ids "$agent_ids_csv"
  --domain-id "$ros_domain_id"
  --rmw "$rmw_impl"
  --localhost-only "$ros_localhost_only"
)
if (( with_visualization == 0 )); then
  station_cmd+=(--no-visualization)
fi

run_common_args=(
  --network "$network_name"
  --cap-add NET_ADMIN
  -e RMW_IMPLEMENTATION="$rmw_impl"
  -e ROS_DOMAIN_ID="$ros_domain_id"
  -e ROS_LOCALHOST_ONLY="$ros_localhost_only"
  -e SOURCE_WORKSPACE_OVERLAY=1
  -w /workspaces/ws_link_assurance_demo
)

if [[ "$rmw_impl" == "rmw_zenoh_cpp" ]]; then
  zenoh_router_endpoint="tcp/${router_container_name}:7447"
  run_common_args+=(
    -e "ZENOH_CONFIG_OVERRIDE=connect/endpoints=[\"${zenoh_router_endpoint}\"]"
    -e "ZENOH_ROUTER_CHECK_ATTEMPTS=10"
  )
fi

if (( use_bind_mount == 1 )); then
  run_common_args+=( -v "${workspace_source}:/workspaces/ws_link_assurance_demo" )
fi

station_run_args=("${run_common_args[@]}")
if [[ "$with_foxglove" == "1" ]]; then
  selected_foxglove_port="$foxglove_port"
  foxglove_port_search_limit=50
  foxglove_port_search_count=0

  while true; do
    station_run_args=("${run_common_args[@]}" -p "${selected_foxglove_port}:${selected_foxglove_port}")

    set +e
    station_run_output="$("${docker_cmd[@]}" run -d \
      --name "$station_container_name" \
      "${station_run_args[@]}" \
      "$runtime_image" \
      "${station_cmd[@]}" 2>&1)"
    station_run_rc=$?
    set -e

    if (( station_run_rc == 0 )); then
      foxglove_port="$selected_foxglove_port"
      break
    fi

    remove_container_if_exists "$station_container_name"

    if [[ "$station_run_output" == *"address already in use"* ]]; then
      foxglove_port_search_count=$((foxglove_port_search_count + 1))
      if (( foxglove_port_search_count >= foxglove_port_search_limit )) || (( selected_foxglove_port >= 65535 )); then
        log_error "Unable to find a free host port for Foxglove bridge after ${foxglove_port_search_count} attempts starting at ${foxglove_port}."
        log_error "Use --no-foxglove or specify an available --foxglove-port."
        exit 1
      fi

      log_warn "Host port ${selected_foxglove_port} is already in use; retrying with $((selected_foxglove_port + 1))."
      selected_foxglove_port=$((selected_foxglove_port + 1))
      continue
    fi

    log_error "Failed to start station container: ${station_run_output}"
    exit 1
  done
else
  "${docker_cmd[@]}" run -d \
    --name "$station_container_name" \
    "${station_run_args[@]}" \
    "$runtime_image" \
    "${station_cmd[@]}" >/dev/null
fi

for agent_id in "${agent_ids[@]}"; do
  safe_agent="$(sanitize_name_component "$agent_id")"
  agent_container_name="${agent_container_prefix}_${safe_agent}"

  "${docker_cmd[@]}" run -d \
    --name "$agent_container_name" \
    "${run_common_args[@]}" \
    "$runtime_image" \
    ./scripts/start_agent_only.sh \
      --node-id "$agent_id" \
      --station-id "$station_id" \
      --domain-id "$ros_domain_id" \
      --rmw "$rmw_impl" \
      --localhost-only "$ros_localhost_only" \
      $( (( with_bt )) && echo --with-bt ) >/dev/null

done

if [[ "$with_foxglove" == "1" ]]; then
  log_info "Starting Foxglove bridge in station container on port ${foxglove_port}."
  "${ROOT_DIR}/scripts/docker_start_foxglove_bridge.sh" \
    --station-name "$station_container_name" \
    --port "$foxglove_port"
fi

log_info "Split demo containers are up."
log_info "Station container: ${station_container_name}"
for agent_id in "${agent_ids[@]}"; do
  safe_agent="$(sanitize_name_component "$agent_id")"
  log_info "Agent container: ${agent_container_prefix}_${safe_agent}"
done

if [[ "$with_foxglove" == "1" ]]; then
  log_info "Foxglove websocket: ws://localhost:${foxglove_port}"
fi

log_info "Use ./scripts/docker_split_demo_down.sh to stop and remove split containers."
