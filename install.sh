#!/bin/sh
# Install the claude-rc systemd service. Idempotent - safe to re-run.
#
# Usage: sudo ./install.sh [--user NAME] [--workdir PATH] [--no-create-user]
#        ./install.sh --destdir DIR [--user NAME] [--workdir PATH]
#
# --destdir DIR stages the three installed files under DIR instead of the live
# system (for packaging and the tests): no root needed, no user or directories
# created, systemd untouched. The user must already exist, because the unit is
# rendered with its home directory.

set -eu

SERVICE_USER=claude
WORKDIR=
CREATE_USER=yes
DESTDIR=

while [ $# -gt 0 ]; do
  case "$1" in
    --user) SERVICE_USER=$2; shift 2 ;;
    --workdir) WORKDIR=$2; shift 2 ;;
    --no-create-user) CREATE_USER=no; shift ;;
    --destdir) DESTDIR=$2; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$DESTDIR" ] || [ "$(id -u)" -eq 0 ] || { echo "install.sh: must run as root" >&2; exit 1; }

# CDPATH must be empty, otherwise `cd` may print and jump somewhere else.
# Assigned on its own line rather than as a `CDPATH= cd ...` prefix, because
# SC1007 flags that prefix form as a likely typo.
CDPATH=''
src_dir=$(cd -- "$(dirname -- "$0")" && pwd)

if [ -n "$DESTDIR" ]; then deps="install"; else deps="systemctl install useradd"; fi
for dep in $deps; do
  command -v "$dep" >/dev/null 2>&1 || { echo "install.sh: missing dependency: $dep" >&2; exit 1; }
done

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  if [ "$CREATE_USER" = no ] || [ -n "$DESTDIR" ]; then
    echo "install.sh: user '$SERVICE_USER' does not exist" >&2
    exit 1
  fi
  # No sudo group on purpose: this account holds a Claude OAuth token and
  # accepts instructions from the internet.
  useradd --create-home --shell /bin/bash "$SERVICE_USER"
  echo "install.sh: created user '$SERVICE_USER' (no sudo)"
fi

home_dir=$(getent passwd "$SERVICE_USER" | cut -d: -f6)
[ -n "$home_dir" ] || { echo "install.sh: cannot determine home of '$SERVICE_USER'" >&2; exit 1; }
[ -n "$WORKDIR" ] || WORKDIR=$home_dir/work

if [ -n "$DESTDIR" ]; then
  install -d -m 0755 "$DESTDIR/usr/local/bin" "$DESTDIR/etc/default" "$DESTDIR/etc/systemd/system"
else
  install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "$WORKDIR"
  install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0700 "$home_dir/.claude"
fi

install -m 0755 "$src_dir/claude-rc-run" "$DESTDIR/usr/local/bin/claude-rc-run"

if [ ! -f "$DESTDIR/etc/default/claude-rc" ]; then
  install -m 0644 "$src_dir/claude-rc.env.example" "$DESTDIR/etc/default/claude-rc"
  echo "install.sh: wrote $DESTDIR/etc/default/claude-rc (all values commented out)"
fi

sed \
  -e "s|@USER@|$SERVICE_USER|g" \
  -e "s|@HOME@|$home_dir|g" \
  -e "s|@WORKDIR@|$WORKDIR|g" \
  "$src_dir/claude-rc.service.in" > "$DESTDIR/etc/systemd/system/claude-rc.service"
chmod 0644 "$DESTDIR/etc/systemd/system/claude-rc.service"

if [ -n "$DESTDIR" ]; then
  echo "install.sh: staged the wrapper, unit and env file under $DESTDIR (systemd untouched)"
  exit 0
fi

systemctl daemon-reload
systemctl enable claude-rc.service

cat <<EOF

Installed. The service is enabled but not started, because Claude Code needs an
interactive login first. As $SERVICE_USER, in $WORKDIR:

  1. claude            # log in with a subscription account, accept workspace trust
  2. exit
  3. systemctl start claude-rc

Then open claude.ai/code or the Claude mobile app and pick the session.

  systemctl status claude-rc
  journalctl -u claude-rc -f
EOF
