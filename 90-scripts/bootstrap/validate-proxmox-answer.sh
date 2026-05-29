#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../logging/common-logging.sh"

ensure_debian_wsl

if [[ $# -ne 1 ]]; then
  die "Usage: $0 <answer-file>"
fi

if [[ ! -f "$1" ]]; then
  die "Answer file not found: $1"
fi

proxmox-auto-install-assistant validate-answer "$1"
log_info "Answer file validated: $1"
