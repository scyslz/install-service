# install-service

Turn any long-running command into a **boot-time systemd service** — system-wide or per-user — with one command.

No config files to hand-write, no hardcoded paths: it resolves the binary, builds a sane `PATH`
(including version-manager dirs from your login shell), and handles the unit for you.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/scyslz/install-service/main/install-service.sh \
  | sudo bash -s -- -n paseo -d "Paseo Daemon" -- paseo daemon run
```

> When piping to bash, pass script arguments after `-s --` so they reach the script, not curl.

Or copy the script and run it directly:

```bash
sudo bash install-service.sh -n <name> [options] -- <command> [args...]
```

## Examples

```bash
# system-wide service (starts at boot, no login needed)
sudo bash install-service.sh -n paseo -d "Paseo Daemon" -- paseo daemon run

# any other program
sudo bash install-service.sh -n myapi -u deploy -- /opt/bin/myapi --port 8080
sudo bash install-service.sh -n worker -- node /srv/app/worker.js

# per-user service (starts on login)
bash install-service.sh --user -n paseo -l ~/.paseo/daemon.out -- paseo daemon run
sudo loginctl enable-linger "$USER"   # optional: start at boot without login

# preview the generated unit without installing (works without root)
bash install-service.sh --print -n paseo -u "$USER" -- paseo daemon run
```

## Options

| Flag | Meaning |
| --- | --- |
| `-n, --name NAME` | service name (required) |
| `-d, --desc TEXT` | `Description=` text |
| `--user` | install a per-user unit instead of a system unit |
| `-u, --run-as USER` | account to run as (system units; default `$SUDO_USER`) |
| `-w, --workdir DIR` | `WorkingDirectory=` (default: that user's home) |
| `-e, --env-file FILE` | `EnvironmentFile=` (repeatable) |
| `--env K=V` | `Environment=` entry (repeatable) |
| `-l, --log FILE` | append stdout/stderr to `FILE` (systemd 240+) |
| `-r, --reload-cmd CMD` | `ExecReload=` command |
| `--restart POLICY` | `Restart=` (default `always`) |
| `--restart-sec N` | `RestartSec=` (default `10`) |
| `--after UNIT` | `After=` (repeatable; default `network-online.target`) |
| `--wants UNIT` | `Wants=` (repeatable; default `network-online.target`) |
| `--no-start` | write + enable only, don't start now |
| `--print` | print the generated unit and exit (no root needed) |
| `-- CMD...` | the command to run (everything after `--`) |

## What it does

- Resolves a bare command name to its absolute path.
- Builds `PATH` from the binary's directory plus the target user's login-shell `PATH`, so tools from
  `nvm`/`mise`/`asdf`/etc. are found (the usual "works in my terminal but not under systemd" trap).
- Writes `/etc/systemd/system/<name>.service` (or `~/.config/systemd/user/<name>.service`).
- Disables a conflicting unit in the other scope, then `daemon-reload` + `enable` (+ `--now`).

## License

MIT
