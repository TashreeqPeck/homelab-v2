#!/usr/bin/env bash

# Shared logging and runtime checks for bootstrap scripts.

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

script_name() {
  if [[ -n "${SCRIPT_NAME:-}" ]]; then
    printf '%s' "$SCRIPT_NAME"
  else
    local source_index
    source_index=$(( ${#BASH_SOURCE[@]} - 1 ))
    if (( source_index < 0 )); then
      source_index=0
    fi
    printf '%s' "$(basename "${BASH_SOURCE[$source_index]:-$0}")"
  fi
}

_log() {
  local level="$1"
  shift
  printf '[%s] [%s] [%s] %s\n' "$(timestamp)" "$level" "$(script_name)" "$*"
}

log_info() {
  _log "INFO" "$@"
}

log_warn() {
  _log "WARN" "$@"
}

log_error() {
  _log "ERROR" "$@" >&2
}

die() {
  log_error "$@"
  exit 1
}

ensure_debian_wsl() {
  if [[ ! -f /proc/sys/kernel/osrelease ]] || ! grep -qi 'microsoft\|wsl' /proc/sys/kernel/osrelease; then
    die "This script must run inside Debian WSL."
  fi

  if [[ ! -r /etc/os-release ]]; then
    die "Unable to read /etc/os-release for distro verification."
  fi

  local os_id
  os_id="$(awk -F= '/^ID=/{gsub(/"/, "", $2); print tolower($2)}' /etc/os-release)"
  if [[ "$os_id" != "debian" ]]; then
    die "Unsupported distro '$os_id'. Debian WSL is required."
  fi
}
