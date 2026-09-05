# Daemon Contract

## Identity

- **Name**: demon-mac
- **Invocation modes**: `boot`, `connection`, `rotate`
- **Management modes**: `supervisor`, `daemon`, `hybrid`
- **Triggers**:
  - `boot` — systemd `demon-mac-boot.service` (oneshot)
  - `connection` — NM dispatcher `99-demon-mac` on `pre-up`,
    argv3 = `$CONNECTION_ID` (SSID/profile name)
  - `rotate` — systemd timer `demon-mac-rotate.timer` (daily, +15min random)

## Management modes

| Mode | Kernel writes | State file | flock | nmcli modify | ROTATION_POLICY honored |
|---|---|---|---|---|---|
| `supervisor` (default) | ❌ | ❌ | ❌ | ✅ idempotent | ❌ (NM controls rotation) |
| `daemon` | ✅ | ✅ | ✅ | ✅ `preserve` | ✅ |
| `hybrid` | ✅ | ✅ | ✅ | ✅ `preserve` | ✅ |

**supervisor** is the safe default. Use it for typical laptops with
home Wi-Fi and/or wired Ethernet. The daemon ensures every active
Wi-Fi or Ethernet connection profile has the configured NM
randomization setting. No driver-compat issues, no link flap, no
state file.

**daemon** is the original behavior. Use it when supervisor isn't
enough: `MAC_PREFIX`, periodic rotation on wired, `PIN_MODE=ssid`,
self-heal after NM revert.

**hybrid** runs both: supervisor first (sets `preserve` +
`mac-address-randomization=0`), then daemon (applies kernel MAC,
writes state). Use it when you want both daemon-driven MAC and NM
hygiene.

## Inputs

| Input | Source | Type | Default |
|---|---|---|---|
| `mode` | argv[1] | enum: `boot`, `connection`, `rotate` | `boot` |
| `iface` | argv[2] | string (required for connection) | — |
| `ssid` | argv[3] | string (NM `$CONNECTION_ID`) | empty |
| `CONNECTION_UUID` | env | NM connection UUID | empty |
| config | `/etc/demon-mac.conf` | shell KEY=VALUE | disabled |
| `DEMON_MAC_CONF` | env | path | `/etc/demon-mac.conf` |
| `DEMON_MAC_DRY_RUN` | env | `0` or `1` | `0` |
| `DEMON_MAC_BYPASS_PHYSICAL` | env | `0` or `1` (test-only) | `0` |
| `DEMON_MAC_FAKE_CURRENT_MAC` | env | test-only: override current MAC | empty |
| `DEMON_MAC_FAKE_IFACES` | env | test-only: override iface list | empty |

## Config keys

| Key | Default | Range | Used by |
|---|---|---|---|
| `ENABLED` | `true` | `true`/`false` | all |
| `MANAGEMENT_MODE` | `supervisor` | `supervisor`/`daemon`/`hybrid` | all |
| `NM_CLONED_MAC` | `stable` | `stable`/`random` | supervisor / hybrid |
| `ROTATION_POLICY` | `connection` | `connection`/`boot`/`once`/`daily`/`weekly`/`monthly` | daemon / hybrid |
| `PIN_MODE` | `none` | `none`/`ssid`/`iface` | daemon / hybrid |
| `MAC_PREFIX` | empty | `XX:XX` hex (locally-administered first byte) | daemon / hybrid |
| `TARGETS` | empty | comma-separated iface list | all |
| `STATE_FILE` | `/var/lib/demon-mac/state` | path (mode 0600) | daemon / hybrid |
| `NM_CLONED_MAC_POLICY` | `preserve` | `preserve`/`none` | daemon / hybrid |
| `STABILIZE_IPV6` | `true` | `true`/`false` | daemon / hybrid |
| `LOG_FILE` | empty | path | all |
| `LOG_LEVEL` | `info` | `debug`/`info`/`warn`/`error` | all |

## Outputs

- **journald**: tag `demon-mac`, priority `user.{debug,info,warning,err}`
- **log file**: `LOG_FILE` if set, append-only, one line per event
- **state file**: per-(iface, ssid) rotation record (daemon / hybrid only)
- **NM profile**: `cloned-mac-address` and `mac-address-randomization`
  set idempotently (supervisor / hybrid)

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success or skipped (always, except usage errors) |
| 64 | usage error (unknown mode, missing iface in connection mode) |

## Lifecycle

- **boot**: invoked once per boot by systemd. Stays "active" thereafter
  (`RemainAfterExit=yes`).
- **connection**: invoked per NM dispatcher `pre-up` event (potentially
  many per boot — every reconnect, every new SSID, every NM restart).
- **rotate**: invoked daily by the systemd timer.

## State (daemon / hybrid only)

State file at `${STATE_FILE}` (default `/var/lib/demon-mac/state`):

**New format (4 columns):**
```
iface|ssid|mac|iso-timestamp
```

**Legacy format (3 columns, still readable):**
```
iface|mac|iso-timestamp
```

Read functions probe both. Write always uses new format. Survives
uninstall. File created mode 0600 (parent dir 0700).

The daemon takes a non-blocking `flock` on
`<state_dir>/demon-mac.lock` immediately after the ENABLED gate;
a losing invocation exits 0 with a log line. Supervisor mode skips
the lock (no state writes, no kernel writes).

## Failure handling

| Failure | Behavior |
|---|---|
| Another instance holds the lock (daemon / hybrid) | Log + exit 0 |
| Driver rejects MAC change (ip returns non-zero) | Log + best-effort `up` + exit 0 |
| Post-set MAC read-back mismatch (driver silently dropped) | Log `post-set MAC mismatch` + exit non-zero from `apply_change` |
| `nmcli` modify fails (supervisor / hybrid) | WARN log + continue |
| Interface not in `TARGETS` | Skip with log |
| Interface not physical | Skip with log |
| Config file missing | Behave as `ENABLED=false`, log warning |
| `MAC_PREFIX` invalid format | WARN log + full random fallback |
| `MAC_PREFIX` first byte not locally-administered | WARN log + full random fallback |
| `PIN_MODE` invalid value | WARN log + treat as `none` |
| `MANAGEMENT_MODE` invalid value | WARN log + treat as `supervisor` |
| `NM_CLONED_MAC` invalid value | WARN log + treat as `stable` |
| `NM_CLONED_MAC_POLICY` invalid value | WARN log + treat as `none` |
| `MAC_PREFIX` set in supervisor mode | WARN log + ignore (set `MANAGEMENT_MODE=daemon`) |
| `ROTATION_POLICY=once\|daily\|weekly\|monthly\|boot` in supervisor mode | WARN log + ignore |
| Any other error | Log + exit 0 (never break systemd boot) |

## Reconcile (daemon / hybrid, non-connection triggers only)

For non-connection policies (`daily` / `weekly` / `monthly` / `once` /
`boot`) the daemon's contract is "this iface must have the MAC recorded
in state, and only rotate when the policy says so." If something (NM
profile, driver reset, manual edit) reverted the kernel MAC between
daemon runs, the daemon re-applies the state value on the next
`boot` or `rotate.timer` invocation, then enforces the NM profile
so the next reactivation doesn't revert again.

Skipped in `connection` mode — that policy always rotates fresh on
every dispatcher event, so re-applying stale state first would just
be overwritten by `apply_change` a moment later.

## Supervisor behavior

For each iface passed in, the daemon:

1. Resolves the active NM connection UUID (from `$CONNECTION_UUID` env,
   or via `nmcli device show <iface>` for boot/rotate).
2. Reads the connection type. Skips if not `802-11-wireless` or
   `802-3-ethernet` (VPN / GSM / bridge / etc. are not MAC-managed).
3. Reads current `connection.cloned-mac-address` (type-agnostic) and,
   for Wi-Fi only, `802-11-wireless.mac-address-randomization`.
4. Compares to target values:
   - supervisor: `cloned-mac-address=$NM_CLONED_MAC` (stable|random),
     `mac-address-randomization=2` (Wi-Fi only)
   - hybrid: `cloned-mac-address=preserve`,
     `mac-address-randomization=0` (Wi-Fi only, so NM doesn't override
     the daemon's MAC)
5. Calls `nmcli connection modify ...` only if the value differs
   (idempotent).

## Operator override

`/etc/demon-mac.conf` is operator-editable. To pick up changes for the
boot or rotate trigger, restart:

```sh
sudo systemctl restart demon-mac-boot
sudo systemctl restart demon-mac-rotate.timer
```

The dispatcher picks up the new config on its next `pre-up` event.

## See also

- `ARCHITECTURE.md` — design
- `RUNBOOK.md` — operations
- `README.md` — quick start
