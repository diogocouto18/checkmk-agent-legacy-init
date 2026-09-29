#!/bin/sh
# Installs the Checkmk agent in legacy mode (xinetd-served, no systemd/Agent
# Controller required). See README.md for background and the manual steps
# this script automates.
#
# Usage: sudo ./install.sh [--only-from <ip[/cidr]>[,<ip[/cidr]>...]]
#                          [--bind <ip>] [--insecure-any]
#                          <path-to-check_mk_agent.linux>
#
# The agent output is unauthenticated and unencrypted, so an install must say
# who may reach it: --only-from restricts xinetd to your Checkmk server(s)
# (or set CHECKMK_ALLOW_FROM), --bind 127.0.0.1 keeps it loopback-only for an
# SSH tunnel, and --insecure-any explicitly accepts exposure to every host.
#
# Requires: xinetd already installed, and the agent script already
# downloaded from your Checkmk server (Setup > Agents > Linux).

set -e

usage() {
  echo "Usage: sudo ./install.sh [--only-from <ip[/cidr],...>] [--bind <ip>] [--insecure-any] <path-to-check_mk_agent.linux>" >&2
}

is_ipv4() {
  # dotted quad with each octet 0-255
  case "$1" in
    *[!0-9.]*|""|.*|*.|*..*) return 1 ;;
  esac
  old_ifs="$IFS"; IFS=.
  set -- $1
  IFS="$old_ifs"
  [ "$#" -eq 4 ] || return 1
  for octet in "$@"; do
    [ "$octet" -le 255 ] || return 1
  done
}

is_ipv4_or_cidr() {
  case "$1" in
    */*)
      is_ipv4 "${1%%/*}" || return 1
      prefix="${1#*/}"
      case "$prefix" in *[!0-9]*|"") return 1 ;; esac
      [ "$prefix" -le 32 ]
      ;;
    *) is_ipv4 "$1" ;;
  esac
}

ONLY_FROM="${CHECKMK_ALLOW_FROM:-}"
BIND_ADDR=""
INSECURE_ANY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --only-from) [ "$#" -ge 2 ] || { usage; exit 1; }; ONLY_FROM="$2"; shift 2 ;;
    --bind)      [ "$#" -ge 2 ] || { usage; exit 1; }; BIND_ADDR="$2"; shift 2 ;;
    --insecure-any) INSECURE_ANY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *) break ;;
  esac
done

AGENT_SCRIPT="$1"
if [ -z "$AGENT_SCRIPT" ] || [ ! -f "$AGENT_SCRIPT" ]; then
  usage
  exit 1
fi

# Normalize to the space-separated list xinetd expects, validating every entry.
ONLY_FROM="$(echo "$ONLY_FROM" | tr ',' ' ')"
for entry in $ONLY_FROM; do
  if ! is_ipv4_or_cidr "$entry"; then
    echo "Invalid --only-from entry (expected IPv4 or IPv4/CIDR): $entry" >&2
    exit 1
  fi
done
if [ -n "$BIND_ADDR" ] && ! is_ipv4 "$BIND_ADDR"; then
  echo "Invalid --bind address (expected IPv4): $BIND_ADDR" >&2
  exit 1
fi

if [ -z "$ONLY_FROM" ] && [ -z "$BIND_ADDR" ] && [ "$INSECURE_ANY" -ne 1 ]; then
  echo "Refusing to install: the agent would be reachable by every host." >&2
  echo "Pass --only-from <checkmk-server-ip>, --bind 127.0.0.1 (SSH tunnel), or --insecure-any." >&2
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
if [ -n "$ONLY_FROM" ]; then
  sed -i "s|^[[:space:]]*# only_from .*|        only_from      = $ONLY_FROM|" /etc/xinetd.d/check-mk-agent
fi
if [ -n "$BIND_ADDR" ]; then
  sed -i "s|^[[:space:]]*# bind .*|        bind           = $BIND_ADDR|" /etc/xinetd.d/check-mk-agent
fi

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
if [ "$INSECURE_ANY" -eq 1 ] && [ -z "$ONLY_FROM" ] && [ -z "$BIND_ADDR" ]; then
  echo "==> WARNING: installed with --insecure-any; the agent is reachable by every host."
fi
