#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/90-scripts/logging/common-logging.sh"

ensure_debian_wsl

if [[ ! -r /etc/os-release ]]; then
  die "Unable to detect Debian release from /etc/os-release"
fi

. /etc/os-release

codename="${VERSION_CODENAME:-}"
version_id="${VERSION_ID:-}"
version_text="${VERSION:-} ${PRETTY_NAME:-}"
version_text=${version_text,,}

if [[ -z "$codename" ]]; then
  case "$version_text" in
    *trixie*) codename="trixie" ;;
    *bookworm*) codename="bookworm" ;;
  esac
fi

if [[ -z "$codename" ]]; then
  case "$version_id" in
    13) codename="trixie" ;;
    12) codename="bookworm" ;;
  esac
fi

case "$codename" in
  trixie)
    key_url="https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg"
    ;;
  bookworm)
    key_url="https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg"
    ;;
  *)
    die "Unsupported Debian release '$codename'. Expected bookworm or trixie."
    ;;
esac

log_info "Debian codename: $codename"
log_info "Proxmox key URL: $key_url"

apt_index_updated=0
sudo_validated=0

ensure_sudo_auth() {
  if [[ "$sudo_validated" -eq 1 ]]; then
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    die "sudo is required to install or configure dependencies, but was not found."
  fi

  sudo -v
  sudo_validated=1
}

ensure_packages() {
  local missing=()
  local package

  for package in "$@"; do
    if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
      missing+=("$package")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    log_info "Already installed: $*"
    return 0
  fi

  ensure_sudo_auth

  if [[ "$apt_index_updated" -eq 0 ]]; then
    sudo apt update
    apt_index_updated=1
  fi

  sudo DEBIAN_FRONTEND=noninteractive apt install -y "${missing[@]}"
}

ensure_packages curl ca-certificates python3

keyring_path="/usr/share/keyrings/proxmox-archive-keyring.gpg"
sources_path="/etc/apt/sources.list.d/proxmox.sources"
new_keyring="$(mktemp)"
new_sources="$(mktemp)"

cleanup_tmp_files() {
  rm -f "$new_keyring" "$new_sources"
}

trap cleanup_tmp_files EXIT

if [[ ! -f "$keyring_path" ]]; then
  log_info "Proxmox keyring not found; downloading..."
  if ! curl -fL --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 2 "$key_url" -o "$new_keyring"; then
    die "Failed to download Proxmox keyring from $key_url"
  fi
fi

cat > "$new_sources" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: $codename
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

if [[ ! -f "$keyring_path" ]]; then
  ensure_sudo_auth
  sudo install -d -m 0755 /usr/share/keyrings
  sudo install -m 0644 "$new_keyring" "$keyring_path"
  apt_index_updated=0
fi

if [[ ! -f "$sources_path" ]] || ! cmp -s "$new_sources" "$sources_path"; then
  ensure_sudo_auth
  sudo install -d -m 0755 /etc/apt/sources.list.d
  sudo install -m 0644 "$new_sources" "$sources_path"
  apt_index_updated=0
fi

# A new repository source was added above, refresh apt index before checking package availability.
apt_index_updated=0
ensure_packages proxmox-auto-install-assistant xorriso dnsmasq ipxe zstd cpio pv

log_info "Installed dependencies (or confirmed already installed): proxmox-auto-install-assistant, xorriso, python3, dnsmasq, ipxe, zstd, cpio, pv"