#!/bin/sh
# Installs the Checkmk agent in legacy mode (xinetd-served, no systemd/Agent
# Controller required). See README.md for background and the manual steps
# this script automates.
#
# Usage: sudo ./install.sh <path-to-check_mk_agent.linux>
#
# Requires: xinetd already installed, and the agent script already
# downloaded from your Checkmk server (Setup > Agents > Linux).

set -e

AGENT_SCRIPT="$1"
if [ -z "$AGENT_SCRIPT" ] || [ ! -f "$AGENT_SCRIPT" ]; then
  echo "Usage: sudo ./install.sh <path-to-check_mk_agent.linux>" >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Must run as root." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Installing agent script to /usr/bin/check_mk_agent"
cp "$AGENT_SCRIPT" /usr/bin/check_mk_agent
chmod 755 /usr/bin/check_mk_agent

echo "==> Creating required directories"
mkdir -p /usr/lib/check_mk_agent /etc/check_mk /var/lib/check_mk_agent

echo "==> Installing xinetd service config"
cp "$SCRIPT_DIR/check-mk-agent.xinetd" /etc/xinetd.d/check-mk-agent

if ! grep -q "^checkmk-agent" /etc/services 2>/dev/null; then
  echo "==> Registering checkmk-agent in /etc/services"
  echo "checkmk-agent        6556/tcp   #Checkmk monitoring agent" >> /etc/services
fi

echo "==> Restarting xinetd"
service xinetd restart

echo "==> Verifying"
sleep 1
if command -v ss >/dev/null 2>&1; then
  ss -tulpn 2>/dev/null | grep -q 6556 && echo "xinetd is listening on 6556" || echo "WARNING: nothing listening on 6556 yet — check xinetd logs"
fi

echo "==> Done. Test with: nc localhost 6556"
echo "==> Remember to set only_from in /etc/xinetd.d/check-mk-agent if you're not using an SSH tunnel."
