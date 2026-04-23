#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/common.sh"

source_ros
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}"

log_error "Agent subsystem injection is no longer supported in this workspace."
log_error "Link assurance now focuses on transport health plus station service readiness only."
log_error "Use ./scripts/run_inject_network.sh, ./scripts/run_inject_disconnect.sh, or ./scripts/run_inject_station_services.sh instead."
exit 2
