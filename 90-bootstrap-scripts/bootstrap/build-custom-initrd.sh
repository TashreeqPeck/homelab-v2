#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../logging/common-logging.sh"

ensure_debian_wsl

if [[ $# -ne 3 ]]; then
  die "Usage: $0 <initrd-source> <proxmox-iso> <custom-initrd-output>"
fi

initrd_source="$1"
prepared_iso="$2"
custom_initrd="$3"

if [[ ! -f "$initrd_source" ]]; then
  die "Initrd source not found: $initrd_source"
fi

if [[ ! -f "$prepared_iso" ]]; then
  die "Prepared ISO not found: $prepared_iso"
fi

for tool in zstd cpio find stat; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    die "Missing required tool: $tool"
  fi
done

output_dir="$(dirname "$custom_initrd")"
work_dir="$output_dir/.initrd-work"
addon_dir="$work_dir/addon"
initrd_cpio="$work_dir/initrd.cpio"
addon_cpio="$work_dir/addon.cpio"
custom_cpio="$work_dir/custom-initrd.cpio"

cleanup() {
  rm -rf "$work_dir"
}

trap cleanup EXIT

rm -rf "$work_dir"
mkdir -p "$addon_dir"

log_info "[initrd] Decompressing source initrd..."
if command -v pv >/dev/null 2>&1; then
  zstd -d -f -c "$initrd_source" | pv -pterab > "$initrd_cpio"
else
  zstd -d -f "$initrd_source" -o "$initrd_cpio"
fi

log_info "[initrd] Staging embedded proxmox.iso..."
if command -v pv >/dev/null 2>&1; then
  iso_size="$(stat -c%s "$prepared_iso")"
  pv -pterab -s "$iso_size" "$prepared_iso" > "$addon_dir/proxmox.iso"
else
  cp "$prepared_iso" "$addon_dir/proxmox.iso"
fi

log_info "[initrd] Creating addon cpio archive (can take a while for large ISO)..."
(
  cd "$addon_dir"
  if command -v pv >/dev/null 2>&1; then
    find . | cpio --quiet -o -H newc | pv -pterab > "$addon_cpio"
  else
    find . | cpio --quiet -o -H newc > "$addon_cpio"
  fi
)
log_info "[initrd] Addon cpio archive created."

log_info "[initrd] Combining cpio payloads..."
cat "$initrd_cpio" "$addon_cpio" > "$custom_cpio"

log_info "[initrd] Compressing custom initrd..."
if command -v pv >/dev/null 2>&1; then
  cpio_size="$(stat -c%s "$custom_cpio")"
  pv -pterab -s "$cpio_size" "$custom_cpio" | zstd -19 -f -o "$custom_initrd"
else
  zstd -19 -f "$custom_cpio" -o "$custom_initrd"
fi

log_info "[initrd] Custom initrd build completed."
