# adguard-unbound

Composable scripts that put Unbound (validating recursive resolver) behind AdGuard Home
on Proxmox VE, with fallback DNS for two failure modes:

| Failure | Handled by |
|---|---|
| Unbound container is down | AdGuard Home fallback DNS (`fallback_dns`) |
| Unbound is up but cannot recurse | `unbound-watchdog` switches Unbound to forwarding (DoT when the fallback servers are known), and back when recursion recovers |

## Layout

```
adguard-unbound.sh              facade, runs on the Proxmox host
adguard-unbound-hook.sh         var_post_install wrapper around the facade
lib/common.sh                   pct helpers (sourced by the facade)
modules/unbound-install.sh      runs inside a CT: install + configure Unbound
modules/watchdog-install.sh     runs inside the Unbound CT: install the watchdog
modules/adguard-upstream.sh     runs inside the AdGuard CT: set upstream + fallback
payload/unbound-watchdog.sh     the watchdog itself (pushed into the Unbound CT)
```

Each module works on its own inside a container; the facade only pushes them in with
`pct push` and runs them with `pct exec`. The whole directory has to be present on the
Proxmox host (git clone or tarball): the scripts reference each other by relative path,
so a single-file `bash -c "$(curl ...)"` one-liner will not work.

## Usage

```bash
# Unbound inside the AdGuard LXC (127.0.0.1:5335)
./adguard-unbound.sh --adguard 105

# Unbound in its own LXC, answering on the LAN (port 53)
./adguard-unbound.sh --mode separate --adguard 105 --unbound 106

# After the AdGuard setup wizard: write upstream + fallback into AdGuardHome.yaml
./adguard-unbound.sh --mode separate --adguard 105 --unbound 106 adguard --apply-adguard

# Preview without changing anything
./adguard-unbound.sh --adguard 105 --dry-run
```

`--adguard` can be omitted when exactly one container carries the `adblock` tag
(the default tag of the community AdGuard script). Steps are `unbound`, `watchdog` and
`adguard`; with none given, all three run.

## As a post-install hook (`var_post_install`)

`build.func` can run a script on the host right after a container is created (see
`tools/pve/post-install-hook-examples.sh`). `adguard-unbound-hook.sh` is a ready-made hook
for the Adguard script:

1. Edit the CONFIG block at the top of `adguard-unbound-hook.sh` (mode, fallback servers, ...).
2. Point the hook at it, for example in `/root/.community-scripts/default.vars`:
   `var_post_install=/opt/adguard-unbound/adguard-unbound-hook.sh`
3. Create the Adguard LXC as usual. Hook output is written to
   `/var/log/community-scripts/post-install-<CTID>.log`.

The hook skips every app other than AdGuard, so it is safe to set globally. In `separate`
mode the Unbound LXC must already exist (set `UNBOUND_CTID`).

## Notes

- `AdGuardHome.yaml` does not exist until the first-run wizard is done, which is always the
  case at hook time. Until then the `adguard` step only prints the values to enter in the
  UI; run it again with `--apply-adguard` afterwards.
- `--apply-adguard` stops AdGuard Home, backs up the YAML, rewrites
  `dns.upstream_dns` and `dns.fallback_dns`, restarts, and restores the backup if the
  service does not come back. If your version has no `fallback_dns` key, only the
  upstream is changed.
- Separate mode: give the Unbound LXC a static IP / DHCP reservation, and start it
  before AdGuard (`pct set <id> --startup order=...`, printed at the end of a run).
- The watchdog needs three consecutive failed checks (about 90 s on Debian, 3 min on
  Alpine) before switching, and each switch reloads Unbound (clearing its cache).
