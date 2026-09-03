# Architecture

## Goal

Randomize host MAC address at boot, on each network connection, and on a
periodic schedule. Operator can choose rotation policy via a single
config key, and disable via 3 layers (config flag, systemd disable,
uninstall).

## Components

```
┌─────────────────────────────────────────────────────────────────┐
│ triggers                                                         │
│   ├─ systemd: demon-mac-boot.service (oneshot @ multi-user)     │
│   ├─ NM dispatcher: 99-demon-mac (pre-up event)                 │
│   └─ systemd timer: demon-mac-rotate.timer (OnCalendar=daily)   │
│       └─ → demon-mac-rotate.service → demon-mac rotate          │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ demon-mac.sh <mode> [iface]                                      │
│   mode = boot | connection | rotate                              │
│                                                                    │
│   1. parse args (exit 64 on bad)                                  │
│   2. source /etc/demon-mac.conf                                   │
│   3. ENABLED gate (exit 0 if not true)                            │
│   4. defaults: ROTATION_POLICY=connection, STATE_FILE=...         │
│   5. iterate physical ifaces (filtered by TARGETS)                │
│   6. should_rotate(iface, trigger) → checks ROTATION_POLICY + state│
│   7. apply_change(iface):                                        │
│        - generate_mac() → 02:xx:xx:xx:xx:xx                     │
│        - ip link set down / address / up                         │
│        - sysctl addr_gen_mode=1 (if STABILIZE_IPV6=true)         │
│        - write_state(iface, mac, iso-ts)                         │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ audit                                                             │
│   ├─ journald (always, tag "demon-mac")                          │
│   └─ LOG_FILE (if set, append-only)                               │
└─────────────────────────────────────────────────────────────────┘
```

## State file

`/var/lib/demon-mac/state` — pipe-separated, one record per iface:

```
eth0|02:ab:cd:ef:01:23|2026-09-03T10:00:00Z
wlan0|02:11:22:33:44:55|2026-09-03T10:00:00Z
```

- Created on first apply; missing file is a normal state.
- Survives `uninstall.sh` (operator-managed; if you want a fresh start,
  `rm /var/lib/demon-mac/state` manually).
- Updated atomically: write to `mktemp` in same dir, then `mv`.

## MAC generation

`generate_mac()` produces 5 random bytes from `/dev/urandom` and
prepends the locally-administered octet `02:`:

| Bit | Value | Meaning |
|---|---|---|
| 0 (multicast) | 0 | unicast |
| 1 (U/L) | 1 | locally administered |
| 2-7 | random | rest of vendor space |

This guarantees:

- Never a real OUI (locally-administered bit set).
- Never multicast (multicast bit clear).
- Never reserved.

## Rotation policy decision

`should_rotate(iface, trigger)` returns 0 (yes) or 1 (no) based on
`ROTATION_POLICY`:

| Policy | Decision |
|---|---|
| `connection` | rotate iff trigger == `connection` |
| `boot` | rotate iff trigger == `boot` |
| `once` | rotate iff iface not in state |
| `daily` | rotate iff state age > 86400s (or iface not in state) |
| `weekly` | rotate iff state age > 604800s (or iface not in state) |
| `monthly` | rotate iff state age > 2592000s (or iface not in state) |
| _unknown_ | fail safe: rotate |

For periodic policies, the timer + boot + connection triggers all
consult the state file; whichever fires first post-expiration wins.

## Trigger matrix

| Trigger | Source | Mode called | Iterates |
|---|---|---|---|
| `boot` | `demon-mac-boot.service` | `boot` | all physical ifaces |
| `connection` | NM `pre-up` event | `connection <iface>` | single iface |
| `rotate` | `demon-mac-rotate.timer` | `rotate` | all physical ifaces |

## Disable model (3-layer)

1. **Config flag**: `ENABLED=false` in `/etc/demon-mac.conf` —
   script reads at start, exits 0 with log.
2. **systemd disable**: `systemctl disable demon-mac-boot` /
   `demon-mac-rotate.timer` — triggers never fire.
3. **Uninstall**: `make uninstall` removes files, units, dispatcher.

## Failure isolation

The script always exits 0 unless argument parsing fails (exit 64).
Per-iface errors (driver rejects, MAC collision, down/up failure)
are logged but do not propagate. This ensures systemd boot proceeds
and NM does not retry on its own.

## See also

- `DAEMON.md` — daemon contract
- `RUNBOOK.md` — operations and troubleshooting