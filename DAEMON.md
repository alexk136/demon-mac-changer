# Daemon Contract

## Identity

- **Name**: demon-mac
- **Modes**: `boot`, `connection`, `rotate`
- **Triggers**:
  - `boot` — systemd `demon-mac-boot.service` (oneshot)
  - `connection` — NM dispatcher `99-demon-mac` on `pre-up`,
    argv3 = `$CONNECTION_ID` (SSID/profile name)
  - `rotate` — systemd timer `demon-mac-rotate.timer` (daily, +15min random)

## Inputs

| Input | Source | Type | Default |
|---|---|---|---|
| `mode` | argv[1] | enum: `boot`, `connection`, `rotate` | `boot` |
| `iface` | argv[2] | string (required for connection) | — |
| `ssid` | argv[3] | string (NM `$CONNECTION_ID`) | empty |
| config | `/etc/demon-mac.conf` | shell KEY=VALUE | disabled |
| `DEMON_MAC_CONF` | env | path | `/etc/demon-mac.conf` |
| `DEMON_MAC_DRY_RUN` | env | `0` or `1` | `0` |
| `DEMON_MAC_BYPASS_PHYSICAL` | env | `0` or `1` (test-only) | `0` |

## Config keys

| Key | Default | Range |
|---|---|---|
| `ENABLED` | `true` | `true`/`false` |
| `ROTATION_POLICY` | `connection` | `connection`/`boot`/`once`/`daily`/`weekly`/`monthly` |
| `PIN_MODE` | `none` | `none`/`ssid`/`iface` |
| `MAC_PREFIX` | empty | `XX:XX` hex (locally-administered first byte) |
| `TARGETS` | empty | comma-separated iface list |
| `STATE_FILE` | `/var/lib/demon-mac/state` | path |
| `STABILIZE_IPV6` | `true` | `true`/`false` |
| `LOG_FILE` | empty | path |
| `LOG_LEVEL` | `info` | `debug`/`info`/`warn`/`error` |

## Outputs

- **journald**: tag `demon-mac`, priority `user.{debug,info,warning,err}`
- **log file**: `LOG_FILE` if set, append-only, one line per event
- **state file**: per-(iface, ssid) rotation record, see ARCHITECTURE.md

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
- **rotate**: invoked daily by by the systemd timer.

## State

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
uninstall.

## Failure handling

| Failure | Behavior |
|---|---|
| Driver rejects MAC change | Log + continue (next iface or exit) |
| Interface not in `TARGETS` | Skip with log |
| Interface not physical (no `/sys/class/net/<iface>/device/`) | Skip with log |
| Config file missing | Behave as `ENABLED=false`, log warning |
| `ip link set ... down`/`address`/`up` fails | Log + best-effort revert + exit 0 |
| `MAC_PREFIX` invalid format | WARN log + full random fallback |
| `MAC_PREFIX` first byte not locally-administered | WARN log + full random fallback |
| `PIN_MODE` invalid value | WARN log + treat as `none` |
| Any other error | Log + exit 0 (never break systemd boot) |

## Operator override

`/etc/demon-mac.conf` is operator-editable. To pick up changes for the
boot or rotate trigger, restart:

```sh
systemctl restart demon-mac-boot
systemctl restart demon-mac-rotate
```

The dispatcher picks up the new config on its next `pre-up` event.

## See also

- `ARCHITECTURE.md` — design
- `RUNBOOK.md` — operations
- `README.md` — quick start