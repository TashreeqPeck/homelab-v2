#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/lib/homelab-bootstrap"
CONFIGURE_SYSTEM_MARKER="$STATE_DIR/configure-system.done"
LOG_FILE="$STATE_DIR/configure-system.log"

mkdir -p "$STATE_DIR"

exec > >(tee -a "$LOG_FILE") 2>&1

if [[ -f "$CONFIGURE_SYSTEM_MARKER" ]]; then
  echo "configure-system already complete"
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive

disable_enterprise_repo_file() {
  local repo_file="$1"
  if [[ ! -f "$repo_file" ]]; then
    return
  fi

  if ! grep -q 'enterprise\.proxmox\.com' "$repo_file"; then
    return
  fi

  local disabled_file="${repo_file}.disabled"
  echo "[configure-system] disabling enterprise repo file ${repo_file}"
  cp "$repo_file" "${repo_file}.bak" || true
  mv "$repo_file" "$disabled_file"
}

echo "[configure-system] preparing apt repositories"
disable_enterprise_repo_file /etc/apt/sources.list.d/pve-enterprise.list
disable_enterprise_repo_file /etc/apt/sources.list.d/pve-enterprise.sources
disable_enterprise_repo_file /etc/apt/sources.list.d/ceph.list
disable_enterprise_repo_file /etc/apt/sources.list.d/ceph.sources

if [[ ! -f /etc/apt/sources.list.d/pve-no-subscription.list ]]; then
  release_codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-bookworm}")"
  echo "[configure-system] adding pve-no-subscription repo for ${release_codename}"
  cat > /etc/apt/sources.list.d/pve-no-subscription.list <<EOF
deb http://download.proxmox.com/debian/pve ${release_codename} pve-no-subscription
EOF
fi

echo "[configure-system] refreshing package metadata"
apt-get update

echo "[configure-system] installing baseline packages"
apt-get install -y --no-install-recommends \
  avahi-daemon \
  ca-certificates \
  curl \
  git \
  python3 \
  python3-apt \
  sudo

if apt-cache show ansible-core >/dev/null 2>&1; then
  echo "[configure-system] installing ansible-core"
  apt-get install -y --no-install-recommends ansible-core
elif apt-cache show ansible >/dev/null 2>&1; then
  echo "[configure-system] installing ansible"
  apt-get install -y --no-install-recommends ansible
else
  echo "[configure-system] ansible package unavailable in current repos; continuing"
fi

echo "[configure-system] enabling avahi daemon"
systemctl enable --now avahi-daemon

echo "[configure-system] enabling NTP sync"
timedatectl set-ntp true

echo "[configure-system] writing bootstrap readiness marker"
mkdir -p /opt/homelab-bootstrap
cat > /opt/homelab-bootstrap/bootstrap-readiness.json <<'JSON'
{
  "bootstrap_ready": true,
  "manager": "ansible",
  "stage": "configure-system"
}
JSON

date -u +"%Y-%m-%dT%H:%M:%SZ" > "$CONFIGURE_SYSTEM_MARKER"
echo "configure-system complete"