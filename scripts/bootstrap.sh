#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

USAGE="Usage: scripts/bootstrap.sh [--devcontainer] [--skip-build] [--skip-tests]"

DEVCONTAINER_MODE=false
SKIP_BUILD=false
SKIP_TESTS=false

for arg in "$@"; do
  case "$arg" in
    --devcontainer)
      DEVCONTAINER_MODE=true
      ;;
    --skip-build)
      SKIP_BUILD=true
      ;;
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

log_info "Bootstrap starting in ${ROOT}."

if [[ "$DEVCONTAINER_MODE" == true ]]; then
  log_info "Running in devcontainer mode."
  if [[ "$SKIP_TESTS" == false ]]; then
    log_info "Devcontainer mode defaults to skipping tests during bootstrap."
    SKIP_TESTS=true
  fi
fi

if ! has_marker "system_deps"; then
  log_info "Installing system dependencies."
  "${SCRIPT_DIR}/install_system_deps.sh"
  write_marker "system_deps"
else
  log_info "System dependencies already installed; skipping."
fi

if ! has_marker "dependencies"; then
  log_info "Fetching workspace dependencies."
  "${SCRIPT_DIR}/fetch_dependencies.sh"
  write_marker "dependencies"
else
  log_info "Workspace dependencies already fetched; skipping."
fi

if [[ "$SKIP_BUILD" == false ]]; then
  log_info "Building workspace."
  if [[ "$SKIP_TESTS" == true ]]; then
    "${SCRIPT_DIR}/build.sh" --skip-tests
  else
    "${SCRIPT_DIR}/build.sh"
  fi
else
  log_info "Skipping build by request."
fi

log_info "Bootstrap completed successfully."
