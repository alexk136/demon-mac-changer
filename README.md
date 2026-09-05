# demon-mac

MAC address supervisor and randomizer for sysadmin-owned hosts.
The daemon sits on top of NetworkManager: in its default mode it
configures NM's per-profile MAC randomization settings; in advanced
modes it generates random MACs and applies them itself.

## Which mode do I want?

| You need… | Use |
|---|---|
| Per-SSID stable MAC on Wi-Fi, no extra files, no driver quirks to worry about | [NM built-in](#built-in-networkmanager) (probably you don't need demon-mac at all) |
| Per-SSID stable MAC on Wi-Fi *and* per-connection stable MAC on Ethernet, with a daemon that ensures the NM setting stays applied across profile resets, new connections, and distro NM upgrades | [`MANAGEMENT_MODE=supervisor`](#supervisor-mode-default) — the default |
| Per-SSID pinning that survives `nmcli connection delete`, daily rotation on stable wired links, OUI-constrained MAC prefix, self-heal after NM revert | [`MANAGEMENT_MODE=daemon`](#daemon-mode) — full kernel-direct MAC management |
| All of the above combined | [`MANAGEMENT_MODE=hybrid`](#hybrid-mode) |

## Built-in NetworkManager

Linux distros that ship NetworkManager and/or systemd-networkd already
have **upstream-supported, distro-tested** MAC randomization built in.
For most use cases (a laptop that wants a different MAC on every Wi-Fi
association) the built-in mechanism is enough — and it's the right
default because it's maintained by the people who maintain your network
stack.

**Try this first.** If it solves your problem, you do not need
demon-mac at all.

### NetworkManager (most desktops and laptops)

NM ≥ 1.4 exposes the per-connection settings you need:

| Setting | Values | Effect |
|---|---|---|
| `802-11-wireless.cloned-mac-address` | `preserve`, `permanent`, `random`, `stable` | `random` = new MAC on every connection; `stable` = new MAC per-SSID, stable across reconnects |
| `802-11-wireless.mac-address-randomization` | `0` (default), `1` (never), `2` (always) | Master switch — must be `2` to enable |

```sh
nmcli connection modify "<profile-name>" \
    802-11-wireless.cloned-mac-address stable \
    802-11-wireless.mac-address-randomization 2
nmcli connection up "<profile-name>"
```

Docs: [NetworkManager 802-11-wireless settings reference](https://networkmanager.dev/docs/api/latest/settings-802-11-wireless.html).

### systemd-networkd (servers, minimal installs, NixOS)

```ini
# /etc/systemd/network/10-mac-randomize.link
[Match]
OriginalName=*

[Link]
MACAddressPolicy=random
```

Docs: [systemd.link(5) — MACAddressPolicy](https://www.freedesktop.org/software/systemd/man/systemd.link.html).

## demon-mac supervisor mode (default)

Default `MANAGEMENT_MODE=supervisor`. The daemon does only what NM
can't do for itself: **ensure the right setting is on every active
NM-managed connection** — Wi-Fi *and* Ethernet. No kernel MAC
writes, no state file, no flock.

On every trigger (`boot`, `connection` pre-up, daily `rotate.timer`)
the daemon:

1. Looks up the active NM connection for the iface (via `$CONNECTION_UUID`
   from the dispatcher, or via `nmcli device show` for boot/rotate).
2. Determines the connection type — only `802-11-wireless` and
   `802-3-ethernet` are eligible. VPN / GSM / bridge / etc. are
   skipped (logged).
3. Reads the current `connection.cloned-mac-address` (the type-agnostic
   setting that works for both Wi-Fi and Ethernet) and, for Wi-Fi,
   `802-11-wireless.mac-address-randomization` (the wireless master
   switch).
4. If either differs from the configured target, calls
   `nmcli connection modify ...` to set it.

`NM_CLONED_MAC=stable` (default) sets `cloned-mac-address=stable` on
every active profile. Per-SSID pin on Wi-Fi; stable per-NM-profile on
Ethernet (Ethernet has no SSID concept — `cloned-mac-address=stable`
means "stable across reconnects of this connection profile").

If `NM_CLONED_MAC=random`, demon-mac sets `cloned-mac-address=random`
on every profile (fresh MAC per connection).

The supervisor never touches `ip link`. It only edits NM profiles.
This means:

- No driver-compat issues (no `brcmfmac` surprises).
- No link flap on rotation (NM handles it cleanly).
- No state file to manage.
- Survives profile deletes — when NM creates a new profile, the next
  `pre-up` event supervises it.

## Daemon mode

`MANAGEMENT_MODE=daemon`. The daemon does what NM can't: **generates
random MACs and applies them via `ip link set address`**. This is the
original demon-mac behavior.

Use this mode when supervisor isn't enough:

- **`MAC_PREFIX=02:11`** — constrain generated MACs to a chosen 16-bit
  OUI range. NM's analogue is `generate-mac-address-mask` with bit-mask
  syntax; demon-mac uses a readable prefix.
- **Daily/weekly/monthly rotation on stable wired links** — NM doesn't
  randomize wired. The `demon-mac-rotate.timer` fires daily and the
  daemon rotates if the state age exceeds the policy threshold.
- **Self-heal after NM revert** — if some other tool changes the NM
  profile back, the daemon's `reconcile_iface` (boot/rotate modes)
  re-applies the state-recorded MAC and re-pins `preserve`.
- **Operator-readable state** — `/var/lib/demon-mac/state` (mode 0600)
  records last-rotation timestamp per (iface, ssid). Survives NM reset,
  uninstall, distro upgrade.

Daemon mode also supports:

- `PIN_MODE=ssid` — different MAC per Wi-Fi network.
- `ROTATION_POLICY=once` / `daily` / `weekly` / `monthly` — schedule rotation.
- `NM_CLONED_MAC_POLICY=preserve` — daemon enforces `preserve` on the
  NM profile so the daemon's MAC isn't overwritten on reactivation.

## Hybrid mode

`MANAGEMENT_MODE=hybrid`. Both supervisor and daemon run. Useful when
you want all of:

- Daily timer rotation on wired (needs daemon).
- Per-SSID MAC ACL on home Wi-Fi (needs daemon's pinning).
- Plus NM's hygiene guarantee that no other tool reverted the profile.

In hybrid mode, supervisor sets `cloned-mac-address=preserve` and
`mac-address-randomization=0` on the active profile — so NM does not
override the daemon's MAC, but the daemon's MAC still gets re-pinned
on every dispatcher event.

## Quick start

```sh
# install (requires root). Default mode = supervisor.
sudo make install

# status
systemctl status demon-mac-boot
systemctl list-timers demon-mac-rotate
journalctl -t demon-mac -n 50
nmcli -t -f connection,802-11-wireless.cloned-mac-address \
    connection show --active

# disable (three layers)
sudo sed -i 's/^ENABLED=true/ENABLED=false/' /etc/demon-mac.conf   # soft
sudo systemctl disable --now demon-mac-boot                       # hard
sudo make uninstall                                                # full
```

To switch to kernel-direct mode (full daemon, OUI prefix, daily timer):

```sh
sudo sed -i 's/^MANAGEMENT_MODE=supervisor/MANAGEMENT_MODE=daemon/' /etc/demon-mac.conf
sudo make install
sudo systemctl restart demon-mac-boot demon-mac-rotate.timer
```

## Configuration (`/etc/demon-mac.conf`)

| Key | Default | Mode | Meaning |
|---|---|---|---|
| `ENABLED` | `true` | all | Master kill-switch |
| `MANAGEMENT_MODE` | `supervisor` | all | `supervisor` / `daemon` / `hybrid` |
| `NM_CLONED_MAC` | `stable` | supervisor / hybrid | Target `cloned-mac-address`: `stable` or `random` |
| `ROTATION_POLICY` | `connection` | daemon / hybrid | `connection`, `boot`, `once`, `daily`, `weekly`, `monthly` |
| `PIN_MODE` | `none` | daemon / hybrid | `none` / `ssid` / `iface` |
| `MAC_PREFIX` | empty | daemon / hybrid | `XX:XX` hex prefix; ignored in supervisor |
| `TARGETS` | empty | all | Empty = all physical; else comma-separated iface list |
| `STATE_FILE` | `/var/lib/demon-mac/state` | daemon / hybrid | Mode 0600. Not used in supervisor |
| `NM_CLONED_MAC_POLICY` | `preserve` | daemon / hybrid | `preserve` / `none` — see daemon mode docs |
| `STABILIZE_IPV6` | `true` | daemon / hybrid | sysctl `addr_gen_mode=1` after MAC change |
| `LOG_FILE` | empty | all | Optional file log (journald always) |
| `LOG_LEVEL` | `info` | all | debug / info / warn / error |

## Triggers

All three triggers fire `demon-mac.sh`. The behavior differs by mode:

- **`demon-mac-boot.service`** — systemd oneshot at multi-user.target,
  invokes `demon-mac boot`. Iterates physical ifaces.
  - **supervisor**: ensures each iface's NM profile has the right setting.
  - **daemon**: rotates per `ROTATION_POLICY`.
- **`demon-mac-rotate.timer`** — daily systemd timer with 15-min
  randomized delay; invokes `demon-mac rotate`.
  - **supervisor**: idempotent re-check on all physical ifaces.
  - **daemon**: rotates if state age exceeds policy threshold.
- **`/etc/NetworkManager/dispatcher.d/99-demon-mac`** — NM dispatcher
  hook; reacts to `pre-up` event, invokes
  `demon-mac connection <iface> <SSID>`. Forwards `$CONNECTION_UUID`
  as env so the daemon can address the right profile.
  - **supervisor**: ensures the new profile has the right setting.
  - **daemon**: rotates the MAC and enforces `cloned-mac-address=preserve`.

## Caveats

- **Wi-Fi `down/up` drops the link for ~100–500 ms** — daemon mode only.
  Supervisor doesn't touch the kernel. If you need unbroken Wi-Fi
  sessions, stay on supervisor or use a wired `TARGETS` entry.
- **Wi-Fi drivers**: daemon mode does `down/up` for most drivers
  (`iwlwifi`, `ath9k`, `mt76`, `rtw88`). `brcmfmac` (Broadcom) and
  several Realtek USB sticks either reject the MAC change silently
  or refuse while associated; the daemon verifies the post-set MAC
  and logs `post-set MAC mismatch` on rejection. Check `dmesg`.
- **IPv6 link-local**: daemon mode sets `addr_gen_mode=1` so SLAAC LL
  no longer derives from the kernel MAC. In supervisor mode NM picks
  its own scheme.
- **Per-SSID pinning weakens in-network privacy** — same MAC across
  visits; visit frequency visible to network-side logging. Cross-SSID
  privacy preserved.
- **Concurrent triggers** (daemon / hybrid only): `flock` on
  `<state_dir>/demon-mac.lock` serializes boot + rotate.timer. The
  loser exits 0 with `another instance holds ... exiting`. Supervisor
  mode takes no flock.
- **State file is mode 0600** (daemon / hybrid). Supervisor doesn't
  write one. Reading `/var/lib/demon-mac/` requires root.

## Migration from earlier versions

The default mode changed from `daemon` to `supervisor`. To keep the
old kernel-direct behavior, add to `/etc/demon-mac.conf`:

```
MANAGEMENT_MODE=daemon
```

Then `sudo make install` and restart the units. Existing
`/var/lib/demon-mac/state` keeps working — same format, same perms.

## Uninstall behavior

`sudo make uninstall` reverses the daemon's NM-side mutations:

1. Reads `/var/lib/demon-mac/touched-profiles` — a list of NM connection
   UUIDs the daemon modified, with the original `cloned-mac-address` and
   `mac-address-randomization` values captured before each modification.
2. Calls `nmcli connection modify <UUID> <field> <original>` for each
   entry, restoring the profile to the pre-demon-mac state.
3. Removes the daemon files, units, and NM dispatcher.
4. Removes the touched-profiles file (consumed).

The `/var/lib/demon-mac/state` file (per-(iface, ssid) rotation record
in daemon mode) is **preserved** — operator-managed. The
`/etc/demon-mac.conf` is also preserved.

If you ran the daemon only in supervisor mode and never as root on
this machine, touched-profiles is empty and the restore step is a
no-op.

If touched-profiles is missing or malformed, the restore step prints
a warning and continues — no daemon-side mutations are reversed, but
the rest of uninstall runs.

## Tests

```sh
make test         # 57 smoke tests: mode dispatch + supervisor + hybrid + daemon
make lint         # bash -n on scripts
```

## See also

- `ARCHITECTURE.md` — design and component map
- `DAEMON.md` — daemon contract and lifecycle
- `RUNBOOK.md` — troubleshooting and operations
