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
sudo cat /var/lib/demon-mac/state      # last-rotation record per (iface, ssid); file is mode 0600
```

Inspect the active NM profile's `cloned-mac-address` setting:

```sh
nmcli -t -g 802-11-wireless.cloned-mac-address,cloned-mac-address \
    con show uuid "$CONNECTION_UUID"
# expect: preserve
```

## Switching rotation policy

```sh
sudo sed -i 's/^ROTATION_POLICY=.*/ROTATION_POLICY=daily/' /etc/demon-mac.conf
sudo systemctl restart demon-mac-rotate.timer
```

## Setting up MAC-authenticated router

This is the typical setup workflow when your router has a MAC ACL.

1. **Edit config** for per-SSID pinning:

   ```sh
   sudo nano /etc/demon-mac.conf
   ```

   Set:

   ```sh
   ENABLED=true
   ROTATION_POLICY=once      # rotate once per SSID, persist forever
   PIN_MODE=ssid             # critical: keeps MAC stable per Wi-Fi network
   MAC_PREFIX=02:11          # optional: constrain to chosen range
   ```

2. **Install** (or restart if already installed):

   ```sh
   sudo make install  # or: sudo systemctl restart demon-mac-boot
   ```

3. **Connect to each SSID once** to generate the pinned MAC:

   ```sh
   # Connect to home Wi-Fi via NetworkManager GUI or nmcli
   # The dispatcher hook fires on pre-up and pins a MAC
   ```

4. **Find the pinned MAC**:

   ```sh
   cat /var/lib/demon-mac/state
   # Example output:
   # wlan0|home-wifi|02:11:34:7a:bc:de|2026-09-03T10:00:00Z
   # wlan0|work-wifi|02:11:98:1f:23:45|2026-09-03T11:30:00Z

   ip link show dev wlan0 | grep ether
   # link/ether 02:11:34:7a:bc:de   <-- same as state file
   ```

5. **Add MAC to router ACL** for each SSID (do this once per network).

6. **From now on**, reconnects reuse the same MAC and pass the ACL.

### Adding a new SSID later

1. Connect to the new SSID (any rotation policy will generate a fresh MAC)
2. Find the new MAC: `cat /var/lib/demon-mac/state | grep <ssid>`
3. Add it to the router ACL

### Changing PIN_MODE mid-operation

Switching `PIN_MODE` doesn't break existing state entries — it only
affects future lookups:

- `none` → `ssid`: future connections will key on SSID, generating
  new MACs for each (iface, ssid) the first time
- `ssid` → `none`: future connections ignore SSID and rotate freely

If you want to reset, clear state: `sudo rm /var/lib/demon-mac/state`.

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
| MAC reverts to original a few seconds after rotation | NM profile has `cloned-mac-address=random`/`stable` and overrides the daemon | Confirm daemon log shows `set cloned-mac-address=preserve`; if not, set `NM_CLONED_MAC_POLICY=preserve` (default) or run `nmcli connection modify uuid <UUID> cloned-mac-address preserve` by hand |
| Daemon logs `post-set MAC mismatch` | Driver (often `brcmfmac` or Realtek USB) silently rejected the address change | Check `dmesg`; if `iw`/`ip link` shows the old MAC after the daemon's run, the chip can't change MAC while associated — skip that iface via `TARGETS` |
| NM keeps reconnecting after each boot | MAC change triggers re-DHCP | Expected; one reconnect is fine; or set `PIN_MODE=ssid` |
| Wi-Fi won't associate after MAC change | Driver doesn't accept change while associated | Disable Wi-Fi trigger; use wired only (e.g. `TARGETS=eth0`) |
| DHCP fails after boot | DHCP server filters by MAC | Either whitelist new MAC, or set `TARGETS=` to skip this iface |
| Router rejects MAC despite ACL | `PIN_MODE=none` and MAC rotated | Set `PIN_MODE=ssid` so MAC stays stable per network |
| MAC is `00:xx:xx:xx:xx:xx` after install | `MAC_PREFIX=00:xx` was accepted (universal OUI) | Use prefix with locally-administered first byte (02, 06, 0A, etc.); script warns but still rotates |
| `INVALID FORMAT` warning in journal | `MAC_PREFIX=` value not `XX:XX` hex | Use 2-byte hex format like `02:11` |
| IPv6 link-local keeps changing | MAC is changing; SLAAC rebuilds LL | `STABILIZE_IPV6=true` (default) sets `addr_gen_mode=1` |
| No MAC change on connection event | `CONNECTION_TRIGGER` triggers, but policy != `connection` | Check `ROTATION_POLICY`; for `daily`/etc, rotation happens at next expiration, not on every event |
| State file corrupted | Operator hand-edit | Delete state file; next rotation will recreate |
| Policy=`once` but MAC keeps changing | Someone cleared state, or multiple triggers fired | Normal — first trigger rotates and re-writes state |
| SSID lookup misses on connection | `CONNECTION_ID` empty in NM dispatcher | Check NM version; verify dispatcher gets `$CONNECTION_ID` env (`systemctl restart NetworkManager`) |
| Log shows `another instance holds ... exiting` | Two triggers (e.g. boot + rotate.timer) ran within the lock window | Expected; the losing invocation is a no-op. If persistent, check `flock` availability (`type flock`) |
| Permission denied reading `/var/lib/demon-mac/state` | File is mode 0600 by design | Use `sudo`; the file is restricted because MACs are persistent identifiers |

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