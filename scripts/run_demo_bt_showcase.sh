#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
This helper script is deprecated and no longer launches the demo.

Use the unified launcher instead:
	./scripts/run_demo_start.sh --agents <N> --with-bt

Examples:
	./scripts/run_demo_start.sh --with-bt
	./scripts/run_demo_start.sh --agents 1 --with-bt
EOF
}

case "${1:-}" in
	-h|--help)
		usage
		exit 0
		;;
esac

usage >&2
exit 2
