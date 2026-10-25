#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/AdguardTeam/AdGuardHome | https://github.com/NLnetLabs/unbound
# Runs INSIDE the AdGuard Home container.
# Points AdGuard Home at Unbound and sets the fallback servers.
#
# AdGuardHome.yaml only exists after the first-run wizard. Until then (or when
# APPLY=0) this prints what to set in the UI instead of editing anything.
#
# Env:
#   UPSTREAM  comma-separated upstream(s), e.g. 127.0.0.1:5335 or 192.168.1.53
#   FALLBACK  comma-separated fallback servers (may be empty)
#   APPLY     1 = edit AdGuardHome.yaml, 0 = only print instructions
# Test hooks: ADGUARD_YAML, NO_SERVICE
set -euo pipefail

UPSTREAM="${UPSTREAM:?UPSTREAM is required}"
FALLBACK="${FALLBACK:-}"
APPLY="${APPLY:-0}"
YAML="${ADGUARD_YAML:-/opt/AdGuardHome/AdGuardHome.yaml}"

instructions() {
  echo "Set these in AdGuard Home (Settings > DNS settings):"
  echo "  Upstream DNS servers : ${UPSTREAM//,/, }"
  if [[ -n "$FALLBACK" ]]; then
    echo "  Fallback DNS servers : ${FALLBACK//,/, }   (if your version has this box)"
  fi
  echo "  Bootstrap DNS        : leave default (plain-IP upstreams need none)"
}

if [[ ! -f "$YAML" ]]; then
  echo "adguard-upstream: $YAML not found - finish the AdGuard setup wizard first."
  instructions
  exit 0
fi

if [[ "$APPLY" != 1 ]]; then
  instructions
  exit 0
fi

# Replace the list under dns:<key>: with the given comma-separated items.
# Exit 3 if the key does not exist in the file.
rewrite_list() {
  awk -v key="$1" -v items="$2" '
    BEGIN { n = split(items, a, ",") }
    /^[^ #\t]/ { in_dns = ($0 ~ /^dns:/); skipping = 0 }
    {
      if (skipping) {
        if ($0 ~ /^    - / || $0 ~ /^      /) next
        skipping = 0
      }
      if (in_dns && $0 ~ ("^  " key ":")) {
        found = 1
        if (items == "") print "  " key ": []"
        else {
          print "  " key ":"
          for (i = 1; i <= n; i++) print "    - " a[i]
        }
        skipping = 1
        next
      }
      print
    }
    END { if (!found) exit 3 }
  ' "$3"
}

service_ctl() {
  [[ "${NO_SERVICE:-0}" == 1 ]] && return 0
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl "$1" AdGuardHome
  else
    rc-service adguardhome "$1"
  fi
}

service_active() {
  [[ "${NO_SERVICE:-0}" == 1 ]] && return 0
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl is-active --quiet AdGuardHome
  else
    rc-service adguardhome status >/dev/null 2>&1
  fi
}

backup="${YAML}.bak.$(date +%Y%m%d%H%M%S)"
tmp1="$(mktemp)"
tmp2="$(mktemp)"
trap 'rm -f "$tmp1" "$tmp2"' EXIT

rewrite_list upstream_dns "$UPSTREAM" "$YAML" >"$tmp1" ||
  { echo "adguard-upstream: could not find dns.upstream_dns in $YAML; nothing changed" >&2; exit 1; }

if rewrite_list fallback_dns "$FALLBACK" "$tmp1" >"$tmp2"; then
  :
else
  rc=$?
  if [[ $rc -eq 3 ]]; then
    echo "adguard-upstream: this AdGuard Home version has no fallback_dns key; upstream updated only." >&2
    cp "$tmp1" "$tmp2"
  else
    echo "adguard-upstream: failed to edit fallback_dns; nothing changed" >&2
    exit 1
  fi
fi

service_ctl stop
cp -a "$YAML" "$backup"
cat "$tmp2" >"$YAML"
service_ctl start
sleep 3

if service_active; then
  echo "adguard-upstream: updated $YAML (backup: $backup)"
  instructions
else
  echo "adguard-upstream: AdGuard Home failed to start; restoring backup" >&2
  cp -a "$backup" "$YAML"
  service_ctl start || true
  exit 1
fi
