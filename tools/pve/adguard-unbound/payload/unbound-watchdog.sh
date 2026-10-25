#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/AdguardTeam/AdGuardHome | https://github.com/NLnetLabs/unbound
# Installed to /usr/local/bin/unbound-watchdog.sh inside the Unbound container.
# If Unbound can no longer recurse, switch it to forwarding to the fallback
# servers; switch back when direct recursion works again.
#
# Settings come from /etc/unbound/watchdog.env (written by watchdog-install.sh):
#   FALLBACK=9.9.9.9,1.1.1.1  CHECK_ADDR=127.0.0.1  CHECK_PORT=53  THRESHOLD=3
# Test hooks: WD_ENV, WD_STATE, WD_FALLBACK_FILE, WD_RELOAD_CMD
set -u

ENV_FILE="${WD_ENV:-/etc/unbound/watchdog.env}"
# shellcheck disable=SC1090
[[ -r "$ENV_FILE" ]] && . "$ENV_FILE"

FALLBACK="${FALLBACK:-9.9.9.9,1.1.1.1}"
CHECK_ADDR="${CHECK_ADDR:-127.0.0.1}"
CHECK_PORT="${CHECK_PORT:-53}"
THRESHOLD="${THRESHOLD:-3}"
STATE="${WD_STATE:-/run/unbound-watchdog.fails}"
ROOT_A=198.41.0.4 # a.root-servers.net, used to test direct outbound port 53

if [[ -n "${WD_FALLBACK_FILE:-}" ]]; then
  FALLBACK_FILE="$WD_FALLBACK_FILE"
elif command -v apk >/dev/null 2>&1; then
  FALLBACK_FILE=/etc/unbound/conf.d/zz-fallback.conf
else
  FALLBACK_FILE=/etc/unbound/unbound.conf.d/zz-fallback.conf
fi

wlog() { logger -t unbound-watchdog "$*" 2>/dev/null || echo "unbound-watchdog: $*"; }

reload_unbound() {
  if [[ -n "${WD_RELOAD_CMD:-}" ]]; then
    eval "$WD_RELOAD_CMD"
  elif [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl reload unbound
  else
    rc-service unbound restart
  fi
}

tls_name() {
  case "$1" in
    9.9.9.9 | 149.112.112.112) echo dns.quad9.net ;;
    1.1.1.1 | 1.0.0.1) echo cloudflare-dns.com ;;
    8.8.8.8 | 8.8.4.4) echo dns.google ;;
  esac
}

write_fallback() {
  local addr all_known=1 tmp="${FALLBACK_FILE}.tmp"
  for addr in ${FALLBACK//,/ }; do
    [[ -n "$(tls_name "$addr")" ]] || all_known=0
  done
  {
    if ((all_known)); then
      echo "server:"
      echo "    tls-cert-bundle: /etc/ssl/certs/ca-certificates.crt"
    fi
    echo "forward-zone:"
    echo '    name: "."'
    ((all_known)) && echo "    forward-tls-upstream: yes"
    for addr in ${FALLBACK//,/ }; do
      if ((all_known)); then
        echo "    forward-addr: ${addr}@853#$(tls_name "$addr")"
      else
        echo "    forward-addr: ${addr}"
      fi
    done
  } >"$tmp"
  mv "$tmp" "$FALLBACK_FILE"
}

if [[ -f "$FALLBACK_FILE" ]]; then
  # Fallback mode: only decide whether direct recursion works again.
  if dig @"$ROOT_A" . NS +time=2 +tries=1 >/dev/null 2>&1; then
    rm -f "$FALLBACK_FILE" "$STATE"
    reload_unbound
    wlog "direct recursion works again, fallback removed"
  fi
  exit 0
fi

# Normal mode: a random label under example.com must be answered by the
# authoritative servers (NXDOMAIN). SERVFAIL or a timeout means recursion broke.
status=$(dig @"$CHECK_ADDR" -p "$CHECK_PORT" "hc-${RANDOM}${RANDOM}.example.com" +time=3 +tries=1 2>/dev/null |
  grep -o 'status: [A-Z]*' || true)

if [[ "$status" == "status: NXDOMAIN" || "$status" == "status: NOERROR" ]]; then
  echo 0 >"$STATE"
  exit 0
fi

fails=$(($(cat "$STATE" 2>/dev/null || echo 0) + 1))
echo "$fails" >"$STATE"
if ((fails >= THRESHOLD)); then
  write_fallback
  if command -v unbound-checkconf >/dev/null 2>&1 && ! unbound-checkconf >/dev/null 2>&1; then
    rm -f "$FALLBACK_FILE"
    wlog "fallback config failed unbound-checkconf, not applied"
    exit 1
  fi
  reload_unbound
  wlog "recursion failing (${fails} checks), fallback enabled: ${FALLBACK}"
fi
