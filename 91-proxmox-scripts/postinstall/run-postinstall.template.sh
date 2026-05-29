#!/usr/bin/env bash
set -euo pipefail

node_id="__NODE_ID__"
run_id="__RUN_ID__"
progress_url="__PROGRESS_URL__"
final_url="__FINAL_URL__"
runner_base_url="__RUNNER_BASE_URL__"
shared_files_base_url="$runner_base_url"
configure_system_url="${shared_files_base_url}/configure-system.sh"
provision_users_url="${shared_files_base_url}/provision-users.sh"
provision_users_env_url="${shared_files_base_url}/provision-users.env"
provision_users_playbook_url="${shared_files_base_url}/provision-users.yml"

work_dir="/tmp/homelab-postinstall"
mkdir -p "$work_dir"
shared_files_dir="$work_dir/shared-files"
mkdir -p "$shared_files_dir"
log_file="$work_dir/runner.log"

exec > >(tee -a "$log_file") 2>&1

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

send_progress() {
  local phase="$1"
  local step="$2"
  local status="$3"
  local message="$4"
  local phase_json
  local step_json
  local status_json
  local message_json
  phase_json="$(json_escape "$phase")"
  step_json="$(json_escape "$step")"
  status_json="$(json_escape "$status")"
  message_json="$(json_escape "$message")"
  curl --silent --show-error --fail --retry 3 --retry-delay 2 --retry-all-errors \
    -H 'Content-Type: application/json' \
    -d "{\"run_id\":\"${run_id}\",\"node_id\":\"${node_id}\",\"phase\":\"${phase_json}\",\"step\":\"${step_json}\",\"status\":\"${status_json}\",\"message\":\"${message_json}\"}" \
    "$progress_url" >/dev/null
}

send_final() {
  local status="$1"
  local message="$2"
  local status_json
  local message_json
  status_json="$(json_escape "$status")"
  message_json="$(json_escape "$message")"
  curl --silent --show-error --fail --retry 3 --retry-delay 2 --retry-all-errors \
    -H 'Content-Type: application/json' \
    -d "{\"run_id\":\"${run_id}\",\"node_id\":\"${node_id}\",\"status\":\"${status_json}\",\"message\":\"${message_json}\"}" \
    "$final_url" >/dev/null
}

current_phase="runner"
current_step="init"

on_error() {
  local lineno="$1"
  local message="runner failed phase=${current_phase} step=${current_step} line=${lineno}"
  local log_tail=""

  if [[ -f "$log_file" ]]; then
    log_tail="$(tail -n 60 "$log_file" || true)"
    if [[ -n "$log_tail" ]]; then
      # Keep payload bounded so callbacks remain reliable.
      log_tail="${log_tail: -3000}"
      message="${message} | log_tail=${log_tail}"
    fi
  fi

  send_progress "$current_phase" "$current_step" failed "$message" || true
  send_final failed "$message" || true
}

trap 'on_error "$LINENO"' ERR

current_phase="configure-system"
current_step="fetch"
send_progress configure-system fetch started "Downloading configure-system script"
curl --silent --show-error --fail "$configure_system_url" -o "$work_dir/configure-system.sh"
chmod +x "$work_dir/configure-system.sh"

current_phase="configure-system"
current_step="execute"
send_progress configure-system execute started "Running configure-system"
"$work_dir/configure-system.sh"
send_progress configure-system execute completed "Configure-system completed"

current_phase="provision-users"
current_step="fetch"
send_progress provision-users fetch started "Downloading provision-users script"
curl --silent --show-error --fail "$provision_users_url" -o "$work_dir/provision-users.sh"
chmod +x "$work_dir/provision-users.sh"
curl --silent --show-error --fail "$provision_users_env_url" -o "$shared_files_dir/provision-users.env"
chmod 600 "$shared_files_dir/provision-users.env"
curl --silent --show-error --fail "$provision_users_playbook_url" -o "$shared_files_dir/provision-users.yml"
chmod 600 "$shared_files_dir/provision-users.yml"

current_phase="provision-users"
current_step="execute"
send_progress provision-users execute started "Running provision-users"
PROVISION_USERS_ENV_PATH="$shared_files_dir/provision-users.env" \
PROVISION_USERS_PLAYBOOK_PATH="$shared_files_dir/provision-users.yml" \
"$work_dir/provision-users.sh"
send_progress provision-users execute completed "Provision-users completed"

send_final success "postinstall runner completed"
