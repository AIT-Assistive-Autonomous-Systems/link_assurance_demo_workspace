#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

log_info "Installing required system dependencies for ROS 2 Kilted + Zenoh."

if ! command_exists apt-get; then
  log_error "apt-get not found. This script targets Ubuntu 24.04."
  exit 1
fi

sudo_if_needed apt-get update

if ! apt-cache show ros-kilted-rmw-zenoh-cpp >/dev/null 2>&1; then
  log_error "Required package ros-kilted-rmw-zenoh-cpp is not available. Failing fast as requested."
  exit 2
fi

packages=(
  curl
  git
  iproute2
  build-essential
  cmake
  python3-pip
  python3-colcon-common-extensions
  python3-rosdep
  python3-vcstool
  clang-format
  clang-tidy
  cpplint
  ros-kilted-ros-base
  ros-kilted-rmw-zenoh-cpp
  ros-kilted-diagnostic-updater
  ros-kilted-diagnostic-msgs
  ros-kilted-diagnostic-aggregator
  ros-kilted-rqt
  ros-kilted-rqt-robot-monitor
  ros-kilted-foxglove-bridge
)

sudo_if_needed apt-get install -y --no-install-recommends "${packages[@]}"

if [[ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
  log_info "Initializing rosdep."
  sudo_if_needed rosdep init
fi

rosdep update

if ! grep -q "source /opt/ros/kilted/setup.bash" "${HOME}/.bashrc"; then
  {
    echo "source /opt/ros/kilted/setup.bash"
    echo "export RMW_IMPLEMENTATION=rmw_zenoh_cpp"
    echo "export ROS_DOMAIN_ID=42"
  } >>"${HOME}/.bashrc"
fi

log_info "System dependency installation complete."
