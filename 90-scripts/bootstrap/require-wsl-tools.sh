#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../logging/common-logging.sh"

ensure_debian_wsl

if [[ $# -lt 1 ]]; then
  die "Usage: $0 <tool> [tool ...]"
fi

for tool in "$@"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    die "Missing required tool: $tool"
  fi
done

log_info "Verified required tools in WSL: $*"
