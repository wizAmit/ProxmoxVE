#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/AdguardTeam/AdGuardHome | https://github.com/NLnetLabs/unbound
# Shared helpers for the host-side facade. Sourced, not executed.

DRY_RUN="${DRY_RUN:-0}"
STAGE_DIR=/root/.adguard-unbound

# Colors only on a terminal: as a var_post_install hook, output goes to a log file.
if [[ -t 1 ]]; then _GN=$'\033[32m' _YW=$'\033[33m' _RD=$'\033[31m' _CL=$'\033[0m'; else _GN="" _YW="" _RD="" _CL=""; fi

log() { printf '%s[+]%s %s\n' "$_GN" "$_CL" "$*"; }
warn() { printf '%s[!]%s %s\n' "$_YW" "$_CL" "$*" >&2; }
die() {
  printf '%s[x]%s %s\n' "$_RD" "$_CL" "$*" >&2
  exit 1
}

# Run a mutating command, or just print it in --dry-run mode.
run() {
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '    (dry-run) %s\n' "$*"
    return 0
  fi
  "$@"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found - run this on the Proxmox VE host"
}

ct_exists() { pct config "$1" >/dev/null 2>&1; }

ct_ensure_running() {
  local ctid="$1"
  ct_exists "$ctid" || die "container $ctid not found"
  if [[ "$(pct status "$ctid")" != "status: running" ]]; then
    log "starting container $ctid"
    run pct start "$ctid"
    [[ "$DRY_RUN" == 1 ]] || sleep 5
  fi
}

ct_require_bash() {
  pct exec "$1" -- sh -c 'command -v bash >/dev/null 2>&1' ||
    die "container $1 has no bash (on Alpine: apk add bash)"
}

ct_ip() {
  local cmd="ip -4 -o addr show dev eth0 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1"
  pct exec "$1" -- sh -c "$cmd" | tr -d '\r'
}

# Print the IDs of containers whose tags contain $1.
find_ct_by_tag() {
  local tag="$1" id
  for id in $(pct list | awk 'NR>1 {print $1}'); do
    if pct config "$id" 2>/dev/null | grep -qiE "^tags:.*(^|[ ;])${tag}([ ;]|$)"; then
      echo "$id"
    fi
  done
}

# ct_push CTID SRC DEST [PERMS]
ct_push() {
  local ctid="$1" src="$2" dest="$3" perms="${4:-0644}"
  run pct exec "$ctid" -- mkdir -p "$(dirname "$dest")"
  run pct push "$ctid" "$src" "$dest" --perms "$perms"
}

# ct_run CTID MODULE [VAR=value ...]  - push a module into the container and run it.
ct_run() {
  local ctid="$1" module="$2"
  shift 2
  local dest="$STAGE_DIR/$(basename "$module")"
  [[ -f "$module" ]] || die "module not found: $module"
  ct_push "$ctid" "$module" "$dest" 0755
  run pct exec "$ctid" -- env "$@" bash "$dest"
}
