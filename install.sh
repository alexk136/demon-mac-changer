#!/usr/bin/env bash
#
# install.sh — install demon-mac to system locations.
# Requires root. Idempotent: re-running is safe.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

require_root() {
    [[ $EUID -eq 0 ]] || { echo "install.sh requires root" >&2; exit 1; }
}

install_files() {
    install -m755 "$ROOT/demon-mac.sh" /usr/local/sbin/demon-mac
    if [[ ! -f /etc/demon-mac.conf ]]; then
        install -m644 "$ROOT/demon-mac.conf.example" /etc/demon-mac.conf
        echo "Installed /etc/demon-mac.conf (defaults: ENABLED=true, ROTATION_POLICY=connection)"
    else
        echo "Existing /etc/demon-mac.conf preserved"
    fi
    install -m644 "$ROOT/systemd/demon-mac-boot.service" /etc/systemd/system/demon-mac-boot.service
    install -m644 "$ROOT/systemd/demon-mac-rotate.service" /etc/systemd/system/demon-mac-rotate.service
    install -m644 "$ROOT/systemd/demon-mac-rotate.timer" /etc/systemd/system/demon-mac-rotate.timer
    install -m755 "$ROOT/networkmanager/99-demon-mac" /etc/NetworkManager/dispatcher.d/99-demon-mac

    # State directory — owned by root, mode 700
    mkdir -p -m 700 /var/lib/demon-mac
}

enable_unit() {
    systemctl daemon-reload
    systemctl enable demon-mac-boot.service
    systemctl enable demon-mac-rotate.timer
}

require_root
install_files
enable_unit
echo "install complete; reboot or restart NetworkManager to apply dispatcher hook"