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
XINETD_TEMPLATE="$SCRIPT_DIR/check-mk-agent.xinetd"
AGENT_DEST=/usr/bin/check_mk_agent
XINETD_DEST=/etc/xinetd.d/check-mk-agent
CHANGED=0

# Preflight: fail early with an actionable message instead of a cryptic error
# halfway through the install.
if ! command -v service >/dev/null 2>&1; then
  echo "The 'service' command was not found; this installer needs a SysV-style init (or the 'service' wrapper)." >&2
  echo "Install the init scripts package or restart xinetd manually after copying the files." >&2
  exit 1
fi
if [ ! -x /usr/sbin/xinetd ] && ! command -v xinetd >/dev/null 2>&1; then
  echo "xinetd is not installed. Install it first, e.g.: apt-get install xinetd" >&2
  exit 1
fi
if [ ! -f "$XINETD_TEMPLATE" ]; then
  echo "Missing xinetd template next to install.sh: $XINETD_TEMPLATE" >&2
  exit 1
fi
# The agent must be a script (shebang), not an HTML error page or empty file.
if [ "$(head -c 2 "$AGENT_SCRIPT")" != "#!" ]; then
  echo "$AGENT_SCRIPT does not look like the agent script (no '#!' shebang on the first line)." >&2
  exit 1
fi

TMPDIR_INSTALL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_INSTALL"' EXIT INT TERM

# install_file <src> <dest> <mode>: copy only when content or mode differs,
# keeping a .bak of whatever was there before. Sets CHANGED=1 if it wrote.
install_file() {
  src="$1"; dest="$2"; mode="$3"
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    chmod "$mode" "$dest"
    echo "    unchanged: $dest"
    return 0
  fi
  if [ -f "$dest" ]; then
    bak="$dest.bak"
    [ ! -e "$bak" ] || bak="$dest.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$dest" "$bak"
    echo "    backed up $dest -> $bak"
  fi
  cp "$src" "$dest"
  chmod "$mode" "$dest"
  echo "    installed: $dest"
  CHANGED=1
}

echo "==> Installing agent script to $AGENT_DEST"
install_file "$AGENT_SCRIPT" "$AGENT_DEST" 755

echo "==> Creating required directories"
mkdir -p /usr/lib/check_mk_agent /etc/check_mk /var/lib/check_mk_agent

echo "==> Installing xinetd service config"
XINETD_NEW="$TMPDIR_INSTALL/check-mk-agent"
cp "$XINETD_TEMPLATE" "$XINETD_NEW"
if [ -n "$ONLY_FROM" ]; then
  sed -i "s|^[[:space:]]*# only_from .*|        only_from      = $ONLY_FROM|" "$XINETD_NEW"
fi
if [ -n "$BIND_ADDR" ]; then
  sed -i "s|^[[:space:]]*# bind .*|        bind           = $BIND_ADDR|" "$XINETD_NEW"
fi
install_file "$XINETD_NEW" "$XINETD_DEST" 644

if ! grep -q "^checkmk-agent" /etc/services 2>/dev/null; then
  echo "==> Registering checkmk-agent in /etc/services"
  echo "checkmk-agent        6556/tcp   #Checkmk monitoring agent" >> /etc/services
fi

# xinetd listens on 6556 only if it is running with our config.
listener_up() {
  if command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | grep ':6556[[:space:]]' | grep -q xinetd
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tlnp 2>/dev/null | grep ':6556[[:space:]]' | grep -q xinetd
  else
    return 2
  fi
}

if [ "$CHANGED" -eq 1 ] || ! listener_up; then
  echo "==> Restarting xinetd"
  service xinetd restart
else
  echo "==> No changes; xinetd already serving 6556, not restarting"
fi

echo "==> Verifying"
tries=0
while :; do
  listener_up && rc=0 || rc=$?
  [ "$rc" -eq 0 ] && { echo "xinetd is listening on 6556"; break; }
  if [ "$rc" -eq 2 ]; then
    echo "WARNING: neither ss nor netstat found; cannot verify the listener" >&2
    break
  fi
  tries=$((tries + 1))
  if [ "$tries" -ge 10 ]; then
    echo "ERROR: xinetd is not listening on port 6556 — check xinetd logs (syslog) and $XINETD_DEST" >&2
    exit 1
  fi
  sleep 1
done

echo "==> Done. Test with: nc localhost 6556"
if [ "$INSECURE_ANY" -eq 1 ] && [ -z "$ONLY_FROM" ] && [ -z "$BIND_ADDR" ]; then
  echo "==> WARNING: installed with --insecure-any; the agent is reachable by every host."
fi
