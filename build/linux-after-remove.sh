#!/bin/sh
# Runs as postrm (deb), %postun (rpm), post_remove (pacman).
set -e

rm -f /usr/lib/udev/rules.d/99-keychron.rules

if command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload-rules >/dev/null 2>&1 || true
  udevadm trigger >/dev/null 2>&1 || true
fi

exit 0
