# demon-mac

MAC address randomizer for sysadmin-owned hosts. Randomizes MAC at boot,
on each NetworkManager connection, and (optionally) on a periodic schedule,
with full kill-switch via config and systemd.

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
```

## Configuration (`/etc/demon-mac.conf`)

| Key | Default | Meaning |
|---|---|---|
| `ENABLED` | `true` | Master kill-switch |
| `ROTATION_POLICY` | `connection` | One of `connection`, `boot`, `once`, `daily`, `weekly`, `monthly` |
| `TARGETS` | empty | Empty = all physical; else comma-separated iface list |
| `STATE_FILE` | `/var/lib/demon-mac/state` | Per-iface rotation timestamp (operator-managed) |
| `STABILIZE_IPV6` | `true` | sysctl `addr_gen_mode=1` after MAC change |
| `LOG_FILE` | empty | Optional file log (journald always) |
| `LOG_LEVEL` | `info` | debug / info / warn / error |

## Rotation policies

| Policy | Behavior | Trigger used |
|---|---|---|
| `connection` | Rotate on every NM `pre-up` | `connection` |
| `boot` | Rotate on every boot | `boot` |
| `once` | Rotate once, persist forever | first trigger fires |
| `daily` | Rotate if last rotation > 24h | `connection` + `rotate` timer |
| `weekly` | Rotate if last rotation > 7d | `connection` + `rotate` timer |
| `monthly` | Rotate if last rotation > 30d | `connection` + `rotate` timer |

For periodic policies (`daily`/`weekly`/`monthly`), the
`demon-mac-rotate.timer` ensures rotation happens even without
network churn (e.g., stable ethernet at home for a week).

## Triggers

- **`demon-mac-boot.service`** — systemd oneshot at multi-user.target,
  runs `demon-mac boot` (iterates all physical ifaces).
- **`demon-mac-rotate.timer`** — daily systemd timer with 15-min
  randomized delay; activates `demon-mac-rotate.service` which runs
  `demon-mac rotate` (iterates all physical ifaces, checks state).
- **`/etc/NetworkManager/dispatcher.d/99-demon-mac`** — NM dispatcher
  hook; reacts to `pre-up` event, runs `demon-mac connection <iface>`.

## Components

- `demon-mac.sh` — main script; modes `boot`, `connection <iface>`, `rotate`
- `demon-mac.conf.example` — config template
- `systemd/demon-mac-boot.service` — boot-time oneshot
- `systemd/demon-mac-rotate.service` — periodic oneshot
- `systemd/demon-mac-rotate.timer` — daily calendar trigger
- `networkmanager/99-demon-mac` — dispatcher (`pre-up`)
- `install.sh` / `uninstall.sh` — system install/uninstall
- `Makefile` — install / uninstall / test / lint targets
- `tests/smoke.sh` — policy matrix + state validation

## Caveats

- **Breaks**: MAC-bound DHCP, captive portals with MAC ACL,
  hardware-bound licensing.
- **IPv6 link-local** changes with MAC; `STABILIZE_IPV6=true`
  sets `addr_gen_mode=1` (random but not MAC-derived).
- **Wi-Fi**: `down/up` works for most drivers (iwlwifi, ath9k,
  mt76, rtw88). Some Broadcom chips reject MAC change; check `dmesg`.

## Tests

```sh
make test         # all smoke tests
make lint         # bash -n on scripts
```

## See also

- `ARCHITECTURE.md` — design and component map
- `DAEMON.md` — daemon contract and lifecycle
- `RUNBOOK.md` — troubleshooting and operations