# demon-mac

MAC address randomizer for sysadmin-owned hosts. Randomizes MAC at boot,
on each NetworkManager connection, and (optionally) on a periodic schedule,
with full kill-switch via config and systemd. Supports per-SSID pinning for
MAC-authenticated networks.

## Before you install this — try the built-in randomization first

Linux distros that ship NetworkManager and/or systemd-networkd already
have **upstream-supported, distro-tested** MAC randomization built in.
For most use cases (a laptop that wants a different MAC on every Wi-Fi
association) the built-in mechanism is enough — and it's the right
default because it's maintained by the people who maintain your network
stack.

**Try this first.** If it solves your problem, you do not need
demon-mac at all.

### NetworkManager (most desktops and laptops)

NM ≥ 1.4 exposes the per-connection settings you need. There are two
controls; both live on the connection profile:

| Setting | Values | Effect |
|---|---|---|
| `802-11-wireless.cloned-mac-address` | `preserve`, `permanent`, `random`, `stable` | `random` = new MAC on every connection; `stable` = new MAC per-SSID, stable across reconnects |
| `802-11-wireless.mac-address-randomization` | `0` (default), `1` (never), `2` (always) | Master switch — must be `2` to enable |

To enable per-SSID stable randomization on a profile:

```sh
nmcli connection modify "<profile-name>" \
    802-11-wireless.cloned-mac-address stable \
    802-11-wireless.mac-address-randomization 2
nmcli connection up "<profile-name>"
```

Replace `<profile-name>` with the SSID (or any name; `nmcli connection`
shows it). Inspect the current value with:

```sh
nmcli -t -f connection,802-11-wireless.cloned-mac-address,802-11-wireless.mac-address-randomization \
    connection show "<profile-name>"
```

Docs:
- [NetworkManager 802-11-wireless settings reference](https://networkmanager.dev/docs/api/latest/settings-802-11-wireless.html) — `cloned-mac-address`, `mac-address-randomization`, `assigned-mac-address`.

### systemd-networkd (servers, minimal installs, NixOS)

systemd-networkd's `.link` files accept `MACAddressPolicy=`:

| Value | Effect |
|---|---|
| `persistent` | Default. Stable per-machine MAC derived from `/etc/machine-id` and the device's ID_NET_NAME_* — same on every boot, different from hardware MAC. |
| `random` | New random MAC on every interface appearance (typically each boot). Locally-administered + unicast bits are set. |
| `none` | Keep the kernel-assigned MAC. Use this if you want to set a specific MAC with `MACAddress=`. |

```ini
# /etc/systemd/network/10-mac-randomize.link
[Match]
OriginalName=*

[Link]
MACAddressPolicy=random
```

Docs: [systemd.link(5) — MACAddressPolicy](https://www.freedesktop.org/software/systemd/man/systemd.link.html).

### Why you might still want demon-mac

The built-in randomization covers the common case. Reach for demon-mac
when you need:

- **MAC-Authenticated Wi-Fi with per-SSID pinning**: a stable MAC per
  network, but you only get that out of NM's `stable` mode if you
  trust NM to keep its state. demon-mac writes its own state file
  (`/var/lib/demon-mac/state`, mode 0600) and survives reinstalls
  cleanly.
- **A constrained prefix**: keep generated MACs inside a chosen
  16-bit OUI range (`MAC_PREFIX=02:11`) for routers/APs that filter
  by OUI rather than full-MAC ACL.
- **Daily/weekly rotation on stable wired links**: NM doesn't
  rotate on wired connections by default; the systemd timer in
  demon-mac rotates them on schedule even without network churn.
- **Self-heal after NM revert**: if NM's `cloned-mac-address`
  setting was changed by hand or by another tool and NM reverts
  your MAC, demon-mac's `NM_CLONED_MAC_POLICY=preserve` reasserts
  preserve on the profile. The built-in mechanism has no such
  watchdog.

If none of that matters to you, uninstall is `sudo make uninstall`
and you're back to the disto's default behavior — no daemon, no
service, no state file.

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
| `STATE_FILE` | `/var/lib/demon-mac/state` | Per-(iface, ssid) rotation record (operator-managed, mode 0600) |
| `NM_CLONED_MAC_POLICY` | `preserve` | `preserve` (default) / `none` — see [NetworkManager interaction](#networkmanager-interaction) |
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
  Forwards `$CONNECTION_UUID` as env so the daemon can enforce
  `cloned-mac-address=preserve` on the profile.

## NetworkManager interaction

NetworkManager ≥ 1.4 exposes `802-11-wireless.cloned-mac-address` /
`ethernet.cloned-mac-address` on each connection profile. Values are
`random`, `stable`, `preserve`, or `permanent`. The daemon sets the
MAC via `ip link set address` on `pre-up`, but if the active profile
is set to anything other than `preserve`, NM will rewrite the MAC on
the next activation — making the daemon's work invisible.

Default behavior (`NM_CLONED_MAC_POLICY=preserve`): after every
successful rotation, the daemon calls
`nmcli connection modify <UUID> cloned-mac-address preserve` on the
active profile. Idempotent — no-op if already `preserve`. Requires
`nmcli` in `PATH` and `CONNECTION_UUID` exported by the dispatcher
(99-demon-mac does this). Boot/rotate triggers skip this — there's
no profile context.

Set `NM_CLONED_MAC_POLICY=none` if you manage the profile by hand or
don't use NM.

To inspect the current profile value:

```sh
nmcli -t -g 802-11-wireless.cloned-mac-address,cloned-mac-address \
    con show uuid "$CONNECTION_UUID"
```

The daemon's MAC change is verified by reading the link back
immediately after `ip link set address`. Some drivers (notably
`brcmfmac` and several Realtek USB sticks) silently ignore address
changes; in that case the daemon logs
`post-set MAC mismatch: ...` and returns failure instead of
recording a misleading success.

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
- **Wi-Fi `down/up` drops the link for ~100–500 ms.** Every rotation
  on a Wi-Fi iface drops all active TCP sessions, breaks VoIP/VPN
  keepalive, and interrupts any in-flight downloads. This is the
  cost of changing the MAC while the interface is up; only some
  drivers accept an address change without a link flap. If you need
  unbroken Wi-Fi sessions, use a wired `TARGETS` entry and disable
  rotation on the wireless iface (e.g. `TARGETS=eth0`).
- **Wi-Fi drivers**: `down/up` works for most (`iwlwifi`, `ath9k`,
  `mt76`, `rtw88`). `brcmfmac` (Broadcom) and several Realtek USB
  sticks either reject the MAC change silently or refuse while
  associated; the daemon verifies the post-set MAC and logs
  `post-set MAC mismatch` on rejection. Check `dmesg` if rotation
  appears to no-op.
- **IPv6 link-local** changes with MAC; `STABILIZE_IPV6=true` sets
  `addr_gen_mode=1` (random but not MAC-derived).
- **NetworkManager MAC race**: see [NetworkManager interaction](#networkmanager-interaction).
  Without `NM_CLONED_MAC_POLICY=preserve` (or a hand-set profile), NM
  may overwrite the daemon's MAC on the next reactivation.
- **Per-SSID pinning weakens in-network privacy** — same MAC across
  visits; visit frequency visible to network-side logging. Cross-SSID
  privacy preserved.
- **Concurrent triggers**: a `flock` on
  `<state_dir>/demon-mac.lock` serializes boot + rotate.timer (and
  any race between dispatcher and timer). If you see
  `another instance holds ... exiting`, that's expected — the other
  invocation is in progress.
- **State file is mode 0600** by design (MACs are persistent
  identifiers; the dir is 0700). Operators reading `/var/lib/demon-mac/`
  need root.

## Tests

```sh
make test         # all 25 smoke tests
make lint         # bash -n on scripts
```

## See also

- `ARCHITECTURE.md` — design and component map
- `DAEMON.md` — daemon contract and lifecycle
- `RUNBOOK.md` — troubleshooting and operations