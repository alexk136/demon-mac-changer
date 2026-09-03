# demon-mac

MAC address randomizer for sysadmin-owned hosts. Randomizes MAC at boot,
on each NetworkManager connection, and (optionally) on a periodic schedule,
with full kill-switch via config and systemd. Supports per-SSID pinning for
MAC-authenticated networks.

## Quick start

```sh
# install (requires root)
sudo make install

# disable (three layers)
sudo sed -i 's/^ENABLED=true/ENABLED=false/' /etc/demon-mac.conf   # soft
sudo systemctl disable --now demon-mac-boot                       # hard
sudo make uninstall                                                # full

# status
systemctl status demon-mac-boot
systemctl list-timers demon-mac-rotate
journalctl -t demon-mac -n 50
ip link show dev eth0 | grep ether
cat /var/lib/demon-mac/state
```

## Configuration (`/etc/demon-mac.conf`)

| Key | Default | Meaning |
|---|---|---|
| `ENABLED` | `true` | Master kill-switch |
| `ROTATION_POLICY` | `connection` | One of `connection`, `boot`, `once`, `daily`, `weekly`, `monthly` |
| `PIN_MODE` | `none` | One of `none`, `ssid`, `iface` — see [MAC authentication](#mac-authentication-on-filtered-routers) |
| `MAC_PREFIX` | empty | `XX:XX` hex prefix constraining generated MACs; empty = full random |
| `TARGETS` | empty | Empty = all physical; else comma-separated iface list |
| `STATE_FILE` | `/var/lib/demon-mac/state` | Per-(iface, ssid) rotation record (operator-managed) |
| `STABILIZE_IPV6` | `true` | sysctl `addr_gen_mode=1` after MAC change |
| `LOG_FILE` | empty | Optional file log (journald always) |
| `LOG_LEVEL` | `info` | debug / info / warn / error |

## Rotation policies

| Policy | Behavior | Trigger used |
|---|---|---|
| `connection` | Rotate on every NM `pre-up` | `connection` |
| `boot` | Rotate on every boot | `boot` |
| `once` | Rotate once per (iface, ssid), persist forever | first trigger fires |
| `daily` | Rotate if last rotation > 24h ago | `connection` + `rotate` timer |
| `weekly` | Rotate if last rotation > 7d ago | `connection` + `rotate` timer |
| `monthly` | Rotate if last rotation > 30d ago | `connection` + `rotate` timer |

For periodic policies, the `demon-mac-rotate.timer` ensures rotation
happens even without network churn (e.g., stable ethernet at home for a
week). Each policy is applied per-(iface, ssid) — see [MAC authentication](#mac-authentication-on-filtered-routers).

## MAC authentication on filtered routers

If your router uses MAC-based ACL (typical home Wi-Fi), default
`PIN_MODE=none` breaks the connection on every reconnect because the
MAC rotates. Two cooperating features solve this:

### `PIN_MODE=ssid` — reuse MAC per Wi-Fi network

```sh
PIN_MODE=ssid
```

The NetworkManager dispatcher passes `$CONNECTION_ID` (typically the
SSID for Wi-Fi) to the script. The state file then keys on
`(iface, ssid)`:

- First connect to `home-wifi` → generate MAC A, save
- Reconnect to `home-wifi` → reuse MAC A
- First connect to `work-wifi` → generate MAC B (different), save
- Reconnect to `work-wifi` → reuse MAC B

**Trade-off**: within a network, MAC is stable (so the router keeps
recognising you). Between networks, MAC is different (privacy
preserved across SSIDs).

For boot and rotate modes, there's no SSID context, so they fall back
to per-iface pin (`iface||mac|ts` in state file).

### `MAC_PREFIX=02:11` — constrain to a chosen range

```sh
MAC_PREFIX=02:11
```

Generated MAC = `02:11:XX:XX:XX:XX` (16-bit prefix fixed, 32 bits random).
First byte MUST be locally-administered + unicast
(`byte & 0x03 == 0x02`); invalid prefixes fall back to full random with
a WARN message.

Useful when:
- You want all generated MACs to come from a recognisable range
- Your router allows range-based ACL (rare on home gear, common on
  enterprise APs)
- Combined with `PIN_MODE=ssid`: per-network pinned MAC within a
  consistent OUI

### Combined: pinned per SSID + constrained prefix

```sh
ROTATION_POLICY=once      # rotate once per SSID, persist forever
PIN_MODE=ssid            # reuse per network
MAC_PREFIX=02:11         # constrain to chosen range
```

Result: each SSID gets its own stable MAC within `02:11:...`. Add
the pinned MAC to your router's ACL once per SSID, after first
connect.

### Setup steps for MAC-auth router

1. `PIN_MODE=ssid` + desired `ROTATION_POLICY` + (optionally) `MAC_PREFIX`
2. `sudo make install`
3. Connect to each SSID once. Find the pinned MAC:
   ```sh
   cat /var/lib/demon-mac/state
   ip link show dev wlan0 | grep ether
   ```
4. Add the MAC to your router's MAC ACL (each SSID independently)
5. From now on, reconnects reuse the MAC and pass ACL

## Triggers

- **`demon-mac-boot.service`** — systemd oneshot at multi-user.target,
  runs `demon-mac boot` (iterates all physical ifaces).
- **`demon-mac-rotate.timer`** — daily systemd timer with 15-min
  randomized delay; activates `demon-mac-rotate.service` which runs
  `demon-mac rotate` (iterates all physical ifaces, checks state).
- **`/etc/NetworkManager/dispatcher.d/99-demon-mac`** — NM dispatcher
  hook; reacts to `pre-up` event, runs
  `demon-mac connection <iface> <SSID>` (NM `$CONNECTION_ID`).

## Components

- `demon-mac.sh` — main script; modes `boot`, `connection <iface> <ssid>`,
  `rotate`
- `demon-mac.conf.example` — config template
- `systemd/demon-mac-boot.service` — boot-time oneshot
- `systemd/demon-mac-rotate.service` — periodic oneshot
- `systemd/demon-mac-rotate.timer` — daily calendar trigger
- `networkmanager/99-demon-mac` — dispatcher (`pre-up`, passes SSID)
- `install.sh` / `uninstall.sh` — system install/uninstall
- `Makefile` — install / uninstall / test / lint targets
- `tests/smoke.sh` — 25 tests: policy matrix + state validation +
  per-SSID pinning + prefix validation + legacy state compat

## Caveats

- **Breaks**: MAC-bound DHCP without ACL pre-add, captive portals with
  MAC ACL (unless using `PIN_MODE=ssid`), hardware-bound licensing.
- **IPv6 link-local** changes with MAC; `STABILIZE_IPV6=true` sets
  `addr_gen_mode=1` (random but not MAC-derived).
- **Wi-Fi**: `down/up` works for most drivers (iwlwifi, ath9k, mt76,
  rtw88). Some Broadcom chips reject MAC change; check `dmesg`.
- **Per-SSID pinning weakens in-network privacy** — same MAC across
  visits; visit frequency visible to network-side logging. Cross-SSID
  privacy preserved.

## Tests

```sh
make test         # all 25 smoke tests
make lint         # bash -n on scripts
```

## See also

- `ARCHITECTURE.md` — design and component map
- `DAEMON.md` — daemon contract and lifecycle
- `RUNBOOK.md` — troubleshooting and operations