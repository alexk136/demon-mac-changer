#!/usr/bin/env bash
#
# uninstall.sh — remove demon-mac from system locations.
# Requires root.
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
disable_unit
remove_files
reload
echo "uninstall complete; /etc/demon-mac.conf and /var/lib/demon-mac/state preserved"