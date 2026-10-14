#!/bin/sh
# Remove the claude-rc systemd service.
#
# Leaves the service user, its home and /etc/default/claude-rc alone - those
# hold credentials and work in progress, so removing them is a manual decision.
#
# Usage: sudo ./uninstall.sh
#        ./uninstall.sh --destdir DIR    (remove what `install.sh --destdir DIR` staged)

set -eu

DESTDIR=
case "${1:-}" in
  --destdir) DESTDIR=$2 ;;
  "") ;;
  -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "uninstall.sh: unknown argument: $1" >&2; exit 2 ;;
esac

[ -n "$DESTDIR" ] || [ "$(id -u)" -eq 0 ] || { echo "uninstall.sh: must run as root" >&2; exit 1; }

if [ -z "$DESTDIR" ] && systemctl list-unit-files claude-rc.service >/dev/null 2>&1; then
  systemctl disable --now claude-rc.service 2>/dev/null || true
fi

rm -f "$DESTDIR/etc/systemd/system/claude-rc.service"
rm -f "$DESTDIR/usr/local/bin/claude-rc-run"
if [ -z "$DESTDIR" ]; then
  systemctl daemon-reload
  systemctl reset-failed claude-rc.service 2>/dev/null || true
fi

cat <<'EOF'
Removed the unit and /usr/local/bin/claude-rc-run.

Left in place on purpose:
  /etc/default/claude-rc    - your configuration
  the service user and its home, including ~/.claude/.credentials.json
EOF
