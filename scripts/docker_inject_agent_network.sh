#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[WARN] ./scripts/docker_inject_agent_network.sh is deprecated. Use ./scripts/docker_inject_network.sh instead." >&2
exec "${ROOT_DIR}/scripts/docker_inject_network.sh" "$@"
