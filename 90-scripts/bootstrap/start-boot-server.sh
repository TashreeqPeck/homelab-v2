#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BOOT_SERVER_PY="$REPO_ROOT/90-scripts/bootstrap/boot_server.py"
source "$SCRIPT_DIR/../logging/common-logging.sh"

ensure_debian_wsl

PXE_DIR="$REPO_ROOT/98-runtime/pxe/proxmox-auto"
ANSWER_FILE="$PXE_DIR/answer.runtime.toml"
BIND_ADDR="0.0.0.0"
PORT="8000"
ANSWER_PATH="/answer"

if [[ $# -ne 0 ]]; then
  die "This script does not accept arguments. Edit variables at the top of the file instead."
fi

if [[ ! -d "$PXE_DIR" ]]; then
  die "PXE directory not found: $PXE_DIR"
fi

if [[ ! -f "$ANSWER_FILE" ]]; then
  die "Rendered runtime answer file not found: $ANSWER_FILE. Run ./00-bootstrap/01-start-pxe-server.ps1 first."
fi

if ! command -v python3 >/dev/null 2>&1; then
  die "python3 is required but not installed."
fi

if [[ ! -f "$BOOT_SERVER_PY" ]]; then
  die "Boot server helper not found: $BOOT_SERVER_PY"
fi

if [[ "$ANSWER_PATH" != /* ]]; then
  die "--answer-path must start with '/'"
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  die "--port must be an integer between 1 and 65535"
fi

PRIMARY_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

log_info "Starting boot server"
log_info "PXE dir: $PXE_DIR"
log_info "Answer file: $ANSWER_FILE"
log_info "Bind: $BIND_ADDR:$PORT"
log_info "Answer path: $ANSWER_PATH"
if [[ -n "$PRIMARY_IP" ]]; then
  log_info "Suggested URL for prepare-iso: http://$PRIMARY_IP:$PORT$ANSWER_PATH"
fi

export PXE_DIR ANSWER_FILE BIND_ADDR PORT ANSWER_PATH

python3 "$BOOT_SERVER_PY"
