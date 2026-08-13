#!/bin/sh
# Remove the claude-rc systemd service.
#
# Leaves the service user, its home and /etc/default/claude-rc alone - those
# hold credentials and work in progress, so removing them is a manual decision.

set -eu

[ "$(id -u)" -eq 0 ] || { echo "uninstall.sh: must run as root" >&2; exit 1; }

if systemctl list-unit-files claude-rc.service >/dev/null 2>&1; then
  systemctl disable --now claude-rc.service 2>/dev/null || true
fi

rm -f /etc/systemd/system/claude-rc.service
rm -f /usr/local/bin/claude-rc-run
systemctl daemon-reload
systemctl reset-failed claude-rc.service 2>/dev/null || true

cat <<'EOF'
Removed the unit and /usr/local/bin/claude-rc-run.

Left in place on purpose:
  /etc/default/claude-rc    - your configuration
  the service user and its home, including ~/.claude/.credentials.json
EOF
