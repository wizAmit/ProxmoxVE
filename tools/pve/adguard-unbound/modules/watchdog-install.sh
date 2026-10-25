#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/AdguardTeam/AdGuardHome | https://github.com/NLnetLabs/unbound
# Runs INSIDE the Unbound container. Installs the recursion watchdog.
# The facade pushes payload/unbound-watchdog.sh to /root/.adguard-unbound/ first.
#
# Env:
#   FALLBACK    comma-separated fallback DNS servers (default 9.9.9.9,1.1.1.1)
#   CHECK_ADDR  address Unbound answers on (default 127.0.0.1)
#   CHECK_PORT  port Unbound answers on    (default 53)
#   THRESHOLD   consecutive failures before switching (default 3)
set -euo pipefail

SRC=/root/.adguard-unbound/unbound-watchdog.sh
[[ -f "$SRC" ]] || { echo "watchdog payload missing at $SRC" >&2; exit 1; }

install -m 0755 "$SRC" /usr/local/bin/unbound-watchdog.sh

cat >/etc/unbound/watchdog.env <<EOF
FALLBACK=${FALLBACK:-9.9.9.9,1.1.1.1}
CHECK_ADDR=${CHECK_ADDR:-127.0.0.1}
CHECK_PORT=${CHECK_PORT:-53}
THRESHOLD=${THRESHOLD:-3}
EOF

if command -v apk >/dev/null 2>&1; then
  # Alpine: bind-tools for dig, busybox cron (1 minute granularity)
  apk add --no-cache bind-tools ca-certificates
  ( (crontab -l 2>/dev/null || true) | grep -v unbound-watchdog || true
    echo '* * * * * /usr/local/bin/unbound-watchdog.sh' ) | crontab -
  rc-update add crond default >/dev/null 2>&1 || true
  rc-service crond start >/dev/null 2>&1 || true
  echo "watchdog-install: cron entry added (checks every minute)"
else
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bind9-dnsutils ca-certificates ||
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dnsutils ca-certificates

  cat >/etc/systemd/system/unbound-watchdog.service <<'EOF'
[Unit]
Description=Unbound recursion watchdog

[Service]
Type=oneshot
ExecStart=/usr/local/bin/unbound-watchdog.sh
EOF

  cat >/etc/systemd/system/unbound-watchdog.timer <<'EOF'
[Unit]
Description=Run the Unbound recursion watchdog every 30 seconds

[Timer]
OnBootSec=60
OnUnitActiveSec=30

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now unbound-watchdog.timer
  echo "watchdog-install: systemd timer enabled (checks every 30s)"
fi
