# Architecture

## Goal

Sit on top of NetworkManager and either (a) ensure NM's built-in
per-profile MAC randomization is configured correctly (supervisor
mode, default), or (b) take over MAC management from NM with
kernel-direct MAC writes, persistent state, and operator-readable
audit (daemon / hybrid mode).

## Layered model

```
┌─────────────────────────────────────────────────────────────────┐
│ Layer 1: NetworkManager built-in                                │
│   `802-11-wireless.cloned-mac-address = stable|random`           │
│   `802-11-wireless.mac-address-randomization = 2`                │
│   → upstream-supported, distro-tested, covers most use cases    │
└─────────────────────────────────────────────────────────────────┘
                                ▲
                                │ configures / supervises
                                │
┌─────────────────────────────────────────────────────────────────┐
│ Layer 2: demon-mac (default)                                    │
│   supervisor mode — idempotent `nmcli connection modify`        │
│   ensures Layer 1 is set on every Wi-Fi profile.                │
│   No kernel writes. No state file. No flock.                    │
└─────────────────────────────────────────────────────────────────┘
                                ▲
                                │ (opt-in) takes over MAC management
                                │
┌─────────────────────────────────────────────────────────────────┐
│ Layer 3: demon-mac kernel-direct                                │
│   daemon / hybrid mode — `ip link set address` + state file     │
│   + flock + reconcile. Required for MAC_PREFIX, daily timer     │
│   on wired, PIN_MODE=ssid with explicit rotation, self-heal.     │
└─────────────────────────────────────────────────────────────────┘
```

## Components

```
┌─────────────────────────────────────────────────────────────────┐
│ triggers                                                         │
│   ├─ systemd: demon-mac-boot.service (oneshot @ multi-user)     │
│   ├─ NM dispatcher: 99-demon-mac (pre-up event)                 │
│   │     └─ argv3 = $CONNECTION_ID, env $CONNECTION_UUID         │
│   └─ systemd timer: demon-mac-rotate.timer (OnCalendar=daily)   │
│       └─ → demon-mac-rotate.service → demon-mac rotate          │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ demon-mac.sh <mode> [iface] [ssid]                               │
│   mode = boot | connection | rotate                              │
│   MANAGEMENT_MODE = supervisor | daemon | hybrid                 │
│                                                                    │
│   1. parse args (exit 64 on bad)                                  │
│   2. source /etc/demon-mac.conf                                   │
│   3. ENABLED gate (exit 0 if not true)                            │
│   4. defaults: MANAGEMENT_MODE=supervisor, NM_CLONED_MAC=stable │
│   5. validate MAC_PREFIX, MANAGEMENT_MODE, NM_CLONED_MAC, etc.  │
│   6. acquire flock (daemon / hybrid only)                        │
│   7. iterate physical ifaces (filtered by TARGETS)               │
│   8. dispatch by MANAGEMENT_MODE:                                 │
│      - supervisor: apply_nm_supervisor(iface)                    │
│        * resolve active NM connection UUID                        │
│        * read current settings                                    │
│        * nmcli modify if drifted (idempotent)                     │
│      - daemon / hybrid:                                          │
│        * reconcile_iface (boot/rotate only)                       │
│        * should_rotate(iface, ssid, trigger)                     │
│        * if hybrid: apply_nm_supervisor(iface)                   │
│        * apply_change(iface, key):                               │
│          - generate_mac() → prefix:XX:XX:XX:XX or full random    │
│          - ip link set down / address / up                        │
│          - sysctl addr_gen_mode=1 (if STABILIZE_IPV6=true)        │
│          - enforce cloned-mac-address=preserve on profile         │
│          - write_state(iface, key, mac, iso-ts)                   │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ audit                                                            │
│   ├─ journald (always, tag "demon-mac")                          │
│   ├─ LOG_FILE (if set, append-only)                               │
│   └─ state file (daemon / hybrid, mode 0600)                     │
└─────────────────────────────────────────────────────────────────┘
```

## State file

`/var/lib/demon-mac/state` — pipe-separated, one record per
(iface, ssid):

**New format (4 columns):**
```
wlan0|home-wifi|02:11:34:7a:bc:de|2026-09-03T10:00:00Z
wlan0|work-wifi|02:11:98:1f:23:45|2026-09-03T11:30:00Z
eth0||02:ab:cd:ef:01:23|2026-09-03T09:00:00Z        # boot-pin (empty ssid)
```

**Legacy format (3 columns, still readable):**
```
eth0|02:ab:cd:ef:01:23|2026-09-03T10:00:00Z
```

Read functions probe both formats in this order:

1. `iface|ssid|mac|ts` — exact (iface, ssid) match
2. Legacy `iface|mac|ts` (3 columns) — iface-only match

All matching is done in `awk` with `NF` + positional `$1`/`$2`
comparisons, so SSID values containing `|` or any regex metacharacter
are matched exactly (no shell-glob / grep-regex surprises).

Write always uses new format. When writing boot-pin (empty key), the
script replaces both empty-SSID new entries AND legacy entries for the
same iface (so the file converges to new format over time).

- Created on first apply; missing file is a normal state.
- Survives `uninstall.sh` (operator-managed; if you want a fresh start,
  `rm /var/lib/demon-mac/state` manually).
- Updated atomically: write to `mktemp` in same dir, then `mv`.
- File is created with mode `0600`, parent dir mode `0700` —
  MACs are persistent identifiers and should not be world-readable
  on a multi-user system.
- Not used in supervisor mode (NM is the source of truth for MAC state).

## MAC generation

`generate_mac()` produces 4 or 5 random bytes from `/dev/urandom` via
`head -c N /dev/urandom | od -An -tx1 | tr -d ' \n'` and formats
with the optional prefix:

**With `MAC_PREFIX=02:11`** (2 octets fixed, 4 octets random):
```
02:11:XX:XX:XX:XX
```

**Without prefix** (full random, first byte forced to `02`):
```
02:XX:XX:XX:XX:XX
```

The `02` first byte means:
| Bit | Value | Meaning |
|---|---|---|
| 0 (multicast) | 0 | unicast |
| 1 (U/L) | 1 | locally administered |
| 2-7 | random | rest of vendor space |

For `MAC_PREFIX`, the script validates that the first byte also has
bits 0=0, 1=1 (locally-administered unicast). Valid first bytes:
`02, 06, 0A, 0E, 12, ..., 7E, 82, ..., FE` (64 values).
Invalid prefix → WARN log + full random fallback.

After applying the new MAC, the daemon reads the link back and
compares — some drivers (`brcmfmac`, several Realtek USB chips)
silently ignore address changes; without the read-back the daemon
would log success while the link kept the old MAC.

## Pin key resolution

`lookup_key(trigger, ssid)` returns:
- `ssid` if `trigger=connection && PIN_MODE=ssid && ssid non-empty`
- `""` otherwise (per-iface pin)

| `PIN_MODE` | connection mode | boot/rotate mode |
|---|---|---|
| `none` | key="" (per-iface) | key="" (per-iface) |
| `ssid` | key=ssid (per-SSID) | key="" (per-iface) |
| `iface` | key="" (per-iface) | key="" (per-iface) |

## Rotation policy decision

`should_rotate(iface, ssid, trigger)` returns 0 (yes) or 1 (no) based
on `ROTATION_POLICY` and the resolved lookup key:

| Policy | Decision |
|---|---|
| `connection` | rotate iff trigger == `connection` |
| `boot` | rotate iff trigger == `boot` |
| `once` | rotate iff `(iface, key)` not in state |
| `daily` | rotate iff state age > 86400s (or key not in state) |
| `weekly` | rotate iff state age > 604800s (or key not in state) |
| `monthly` | rotate iff state age > 2592000s (or key not in state) |
| _unknown_ | fail safe: rotate |

## Trigger matrix

| Trigger | Source | Mode called | Iterates | Args |
|---|---|---|---|---|
| `boot` | `demon-mac-boot.service` | `boot` | all physical ifaces | (none) |
| `connection` | NM `pre-up` event | `connection <iface> <ssid>` | single iface | argv3 = NM `$CONNECTION_ID` |
| `rotate` | `demon-mac-rotate.timer` | `rotate` | all physical ifaces | (none) |

## Disable model (3-layer)

1. **Config flag**: `ENABLED=false` in `/etc/demon-mac.conf` —
   script reads at start, exits 0 with log.
2. **systemd disable**: `systemctl disable demon-mac-boot` /
   `demon-mac-rotate.timer` — triggers never fire.
3. **Uninstall**: `make uninstall` removes files, units, dispatcher.

## Concurrency / single-flight

`boot`, `rotate.timer` and (when wired) the dispatcher can all
invoke the daemon within seconds of each other. In `daemon` /
`hybrid` mode, the daemon acquires a non-blocking `flock` on
`<state_dir>/demon-mac.lock` immediately after the ENABLED gate.
The loser exits 0 with a log line. This serializes:

- concurrent state-file writes (the `mktemp`+`mv` is atomic on a
  single FS, but two writers can still race on read-modify-write),
- two simultaneous `ip link set down/address/up` on the same iface
  (which can leave the link in a half-down state on some drivers).

The lock lives in the state directory (same local FS as the state
file, so `flock` semantics hold).

Supervisor mode takes no lock — NM handles its own concurrency on
the profile, and the daemon only does idempotent `nmcli modify`
calls.

## NetworkManager interaction

Two modes, opposite directions:

**Supervisor mode (default)** — daemon configures NM to do the
randomization itself. Reads the profile's current
`802-11-wireless.cloned-mac-address` and
`802-11-wireless.mac-address-randomization`, compares to
`NM_CLONED_MAC` / `2`, and idempotently calls
`nmcli connection modify uuid $CONNECTION_UUID ...` when drift is
detected. Target values:
- `cloned-mac-address = $NM_CLONED_MAC` (`stable` by default — per-SSID pin)
- `mac-address-randomization = 2` (always randomize)

**Daemon mode** — daemon takes over MAC management. After every
successful `connection`-mode rotation, daemon calls
`nmcli connection modify uuid $CONNECTION_UUID cloned-mac-address preserve`
(`NM_CLONED_MAC_POLICY=preserve`, default) so NM doesn't overwrite
the daemon's MAC on next reactivation. Idempotent — skipped if
already `preserve`.

**Hybrid mode** — supervisor runs first, setting
`cloned-mac-address=preserve` + `mac-address-randomization=0` (so NM
won't override the daemon's MAC), then daemon applies kernel MAC
and writes state.

Both modes require `nmcli` in `PATH` and `CONNECTION_UUID` exported
by the dispatcher (`99-demon-mac` does the export).

## Failure isolation

The script always exits 0 unless argument parsing fails (exit 64)
or the daemon was rejected by the lock (daemon / hybrid only).
Per-iface errors (driver rejects, MAC collision, down/up failure,
post-set mismatch, `nmcli modify` failure) are logged but do not
propagate. This ensures systemd boot proceeds and NM does not
retry on its own.

## Backward compatibility

- Script reads both legacy (3-column) and new (4-column) state formats.
- Existing installations with legacy state continue to work.
- New writes always use 4-column format.
- Boot-mode writes replace both legacy and empty-SSID new entries for
  the same iface, converging to new format over time.

## See also

- `DAEMON.md` — daemon contract
- `RUNBOOK.md` — operations and troubleshooting