#!/bin/sh
# Install the claude-rc systemd service. Idempotent - safe to re-run.
#
# Usage: sudo ./install.sh [--user NAME] [--workdir PATH] [--no-create-user]

set -eu

SERVICE_USER=claude
WORKDIR=
CREATE_USER=yes

while [ $# -gt 0 ]; do
  case "$1" in
    --user) SERVICE_USER=$2; shift 2 ;;
    --workdir) WORKDIR=$2; shift 2 ;;
    --no-create-user) CREATE_USER=no; shift ;;
    -h|--help) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "install.sh: must run as root" >&2; exit 1; }

# CDPATH must be empty, otherwise `cd` may print and jump somewhere else.
# Assigned on its own line rather than as a `CDPATH= cd ...` prefix, because
# SC1007 flags that prefix form as a likely typo.
CDPATH=''
src_dir=$(cd -- "$(dirname -- "$0")" && pwd)

for dep in systemctl install useradd; do
  command -v "$dep" >/dev/null 2>&1 || { echo "install.sh: missing dependency: $dep" >&2; exit 1; }
done

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  if [ "$CREATE_USER" = no ]; then
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

install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "$WORKDIR"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0700 "$home_dir/.claude"

install -m 0755 "$src_dir/claude-rc-run" /usr/local/bin/claude-rc-run

if [ ! -f /etc/default/claude-rc ]; then
  install -m 0644 "$src_dir/claude-rc.env.example" /etc/default/claude-rc
  echo "install.sh: wrote /etc/default/claude-rc (all values commented out)"
fi

sed \
  -e "s|@USER@|$SERVICE_USER|g" \
  -e "s|@HOME@|$home_dir|g" \
  -e "s|@WORKDIR@|$WORKDIR|g" \
  "$src_dir/claude-rc.service.in" > /etc/systemd/system/claude-rc.service
chmod 0644 /etc/systemd/system/claude-rc.service

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
