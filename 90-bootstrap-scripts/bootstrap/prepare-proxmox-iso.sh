#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../logging/common-logging.sh"

ensure_debian_wsl

if [[ $# -ne 3 ]]; then
  die "Usage: $0 <iso-path> <answer-url> <output-dir>"
fi

iso_path="$1"
answer_url="$2"
output_dir="$3"

if [[ ! -f "$iso_path" ]]; then
  die "ISO file not found: $iso_path"
fi

if [[ -z "$answer_url" ]] || [[ "$answer_url" != http*://* ]]; then
  die "Answer URL must be a valid http(s) URL."
fi

if ! command -v proxmox-auto-install-assistant >/dev/null 2>&1; then
  die "proxmox-auto-install-assistant is required. Run ./00-bootstrap/00-install-dependencies.ps1 first."
fi

mkdir -p "$output_dir"
log_info "Preparing Proxmox PXE assets"
log_info "ISO path: $iso_path"
log_info "Answer URL: $answer_url"
log_info "Output dir: $output_dir"

proxmox-auto-install-assistant prepare-iso \
  "$iso_path" \
  --fetch-from http \
  --url "$answer_url" \
  --pxe-loader ipxe \
  --output "$output_dir"

log_info "prepare-iso completed successfully"
