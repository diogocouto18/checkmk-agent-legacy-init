#!/bin/sh
# Smoke test, meant to run as root inside a disposable ubuntu container:
#   docker run --rm -v "$PWD:/src:ro" ubuntu:22.04 sh /src/tests/smoke.sh
set -eu

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xinetd netcat-openbsd iproute2 >/dev/null

# Minimal stand-in for the agent script downloaded from a Checkmk server.
printf '#!/bin/sh\necho "<<<check_mk>>>"\n' > /tmp/check_mk_agent.linux

echo "== run 1"
sh /src/install.sh --only-from 127.0.0.1 /tmp/check_mk_agent.linux

# -4: localhost may resolve to ::1 first, which an IPv4 only_from rejects
out="$(nc -4 -q1 localhost 6556 || true)"
case "$out" in
  *"<<<check_mk>>>"*) echo "agent output OK" ;;
  *) echo "FAIL: unexpected agent output: $out" >&2; exit 1 ;;
esac

echo "== run 2 (must be idempotent)"
sum1="$(cat /usr/bin/check_mk_agent /etc/xinetd.d/check-mk-agent | md5sum)"
second="$(sh /src/install.sh --only-from 127.0.0.1 /tmp/check_mk_agent.linux)"
echo "$second"
sum2="$(cat /usr/bin/check_mk_agent /etc/xinetd.d/check-mk-agent | md5sum)"
[ "$sum1" = "$sum2" ] || { echo "FAIL: files changed on second run" >&2; exit 1; }
case "$second" in
  *"No changes"*) ;;
  *) echo "FAIL: second run did not report 'No changes'" >&2; exit 1 ;;
esac
[ ! -e /usr/bin/check_mk_agent.bak ] || { echo "FAIL: unexpected .bak after no-op run" >&2; exit 1; }

echo "== refuses an input that is not a script"
echo "<html>" > /tmp/bad
if sh /src/install.sh --only-from 127.0.0.1 /tmp/bad; then
  echo "FAIL: installer accepted a non-script input" >&2
  exit 1
fi

echo "smoke test passed"
