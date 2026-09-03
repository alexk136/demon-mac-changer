# Daemon Contract

## Identity

- **Name**: demon-mac
- **Modes**: `boot`, `connection`, `rotate`
- **Triggers**:
  - `boot` — systemd `demon-mac-boot.service` (oneshot)
  - `connection` — NM dispatcher `99-demon-mac` on `pre-up`
  - `rotate` — systemd timer `demon-mac-rotate.timer` (daily, +15min random)

## Inputs

| Input | Source | Type | Default |
|---|---|---|---|
| `mode` | argv[1] | enum: `boot`, `connection`, `rotate` | `boot` |
| `iface` | argv[2] | string (required for connection) | — |
| config | `/etc/demon-mac.conf` | shell KEY=VALUE | disabled |
| `DEMON_MAC_CONF` | env | path | `/etc/demon-mac.conf` |
| `DEMON_MAC_DRY_RUN` | env | `0` or `1` | `0` |

## Outputs

- **journald**: tag `demon-mac`, priority `user.{debug,info,warning,err}`
- **log file**: `LOG_FILE` if set, append-only, one line per event

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
- **rotate**: invoked daily by systemd timer.

## State

State file at `${STATE_FILE}` (default `/var/lib/demon-mac/state`):

```
iface|mac|iso-timestamp
```

One record per iface, updated atomically. Survives uninstall.

## Failure handling

| Failure | Behavior |
|---|---|
| Driver rejects MAC change | Log + continue (next iface or exit) |
| Interface not in `TARGETS` | Skip with log |
| Interface not physical (no `/sys/class/net/<iface>/device/`) | Skip with log |
| Config file missing | Behave as `ENABLED=false`, log warning |
| `ip link set ... down`/`address`/`up` fails | Log + best-effort revert + exit 0 |
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