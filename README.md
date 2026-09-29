# checkmk-agent-legacy-init

How to get the [Checkmk](https://checkmk.com) monitoring agent running on Linux hosts that don't have `systemd` — old Ubuntu 12.04/14.04 boxes, minimal containers, or anything with an init system Checkmk's modern Agent Controller doesn't support.

## Why

Checkmk's official installer assumes `systemd` 219+. If you're still keeping a handful of ancient hosts alive (which happens more often than anyone likes to admit in a long-lived server fleet), the installer just doesn't work — you need **legacy mode**, which runs the agent as a plain script served over `xinetd` instead of through the Agent Controller.

This repo is the condensed, copy-pasteable version of Checkmk's own [legacy mode documentation](https://docs.checkmk.com/latest/en/agent_linux_legacy.html), plus a small install script that automates it.

## What legacy mode is (and isn't)

- **Is**: the agent runs as a script, served on TCP port 6556 by `xinetd` (or another super-server), no Agent Controller, no registration.
- **Isn't**: encrypted. Legacy mode has no pull/push encryption — either restrict `xinetd`'s `only_from` to your Checkmk server's IP, or tunnel over SSH instead (see [the official docs](https://docs.checkmk.com/latest/en/agent_linux_legacy.html) for the SSH tunnel approach if that matters for your setup).

## Supported distros and prerequisites

Tested means the installer was actually run there; untested means it should work (plain POSIX `sh`, xinetd, `ss` or `netstat`) but nobody has verified it.

| Distro | Status |
|---|---|
| Ubuntu 22.04 (container, xinetd 2.3.15) | Tested (install, second run, uninstall) |
| Ubuntu 12.04 / 14.04 | Untested by the maintainer on real hosts; the target audience, script is POSIX `sh` and avoids bashisms |
| Debian 7/8/9 | Untested |
| CentOS/RHEL 6 | Untested (`yum install xinetd`) |

Prerequisites (as root):

```bash
apt-get update && apt-get install -y xinetd netcat   # Debian/Ubuntu; netcat is only for the test
```

The scripts use `service xinetd restart`. If `service` is missing, use `/etc/init.d/xinetd restart` instead (manual steps below), and restart xinetd yourself after running the installer. Verification uses `ss`, falling back to `netstat`; if neither exists it warns and skips the listener check.

**Firewall**: port 6556/tcp must be reachable from your Checkmk server only. `only_from` is a second line of defence, not a substitute, e.g. `iptables -A INPUT -p tcp --dport 6556 -s <checkmk-server-ip> -j ACCEPT` followed by a `DROP` for the rest.

## Manual steps

1. **Get the agent script** from your Checkmk server (Setup → Agents → Linux):
   ```bash
   wget http://<your-checkmk-server>/<site>/check_mk/agents/check_mk_agent.linux
   ```
2. **Install it**:
   ```bash
   mv check_mk_agent.linux /usr/bin/check_mk_agent
   chmod 755 /usr/bin/check_mk_agent
   check_mk_agent | head   # sanity check
   ```
3. **Create the required directories**:
   ```bash
   mkdir -p /usr/lib/check_mk_agent /etc/check_mk /var/lib/check_mk_agent
   ```
4. **Configure xinetd** — copy [`check-mk-agent.xinetd`](./check-mk-agent.xinetd) to `/etc/xinetd.d/check-mk-agent`. Uncomment and set `only_from` to your Checkmk server's IP if you're not tunneling over SSH.
5. **Register the service** — add to `/etc/services`:
   ```
   checkmk-agent        6556/tcp   #Checkmk monitoring agent
   ```
6. **Restart xinetd**:
   ```bash
   service xinetd restart
   ```
7. **Verify**:
   ```bash
   ss -tulpn | grep 6556       # xinetd should be listening
   nc localhost 6556           # should print <<<check_mk>>> and agent output
   ```

## Or just run the script

[`install.sh`](./install.sh) does steps 2–6 for you (it still needs the agent script downloaded first, and `xinetd` already installed):

```bash
wget http://<your-checkmk-server>/<site>/check_mk/agents/check_mk_agent.linux
sudo ./install.sh --only-from <checkmk-server-ip> check_mk_agent.linux
```

The agent output (hostnames, processes, installed packages) is unauthenticated and unencrypted, so the installer **refuses to run** unless you say who may reach it:

| Option | Effect |
|---|---|
| `--only-from <ip[/cidr][,...]>` | Writes `only_from` into the xinetd config so only your Checkmk server(s) can connect. Also settable via the `CHECKMK_ALLOW_FROM` env var. |
| `--bind <ip>` | Writes `bind`, e.g. `--bind 127.0.0.1` to keep the agent loopback-only and reach it through an SSH tunnel. |
| `--insecure-any` | Explicitly accepts exposure to every host (prints a warning). |

Values are validated as IPv4 or IPv4/CIDR before anything on the system is touched.

Re-running the installer is safe: unchanged files are left alone (no restart), and files that differ are backed up to `*.bak` before being replaced. To upgrade the agent, download the new `check_mk_agent.linux` and run the installer again.

## Uninstall

```bash
sudo ./uninstall.sh
```

Or by hand:

```bash
rm -f /etc/xinetd.d/check-mk-agent /usr/bin/check_mk_agent
sed -i '/^checkmk-agent/d' /etc/services
service xinetd restart      # or: /etc/init.d/xinetd restart
```

`/usr/lib/check_mk_agent`, `/etc/check_mk`, `/var/lib/check_mk_agent` and any `*.bak` files are not removed.

## Troubleshooting

| Symptom | Check |
|---|---|
| Installer says xinetd is not installed | `apt-get install xinetd` |
| "not listening on port 6556" | Config syntax error or port taken: run `ss -tlnp \| grep 6556` and look at the syslog for `xinetd` |
| `nc localhost 6556` returns nothing | `only_from` blocks the connecting address. `localhost` may resolve to `::1`, which an IPv4 `only_from` rejects; try `nc -4 127.0.0.1 6556` |
| Works locally, Checkmk cannot connect | Firewall, or `only_from` does not include the Checkmk server's IP |
| Installer rejects the input file | The file must start with `#!`; a download error often saves an HTML page instead |

## Source

Steps condensed from Checkmk's own [Monitoring Linux in legacy mode](https://docs.checkmk.com/latest/en/agent_linux_legacy.html) documentation — this repo doesn't add new technique, just a faster path to it for anyone hitting the same "why won't this install" wall.

## License

MIT
