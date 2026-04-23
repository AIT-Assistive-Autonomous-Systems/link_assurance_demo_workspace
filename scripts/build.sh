#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

USAGE="Usage: scripts/build.sh [--skip-tests]"
SKIP_TESTS=false

for arg in "$@"; do
  case "$arg" in
    --skip-tests)
      SKIP_TESTS=true
      ;;
    *)
      log_error "$USAGE"
      exit 1
      ;;
  esac
done

ROOT="$(repo_root)"
source_ros

export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}"

log_info "Building workspace at ${ROOT}."
cd "${ROOT}"

colcon build \
  --symlink-install \
  --event-handlers console_direct+ \
  --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo

if [[ "$SKIP_TESTS" == true ]]; then
  log_info "Skipping tests by request."
else
  log_info "Running tests."
  colcon test --event-handlers console_direct+
  colcon test-result --verbose
fi

log_info "Build and test completed."
