#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/AdguardTeam/AdGuardHome | https://github.com/NLnetLabs/unbound
# adguard-unbound.sh - facade that wires AdGuard Home to Unbound (with fallback).
# Run on the Proxmox VE host as root.
#
# Topologies:
#   local     Unbound runs inside the AdGuard Home LXC on 127.0.0.1:5335 (default)
#   separate  Unbound runs in its own LXC and answers on the LAN, port 53
#
# Steps (default: all):
#   unbound    install and configure Unbound
#   watchdog   install the recursion watchdog (switches Unbound to forwarding
#              when recursion breaks, back when it recovers)
#   adguard    point AdGuard Home at Unbound (+ fallback servers)
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

MODE=local
ADGUARD_CT=""
UNBOUND_CT=""
FALLBACK="9.9.9.9,1.1.1.1"
EXTRA_ALLOW=""
LISTEN=""
PORT=""
APPLY=0
NO_WATCHDOG=0
STEPS=()

usage() {
  cat <<'EOF'
Usage: adguard-unbound.sh [options] [step ...]

Steps:  unbound | watchdog | adguard | all (default)

Options:
  --mode local|separate   topology (default: local)
  --adguard CTID          AdGuard Home container (default: the one tagged "adblock")
  --unbound CTID          Unbound container (required for --mode separate)
  --fallback LIST         comma-separated fallback DNS servers (default: 9.9.9.9,1.1.1.1)
  --allow CIDR[,CIDR]     extra networks allowed to query Unbound (separate mode)
  --listen ADDR           override Unbound listen address
  --port N                override Unbound port
  --apply-adguard         edit AdGuardHome.yaml (needs the setup wizard finished);
                          without it, the adguard step only prints what to set
  --no-watchdog           skip the watchdog step
  --dry-run               print what would run, change nothing
  -h, --help              show this help

Examples:
  adguard-unbound.sh --adguard 105
  adguard-unbound.sh --mode separate --adguard 105 --unbound 106 --apply-adguard
  adguard-unbound.sh --adguard 105 adguard --apply-adguard   # only re-run one step
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:?--mode needs a value}"; shift 2 ;;
    --adguard) ADGUARD_CT="${2:?--adguard needs a CTID}"; shift 2 ;;
    --unbound) UNBOUND_CT="${2:?--unbound needs a CTID}"; shift 2 ;;
    --fallback) FALLBACK="${2?--fallback needs a value}"; shift 2 ;;
    --allow) EXTRA_ALLOW="${2:?--allow needs a value}"; shift 2 ;;
    --listen) LISTEN="${2:?--listen needs a value}"; shift 2 ;;
    --port) PORT="${2:?--port needs a value}"; shift 2 ;;
    --apply-adguard) APPLY=1; shift ;;
    --no-watchdog) NO_WATCHDOG=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    unbound | watchdog | adguard) STEPS+=("$1"); shift ;;
    all) STEPS+=(unbound watchdog adguard); shift ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ ${#STEPS[@]} -gt 0 ]] || STEPS=(unbound watchdog adguard)
has_step() { local s; for s in "${STEPS[@]}"; do [[ "$s" == "$1" ]] && return 0; done; return 1; }

[[ "$MODE" == local || "$MODE" == separate ]] || die "--mode must be 'local' or 'separate'"
need_cmd pct

# --- resolve containers -------------------------------------------------------
if [[ -z "$ADGUARD_CT" ]]; then
  mapfile -t found < <(find_ct_by_tag adblock)
  if [[ ${#found[@]} -eq 1 ]]; then
    ADGUARD_CT="${found[0]}"
    log "auto-detected AdGuard container: $ADGUARD_CT"
  else
    die "could not pick the AdGuard container (tag 'adblock' matches: ${found[*]:-none}); use --adguard CTID"
  fi
fi

if [[ "$MODE" == local ]]; then
  UNBOUND_CT="$ADGUARD_CT"
  : "${LISTEN:=127.0.0.1}"
  : "${PORT:=5335}"
else
  [[ -n "$UNBOUND_CT" ]] || die "--mode separate needs --unbound CTID"
  [[ "$UNBOUND_CT" != "$ADGUARD_CT" ]] || die "--unbound and --adguard must differ in separate mode"
  : "${LISTEN:=0.0.0.0}"
  : "${PORT:=53}"
fi

ct_ensure_running "$ADGUARD_CT"
[[ "$UNBOUND_CT" == "$ADGUARD_CT" ]] || ct_ensure_running "$UNBOUND_CT"
ct_require_bash "$ADGUARD_CT"
[[ "$UNBOUND_CT" == "$ADGUARD_CT" ]] || ct_require_bash "$UNBOUND_CT"

# --- derive addresses / ACLs ----------------------------------------------------
if [[ "$MODE" == local ]]; then
  ALLOW="127.0.0.0/8"
  UPSTREAM="127.0.0.1:${PORT}"
else
  ADGUARD_IP="$(ct_ip "$ADGUARD_CT")"
  UNBOUND_IP="$(ct_ip "$UNBOUND_CT")"
  [[ -n "$ADGUARD_IP" ]] || die "could not read the IP of container $ADGUARD_CT"
  [[ -n "$UNBOUND_IP" ]] || die "could not read the IP of container $UNBOUND_CT"
  ALLOW="127.0.0.0/8,${ADGUARD_IP}/32"
  [[ -z "$EXTRA_ALLOW" ]] || ALLOW="${ALLOW},${EXTRA_ALLOW}"
  UPSTREAM="$UNBOUND_IP"
  [[ "$PORT" == 53 ]] || UPSTREAM="${UNBOUND_IP}:${PORT}"
  warn "Unbound LXC is at ${UNBOUND_IP}; give it a static IP or a DHCP reservation."
fi

CHECK_ADDR="$LISTEN"
[[ "$LISTEN" != 0.0.0.0 ]] || CHECK_ADDR=127.0.0.1

# --- steps ----------------------------------------------------------------------
step_unbound() {
  log "Unbound: installing in CT $UNBOUND_CT (listen ${LISTEN}:${PORT})"
  ct_run "$UNBOUND_CT" "$ROOT/modules/unbound-install.sh" \
    UNBOUND_LISTEN="$LISTEN" UNBOUND_PORT="$PORT" UNBOUND_ALLOW="$ALLOW"
}

step_watchdog() {
  if [[ "$NO_WATCHDOG" == 1 ]]; then
    log "Watchdog: skipped (--no-watchdog)"
    return 0
  fi
  log "Watchdog: installing in CT $UNBOUND_CT (fallback: ${FALLBACK:-none})"
  ct_push "$UNBOUND_CT" "$ROOT/payload/unbound-watchdog.sh" "$STAGE_DIR/unbound-watchdog.sh" 0755
  ct_run "$UNBOUND_CT" "$ROOT/modules/watchdog-install.sh" \
    FALLBACK="$FALLBACK" CHECK_ADDR="$CHECK_ADDR" CHECK_PORT="$PORT"
}

step_adguard() {
  log "AdGuard Home: upstream ${UPSTREAM}, fallback ${FALLBACK:-none} (CT $ADGUARD_CT)"
  ct_run "$ADGUARD_CT" "$ROOT/modules/adguard-upstream.sh" \
    UPSTREAM="$UPSTREAM" FALLBACK="$FALLBACK" APPLY="$APPLY"
}

has_step unbound && step_unbound
has_step watchdog && step_watchdog
has_step adguard && step_adguard

# --- summary ----------------------------------------------------------------------
echo
log "Done. Mode: $MODE | Unbound CT: $UNBOUND_CT | AdGuard CT: $ADGUARD_CT | upstream: $UPSTREAM"
if [[ "$MODE" == separate ]]; then
  echo "    Make sure Unbound starts before AdGuard Home:"
  echo "      pct set $UNBOUND_CT --startup order=1,up=10"
  echo "      pct set $ADGUARD_CT --startup order=2"
fi
if [[ "$APPLY" != 1 ]] && has_step adguard; then
  echo "    Re-run with '--apply-adguard' after the AdGuard setup wizard to edit its config,"
  echo "    or set the values above in Settings > DNS settings by hand."
fi
