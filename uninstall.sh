#!/bin/sh
# Removes what install.sh set up: the xinetd service file, the agent binary and
# the /etc/services entry, then restarts xinetd. Backups (*.bak) and the
# directories under /usr/lib/check_mk_agent, /etc/check_mk and
# /var/lib/check_mk_agent are left alone. Safe to run more than once.
#
# Usage: sudo ./uninstall.sh

set -e

if [ "$(id -u)" -ne 0 ]; then
  echo "Must run as root." >&2
  exit 1
fi

echo "==> Removing xinetd service config and agent binary"
rm -f /etc/xinetd.d/check-mk-agent /usr/bin/check_mk_agent

if grep -q "^checkmk-agent" /etc/services 2>/dev/null; then
  echo "==> Removing checkmk-agent from /etc/services"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT INT TERM
  grep -v "^checkmk-agent" /etc/services > "$tmp" || true
  cat "$tmp" > /etc/services
fi

if command -v service >/dev/null 2>&1; then
  echo "==> Restarting xinetd"
  service xinetd restart || echo "WARNING: could not restart xinetd; restart it manually" >&2
else
  echo "WARNING: 'service' not found; restart xinetd manually (/etc/init.d/xinetd restart)" >&2
fi

echo "==> Done."
