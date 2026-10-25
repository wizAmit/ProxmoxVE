#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/AdguardTeam/AdGuardHome | https://github.com/NLnetLabs/unbound
#
# var_post_install hook for the Adguard LXC script.
#
# build.func runs hooks ON THE PROXMOX HOST as root, after the container has been created and started,
# with APP, NSAPP, CTID, IP, HN, STORAGE and BRG in the environment (see tools/pve/post-install-hook-examples.sh).
# This wrapper adds Unbound (and the fallback watchdog) to the new AdGuard container.
#
# Setup (the whole adguard-unbound directory must exist on the host, e.g. a git clone or tarball):
#   1. Edit the CONFIG block below.
#   2. In /root/.community-scripts/default.vars (or app.vars, or Advanced Settings -> post-install step):
#        var_post_install=/opt/adguard-unbound/adguard-unbound-hook.sh
#
# At hook time the AdGuard setup wizard has not been run, so AdGuardHome.yaml does not exist yet. The hook installs
# Unbound and the watchdog and prints the values to enter in the AdGuard UI. After the wizard, run:
#   /opt/adguard-unbound/adguard-unbound.sh --adguard <CTID> [same options] adguard --apply-adguard
#
# Safe to set globally: it does nothing for other apps. Idempotent, so re-running is fine.
set -euo pipefail

# --- CONFIG (edit me) ------------------------------------------------------------------------------------------
MODE="local"               # local    = Unbound inside the AdGuard LXC (127.0.0.1:5335)
                           # separate = Unbound in its own, already existing LXC (see UNBOUND_CTID)
UNBOUND_CTID=""            # required when MODE=separate
FALLBACK="9.9.9.9,1.1.1.1" # comma-separated fallback DNS servers
ALLOW=""                   # separate mode: extra CIDRs allowed to query Unbound, e.g. "192.168.1.0/24"
WATCHDOG="yes"             # yes | no
# ---------------------------------------------------------------------------------------------------------------

if [[ -n "${NSAPP:-}" && "${NSAPP}" != adguard* ]]; then
  echo "adguard-unbound-hook: skipping, not an AdGuard container (NSAPP=${NSAPP})"
  exit 0
fi

: "${CTID:?CTID is not set - this script is meant to run as a var_post_install hook}"

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

args=(--mode "$MODE" --adguard "$CTID" --fallback "$FALLBACK")
if [[ "$MODE" == separate ]]; then
  : "${UNBOUND_CTID:?MODE=separate needs UNBOUND_CTID set in the CONFIG block}"
  args+=(--unbound "$UNBOUND_CTID")
  [[ -z "$ALLOW" ]] || args+=(--allow "$ALLOW")
fi
[[ "$WATCHDOG" == yes ]] || args+=(--no-watchdog)

echo "adguard-unbound-hook: CT ${CTID} (${APP:-AdGuard}) mode=${MODE}"
exec bash "$HERE/adguard-unbound.sh" "${args[@]}"
