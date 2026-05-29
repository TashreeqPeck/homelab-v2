#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/lib/homelab-bootstrap"
CONFIGURE_SYSTEM_MARKER="$STATE_DIR/configure-system.done"
PROVISION_USERS_MARKER="$STATE_DIR/provision-users.done"
PROVISION_USERS_LOG="$STATE_DIR/provision-users.log"
PROVISION_USERS_ENV_PATH="${PROVISION_USERS_ENV_PATH:-/tmp/homelab-postinstall/provision-users.env}"
PROVISION_USERS_PLAYBOOK_PATH="${PROVISION_USERS_PLAYBOOK_PATH:-/tmp/homelab-postinstall/provision-users.yml}"

mkdir -p "$STATE_DIR"

exec > >(tee -a "$PROVISION_USERS_LOG") 2>&1

if [[ ! -f "$CONFIGURE_SYSTEM_MARKER" ]]; then
  echo "provision-users blocked: configure-system marker missing" >&2
  exit 1
fi

if [[ -f "$PROVISION_USERS_MARKER" ]]; then
  echo "provision-users already complete"
  exit 0
fi

if [[ ! -f "$PROVISION_USERS_ENV_PATH" ]]; then
  echo "provision-users blocked: secrets file missing at $PROVISION_USERS_ENV_PATH" >&2
  exit 1
fi

if [[ ! -f "$PROVISION_USERS_PLAYBOOK_PATH" ]]; then
  echo "provision-users blocked: playbook missing at $PROVISION_USERS_PLAYBOOK_PATH" >&2
  exit 1
fi

source "$PROVISION_USERS_ENV_PATH"

required_vars=(
  ADMIN_USERNAME
  ADMIN_PASSWORD
  ADMIN_PROXMOX_USER
  SERVICE_PROXMOX_USER
)

for name in "${required_vars[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "provision-users blocked: required variable missing in secrets file: $name" >&2
    exit 1
  fi
done

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "provision-users blocked: ansible-playbook is not installed" >&2
  exit 1
fi

if [[ "${ADMIN_PASSWORD}" == *$'\n'* || "${ADMIN_PASSWORD}" == *$'\r'* ]]; then
  echo "provision-users blocked: ADMIN_PASSWORD must not contain newlines" >&2
  exit 1
fi

if [[ -z "${ADMIN_PASSWORD}" ]]; then
  echo "provision-users blocked: ADMIN_PASSWORD must not be empty" >&2
  exit 1
fi

tmp_dir="$(mktemp -d /tmp/provision-users-XXXXXX)"
inventory_file="$tmp_dir/inventory.ini"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

cat > "$inventory_file" <<'INI'
[localhost]
localhost ansible_connection=local
INI

export ADMIN_USERNAME
export ADMIN_PASSWORD
export ADMIN_SSH_PUBLIC_KEY="${ADMIN_SSH_PUBLIC_KEY:-}"
export ADMIN_PROXMOX_USER
export ADMIN_PROXMOX_ROLE="${ADMIN_PROXMOX_ROLE:-Administrator}"
export SERVICE_PROXMOX_USER
export SERVICE_PROXMOX_ROLE="${SERVICE_PROXMOX_ROLE:-PVEAdmin}"
export SERVICE_TOKEN_NAME="${SERVICE_TOKEN_NAME:-bootstrap}"
export SERVICE_TOKEN_OUTPUT_PATH="${SERVICE_TOKEN_OUTPUT_PATH:-/var/lib/homelab-bootstrap/service-token.json}"

ansible-playbook -i "$inventory_file" "$PROVISION_USERS_PLAYBOOK_PATH"

date -u +"%Y-%m-%dT%H:%M:%SZ" > "$PROVISION_USERS_MARKER"
echo "provision-users complete"