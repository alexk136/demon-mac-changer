#!/usr/bin/env bash
#
# uninstall.sh — remove demon-mac from system locations.
# Requires root.
#
# Restores NM-managed connection profiles to their pre-demon-mac state
# (reads /var/lib/demon-mac/touched-profiles; the daemon records original
# values before modifying any profile). Falls back to clearing daemon-set
# values on profiles that no longer have an original recorded.
#
# Preserves /etc/demon-mac.conf and /var/lib/demon-mac/state (operator-managed).
#
set -euo pipefail

require_root() {
    [[ $EUID -eq 0 ]] || { echo "uninstall.sh requires root" >&2; exit 1; }
}

disable_unit() {
    systemctl disable demon-mac-boot.service 2>/dev/null || true
    systemctl disable demon-mac-rotate.timer 2>/dev/null || true
    systemctl stop demon-mac-boot.service 2>/dev/null || true
    systemctl stop demon-mac-rotate.timer 2>/dev/null || true
}

# Restore NM profiles the daemon touched.
# File format: UUID|conn_type|original_cloned|original_random
#   - UUID: the connection UUID the daemon modified
#   - conn_type: 802-11-wireless | 802-3-ethernet (drives field selection)
#   - original_cloned: the value of <type>.cloned-mac-address BEFORE
#                       the daemon modified it; "" means "unset" (NM
#                       default for that type)
#   - original_random: for Wi-Fi, the value of mac-address-randomization
#                      BEFORE the daemon modified it; "" for ethernet
#                      (ethernet has no randomization field)
#
# Setting an NM property to the empty string "" reverts it to the
# type's default. So restoring the original "empty" state is just
# `nmcli ... <field> ""`.
restore_touched_profiles() {
    local file=/var/lib/demon-mac/touched-profiles
    [[ -r "$file" ]] || { echo "no touched-profiles file; nothing to restore"; return 0; }
    command -v nmcli >/dev/null 2>&1 || { echo "nmcli not found; cannot restore NM profiles"; return 0; }

    local restored=0 failed=0
    local uuid conn_type orig_cloned orig_random cloned_field random_field
    while IFS='|' read -r uuid conn_type orig_cloned orig_random; do
        [[ -z "$uuid" || -z "$conn_type" ]] && continue

        case "$conn_type" in
            802-11-wireless)
                cloned_field="802-11-wireless.cloned-mac-address"
                random_field="802-11-wireless.mac-address-randomization"
                ;;
            802-3-ethernet)
                cloned_field="802-3-ethernet.cloned-mac-address"
                random_field=""
                ;;
            *)
                echo "WARN: unknown conn_type '$conn_type' for $uuid; skipping"
                continue
                ;;
        esac

        if nmcli connection modify uuid "$uuid" "$cloned_field" "${orig_cloned:-}" 2>/dev/null; then
            echo "  restored $uuid: $cloned_field=${orig_cloned:-<default>}"
            restored=$((restored + 1))
        else
            echo "WARN: failed to restore $cloned_field on $uuid"
            failed=$((failed + 1))
        fi

        if [[ -n "$random_field" ]]; then
            if nmcli connection modify uuid "$uuid" "$random_field" "${orig_random:-}" 2>/dev/null; then
                echo "  restored $uuid: $random_field=${orig_random:-<default>}"
                restored=$((restored + 1))
            else
                echo "WARN: failed to restore $random_field on $uuid"
                failed=$((failed + 1))
            fi
        fi
    done < "$file"

    # Always remove the tracking file (success or partial failure)
    rm -f "$file"

    echo "touched-profiles: restored=$restored failed=$failed"
    return 0
}

remove_files() {
    rm -f /usr/local/sbin/demon-mac
    rm -f /etc/systemd/system/demon-mac-boot.service
    rm -f /etc/systemd/system/demon-mac-rotate.service
    rm -f /etc/systemd/system/demon-mac-rotate.timer
    rm -f /etc/NetworkManager/dispatcher.d/99-demon-mac
}

reload() {
    systemctl daemon-reload
    systemctl reload NetworkManager 2>/dev/null || true
}

require_root
echo "=== restoring NM profiles ==="
restore_touched_profiles
disable_unit
remove_files
reload
echo
echo "uninstall complete"
echo "  removed: /usr/local/sbin/demon-mac, systemd units, NM dispatcher"
echo "  preserved: /etc/demon-mac.conf (your config)"
echo "  preserved: /var/lib/demon-mac/state (per-(iface,ssid) rotation record; remove manually if no longer needed)"
echo "  removed:   /var/lib/demon-mac/touched-profiles (NM restore list, consumed above)"
