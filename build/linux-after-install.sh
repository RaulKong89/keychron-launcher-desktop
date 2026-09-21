#!/bin/sh
# Runs as postinst (deb), %post (rpm), post_install (pacman) via electron-builder/fpm.
# Self-contained on purpose: package managers place files at different install
# roots (/opt/<name> varies by target), so this writes the rule directly
# instead of copying it from the app's install directory.
set -e

RULE_FILE="/usr/lib/udev/rules.d/99-keychron.rules"

cat > "$RULE_FILE" << 'EOF'
# Keychron Launcher WebHID permissions
# Grants userspace access to /dev/hidraw for all Keychron devices
# (keyboards, mice, 2.4G receivers) and the STM32 bootloader used for
# firmware flashing.

# Keychron devices: keyboards, mice, 2.4G receivers (vendor 0x3434)
KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="3434", MODE="0666", GROUP="users", TAG+="uaccess", TAG+="udev-acl"

# STM32 bootloader mode (firmware flashing)
SUBSYSTEM=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="df11", MODE="0666", GROUP="users", TAG+="uaccess", TAG+="udev-acl"

# All Keychron USB devices, including every Link receiver product ID.
SUBSYSTEM=="usb", ATTRS{idVendor}=="3434", MODE="0666", GROUP="users", TAG+="uaccess", TAG+="udev-acl"
EOF

chmod 644 "$RULE_FILE"

# Some RPM-based distros (Fedora, RHEL) run SELinux enforcing by default and
# silently ignore udev rule files with the wrong context if they were not
# written through the RPM database's own file list.
if command -v restorecon >/dev/null 2>&1; then
  restorecon "$RULE_FILE" >/dev/null 2>&1 || true
fi

if command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload-rules >/dev/null 2>&1 || true
  udevadm trigger >/dev/null 2>&1 || true
fi

exit 0
