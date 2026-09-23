# checkmk-agent-legacy-init

How to get the [Checkmk](https://checkmk.com) monitoring agent running on Linux hosts that don't have `systemd` — old Ubuntu 12.04/14.04 boxes, minimal containers, or anything with an init system Checkmk's modern Agent Controller doesn't support.

## Why

Checkmk's official installer assumes `systemd` 219+. If you're still keeping a handful of ancient hosts alive (which happens more often than anyone likes to admit in a long-lived server fleet), the installer just doesn't work — you need **legacy mode**, which runs the agent as a plain script served over `xinetd` instead of through the Agent Controller.

This repo is the condensed, copy-pasteable version of Checkmk's own [legacy mode documentation](https://docs.checkmk.com/latest/en/agent_linux_legacy.html), plus a small install script that automates it.

## What legacy mode is (and isn't)

- **Is**: the agent runs as a script, served on TCP port 6556 by `xinetd` (or another super-server), no Agent Controller, no registration.
- **Isn't**: encrypted. Legacy mode has no pull/push encryption — either restrict `xinetd`'s `only_from` to your Checkmk server's IP, or tunnel over SSH instead (see [the official docs](https://docs.checkmk.com/latest/en/agent_linux_legacy.html) for the SSH tunnel approach if that matters for your setup).

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
sudo ./install.sh check_mk_agent.linux
```

## Source

Steps condensed from Checkmk's own [Monitoring Linux in legacy mode](https://docs.checkmk.com/latest/en/agent_linux_legacy.html) documentation — this repo doesn't add new technique, just a faster path to it for anyone hitting the same "why won't this install" wall.

## License

MIT
