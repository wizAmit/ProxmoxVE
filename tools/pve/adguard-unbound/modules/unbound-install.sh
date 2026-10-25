#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/AdguardTeam/AdGuardHome | https://github.com/NLnetLabs/unbound
# Runs INSIDE a container (pushed there by adguard-unbound.sh).
# Installs Unbound as a validating recursive resolver. Idempotent.
#
# Env:
#   UNBOUND_LISTEN  interface to bind        (default 127.0.0.1)
#   UNBOUND_PORT    port to listen on        (default 5335)
#   UNBOUND_ALLOW   comma-separated CIDRs allowed to query (default 127.0.0.0/8)
set -euo pipefail

LISTEN="${UNBOUND_LISTEN:-127.0.0.1}"
PORT="${UNBOUND_PORT:-5335}"
ALLOW="${UNBOUND_ALLOW:-127.0.0.0/8}"

build_conf() {
  echo "server:"
  echo "    interface: ${LISTEN}"
  echo "    port: ${PORT}"
  echo "    do-ip4: yes"
  echo "    do-ip6: no"
  echo "    do-udp: yes"
  echo "    do-tcp: yes"
  local c
  for c in ${ALLOW//,/ }; do
    echo "    access-control: ${c} allow"
  done
  cat <<'EOF'
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-referral-path: yes
    qname-minimisation: yes
    use-caps-for-id: no
    edns-buffer-size: 1232
    prefetch: yes
    prefetch-key: yes
    cache-min-ttl: 300
    cache-max-ttl: 86400
    serve-expired: yes
    num-threads: 1
    msg-cache-size: 16m
    rrset-cache-size: 32m
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    private-address: fd00::/8
    private-address: fe80::/10
EOF
}

if command -v apk >/dev/null 2>&1; then
  # Alpine
  apk add --no-cache unbound ca-certificates
  mkdir -p /var/lib/unbound /etc/unbound/conf.d
  {
    build_conf
    echo '    username: "unbound"'
    echo '    chroot: ""'
    echo '    auto-trust-anchor-file: "/var/lib/unbound/root.key"'
    echo
    echo 'include-toplevel: "/etc/unbound/conf.d/*.conf"'
  } >/etc/unbound/unbound.conf
  unbound-anchor -a /var/lib/unbound/root.key >/dev/null 2>&1 || true
  chown -R unbound:unbound /var/lib/unbound 2>/dev/null || true
  unbound-checkconf
  rc-update add unbound default >/dev/null
  rc-service unbound restart
else
  # Debian/Ubuntu. Write the config BEFORE installing: the package starts
  # Unbound on install, and its default listener (127.0.0.1:53) would collide
  # with AdGuard Home when both share a container.
  mkdir -p /etc/unbound/unbound.conf.d
  build_conf >/etc/unbound/unbound.conf.d/adguard.conf
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unbound ca-certificates
  systemctl disable --now unbound-resolvconf.service >/dev/null 2>&1 || true
  unbound-checkconf
  systemctl enable unbound >/dev/null 2>&1
  systemctl restart unbound
fi

echo "unbound-install: listening on ${LISTEN}:${PORT}, allowed: ${ALLOW}"
