#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

ROOT="$(repo_root)"

log_info "Fetching reproducible dependencies."

SOURCE_WORKSPACE_OVERLAY=0 source_ros

mkdir -p "${ROOT}/src"

import_vcs_repos_file() {
  local repos_file="$1"
  local label="$2"

  if [[ ! -f "$repos_file" ]]; then
    log_info "No ${label} file found at ${repos_file}; skipping."
    return
  fi

  if grep -q '<org>' "$repos_file"; then
    log_warn "${label} contains placeholder URLs; skipping import until URLs are set."
    return
  fi

  log_info "Importing repositories listed in ${repos_file}."
  vcs import "${ROOT}/src" <"$repos_file"
}

import_vcs_repos_file "${ROOT}/dependencies.repos" "external dependency repos"
import_vcs_repos_file "${ROOT}/link_assurance_packages.repos" "link assurance package repos"

log_info "Installing rosdep system dependencies from local sources."

if [[ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
  log_info "rosdep is not initialized in this container; initializing now."
  sudo_if_needed rosdep init
fi

rosdep update
rosdep install --from-paths "${ROOT}/src" --ignore-src -r -y --rosdistro kilted --skip-keys ament_python

log_info "Dependency fetch complete."
