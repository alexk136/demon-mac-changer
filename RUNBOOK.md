# Runbook

## Installation

```sh
sudo make install
```

Or step-by-step:

```sh
sudo install -m755 demon-mac.sh /usr/local/sbin/demon-mac
sudo install -m644 demon-mac.conf.example /etc/demon-mac.conf
sudo install -m644 systemd/demon-mac-boot.service /etc/systemd/system/
sudo install -m644 systemd/demon-mac-rotate.service /etc/systemd/system/
sudo install -m644 systemd/demon-mac-rotate.timer /etc/systemd/system/
sudo install -m755 networkmanager/99-demon-mac /etc/NetworkManager/dispatcher.d/
sudo mkdir -p -m 700 /var/lib/demon-mac
sudo systemctl daemon-reload
sudo systemctl enable --now demon-mac-boot.service
sudo systemctl enable --now demon-mac-rotate.timer
```

## Disabling

**Soft (config flag):**

```sh
sudo sed -i 's/^ENABLED=true/ENABLED=false/' /etc/demon-mac.conf
sudo systemctl restart demon-mac-boot demon-mac-rotate.timer
```

**Hard (systemd):**

```sh
sudo systemctl disable --now demon-mac-boot.service
sudo systemctl disable --now demon-mac-rotate.timer
```

**Uninstall:**

```sh
sudo make uninstall
```

`/etc/demon-mac.conf` and `/var/lib/demon-mac/state` are preserved
(operator-managed).

## Status check

```sh
systemctl status demon-mac-boot.service
systemctl list-timers demon-mac-rotate
journalctl -t demon-mac -n 50
ip link show dev eth0 | grep ether     # current MAC
cat /var/lib/demon-mac/state            # last-rotation record
```

## Switching rotation policy

```sh
sudo sed -i 's/^ROTATION_POLICY=.*/ROTATION_POLICY=daily/' /etc/demon-mac.conf
sudo systemctl restart demon-mac-rotate.timer
```

## Restoring original MAC

```sh
sudo ip link set dev eth0 down
sudo ip link set dev eth0 address aa:bb:cc:dd:ee:ff   # original from label
sudo ip link set dev eth0 up
sudo rm /var/lib/demon-mac/state  # clear state so next trigger re-applies
```

Original MAC is on the NIC label, or via `dmesg | grep -i mac`, or
`ethtool -P eth0` (persistent MAC).

## Resetting state

To force the next rotation regardless of policy:

```sh
sudo rm /var/lib/demon-mac/state
sudo systemctl restart demon-mac-rotate.timer
```

For `once` policy specifically, removing the state makes the next
trigger rotate again.

## Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| NM keeps reconnecting after each boot | MAC change triggers re-DHCP | Expected; one reconnect is fine |
| Wi-Fi won't associate after MAC change | Driver doesn't accept change while associated | Disable Wi-Fi trigger; use wired only |
| DHCP fails after boot | DHCP server filters by MAC | Either whitelist new MAC, or set `TARGETS=` to skip this iface |
| IPv6 link-local keeps changing | MAC is changing; SLAAC rebuilds LL | `STABILIZE_IPV6=true` (default) sets `addr_gen_mode=1` |
| No MAC change on connection event | `CONNECTION_TRIGGER` triggers, but policy != `connection` | Check `ROTATION_POLICY`; for `daily`/etc, rotation happens at next expiration, not on every event |
| State file corrupted | Operator hand-edit | Delete state file; next rotation will recreate |
| Policy=`once` but MAC keeps changing | Someone cleared state, or multiple triggers fired | Normal — first trigger rotates and re-writes state |

## Driver notes

| Driver | Status | Notes |
|---|---|---|
| `iwlwifi` | ✅ | `down/up` works; `iwlmvm` not in monitor mode |
| `ath9k` | ✅ | Generally OK |
| `rtw88` | ✅ | Newer driver, OK |
| `mt76` | ✅ | OK |
| `brcmfmac` | ⚠️ | Some Broadcom chips reject MAC change; check `dmesg` |
| `e1000e` | ✅ | Wired, OK |
| `r8169` | ✅ | Wired, OK |

## Log noise

If you see too many dispatcher calls, the script filters events to
`pre-up` only. Other events (`up`, `down`, `hostname`, etc.) are
ignored by `99-demon-mac`.

## See also

- `README.md` — quick start
- `ARCHITECTURE.md` — design
- `DAEMON.md` — contract