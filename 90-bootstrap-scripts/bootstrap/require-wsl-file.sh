#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../logging/common-logging.sh"

ensure_debian_wsl

if [[ $# -ne 1 ]]; then
  die "Usage: $0 <file-path>"
fi

if [[ ! -f "$1" ]]; then
  die "File not found in WSL: $1"
fi

log_info "Verified file exists in WSL: $1"
