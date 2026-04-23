#!/usr/bin/env bash

set -euo pipefail

log_info() {
  echo "[INFO] $*"
}

log_warn() {
  echo "[WARN] $*"
}

log_error() {
  echo "[ERROR] $*" >&2
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_command() {
  local cmd="$1"
  if ! command_exists "$cmd"; then
    log_error "Required command not found: ${cmd}"
    exit 1
  fi
}

repo_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  dirname "$script_dir"
}

marker_dir() {
  echo "$(repo_root)/.bootstrap"
}

ensure_marker_dir() {
  mkdir -p "$(marker_dir)"
}

has_marker() {
  local name="$1"
  [[ -f "$(marker_dir)/${name}.done" ]]
}

write_marker() {
  local name="$1"
  ensure_marker_dir
  date -u +"%Y-%m-%dT%H:%M:%SZ" >"$(marker_dir)/${name}.done"
}

sudo_if_needed() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

source_ros() {
  local had_nounset=0
  if [[ $- == *u* ]]; then
    had_nounset=1
    set +u
  fi

  if [[ -f /opt/ros/kilted/setup.bash ]]; then
    # shellcheck disable=SC1091
    source /opt/ros/kilted/setup.bash
  fi

  local ws_setup
  ws_setup="$(repo_root)/install/setup.bash"
  if [[ "${SOURCE_WORKSPACE_OVERLAY:-1}" == "1" && -f "$ws_setup" ]]; then
    # shellcheck disable=SC1090
    source "$ws_setup"
  fi

  if [[ $had_nounset -eq 1 ]]; then
    set -u
  fi
}

default_network_interface() {
  local iface
  iface="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
  if [[ -n "$iface" ]]; then
    echo "$iface"
  else
    echo "lo"
  fi
}

default_fault_interface() {
  # Use loopback by default so fault injection does not touch the internet path.
  echo "${LINK_ASSURANCE_TC_IFACE:-lo}"
}

assert_safe_fault_interface() {
  local iface="$1"
  local default_iface
  default_iface="$(default_network_interface)"

  if [[ "$iface" == "$default_iface" && "${LINK_ASSURANCE_ALLOW_PRIMARY_IFACE:-0}" != "1" ]]; then
    log_error "Refusing to run tc on primary interface '${iface}' by default."
    log_error "Use LINK_ASSURANCE_TC_IFACE=lo (recommended) or set LINK_ASSURANCE_ALLOW_PRIMARY_IFACE=1 to override."
    exit 1
  fi
}

clear_qdisc_root() {
  local iface="$1"
  sudo_if_needed tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
}

wait_for_service() {
  local service_name="$1"
  local timeout_s="${2:-20}"
  local deadline=$((SECONDS + timeout_s))

  while (( SECONDS < deadline )); do
    if ros2 service list | grep -Fxq "$service_name"; then
      return 0
    fi
    sleep 1
  done

  return 1
}

trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  echo "$value"
}

is_non_negative_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

is_positive_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 ))
}

normalize_bool() {
  local raw
  raw="$(trim_whitespace "$1")"
  raw="${raw,,}"

  case "$raw" in
    1|true|yes|on)
      echo "1"
      ;;
    0|false|no|off)
      echo "0"
      ;;
    *)
      return 1
      ;;
  esac
}

parse_csv_values() {
  local csv="$1"
  local -n out_values="$2"
  local IFS=','
  local -a raw_parts=()
  local part=""
  local trimmed=""

  out_values=()
  read -r -a raw_parts <<<"$csv"

  for part in "${raw_parts[@]}"; do
    trimmed="$(trim_whitespace "$part")"
    if [[ -z "$trimmed" ]]; then
      continue
    fi
    out_values+=("$trimmed")
  done

  if (( ${#out_values[@]} == 0 )); then
    return 1
  fi

  return 0
}
