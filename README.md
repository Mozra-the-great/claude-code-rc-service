# claude-code-rc-service

Run [Claude Code](https://claude.com/claude-code) Remote Control (`claude rc`) as a
systemd service on a Linux host, so you can drive it from your phone or a browser
without leaving a terminal open.

`claude rc` is a persistent server: it accepts multiple concurrent sessions and keeps
running when a session ends. This repo wraps it in a unit that starts at boot, restarts
on crash, and keeps retrying through outages without hammering the API.

## Why a service

Running `claude rc` in a terminal means the sessions die with the terminal — closing SSH,
a reboot, or a dropped connection takes everything with it. A systemd unit survives all
three, which is what makes an always-available host you can reach from a phone actually
always available.

## How the phone connects

Outbound only. The host connects to Anthropic's service, and you pick the session up from
[claude.ai/code](https://claude.ai/code) or the Claude mobile app. There is nothing to
port-forward, no reverse proxy, and no VPN required — which also means this works fine
behind CGNAT or double NAT.

## Requirements

- Linux with systemd
- Claude Code installed and on `PATH`
- A Claude account **with a subscription** — `claude rc` refuses to start otherwise
- `util-linux` (for `script`) only if you enable the PTY shim, see below

## Install

```sh
git clone https://github.com/Mozra-the-great/claude-code-rc-service.git
cd claude-code-rc-service
sudo ./install.sh
```

Options: `--user NAME` (default `claude`), `--workdir PATH` (default `~/work`),
`--no-create-user`.

`install.sh` is idempotent. It creates the service user **without sudo** — the account
holds an OAuth token and takes instructions from the internet, so it should not be able
to escalate.

The service is enabled but deliberately **not started**, because Claude Code cannot be
authenticated non-interactively. Finish as the service user:

```sh
sudo -u claude -i
cd ~/work
claude          # log in, and accept the workspace trust prompt
claude rc       # answer the one-time "Enable Remote Control? (y/n)" with y, then Ctrl+C
exit
sudo systemctl start claude-rc
```

That third line matters. On its very first run `claude rc` asks **"Enable Remote
Control? (y/n)"**. With no terminal attached it reads EOF and exits *successfully*, so
the service restarts five times and lands in `failed` with no error message anywhere —
only that question in the journal. Answering it once persists the choice.

If you automate the host and cannot run it by hand, the answer is stored in
`~/.claude.json`; setting `remoteDialogSeen` and `hasUsedRemoteControl` to `true` there
before first start has the same effect. That is undocumented internal state, so prefer
the interactive route where you can.

Uninstall with `sudo ./uninstall.sh`. It removes the unit and the wrapper but leaves the
service user, its home and your config alone — those hold credentials and work in progress.

## Configuration

`/etc/default/claude-rc`, all optional. See `claude-rc.env.example` for the full list.

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_RC_WORKDIR` | `$HOME/work` | Directory Claude Code works in |
| `CLAUDE_RC_NAME` | hostname | Session name shown in the app |
| `CLAUDE_RC_FLAGS` | *(none)* | Extra flags, e.g. `--spawn=worktree` |
| `CLAUDE_RC_PTY` | `off` | Run under a pseudo-terminal |
| `CLAUDE_BIN` | `claude` | Path to the binary |

`systemctl restart claude-rc` after changing anything.

## Restart behaviour

`Restart=always` with `RestartSec=60` and `StartLimitIntervalSec=0`, so systemd never gives
up. After a network or API outage every start fails with a connect timeout; a start limit
would leave the unit in `failed` for good once the outage outlasts the burst, and nothing
would bring it back. The fixed 60 s pause keeps a persistent failure from turning into a
crash loop against the API. (Debian 12 ships systemd 252, which has no `RestartSteps`
for a growing back-off.)

A unit that keeps failing therefore shows up as `activating (auto-restart)` rather than
`failed`; watch `NRestarts` and the journal, not just the unit state.

Hitting a usage limit does **not** restart the service — the server stays up and only the
session inside it waits.

The wrapper exits `78` (`EX_CONFIG`) with a clear message if `~/.claude/.credentials.json`
is missing, so a not-logged-in host fails visibly instead of silently looping.

## Statusline and the rate-limit hook

If you also use
[claude-code-ratelimit-hook](https://github.com/Mozra-the-great/claude-code-ratelimit-hook),
be aware that it gets its data from the statusline command — that is the only place Claude
Code exposes rate-limit fields.

Measured on Debian 12: the statusline **does** run under this service with
`CLAUDE_RC_PTY=off`, no pseudo-terminal needed. `rate-limit-state.json` is written with
real percentages as soon as the server comes up.

It refreshes when a session renders, not on a timer — so during idle periods `updated_at`
stands still, and during actual work it tracks. That is fine for the hook, which only
needs current data at the moment it decides whether to block, and which treats a window
whose `resets_at` has passed as no longer blocking.

Check it with:

```sh
sudo -u claude cat ~claude/.claude/rate-limit-state.json
```

If the file never appears at all, first make sure `settings.json` actually declares a
`statusLine` command — an empty or default `settings.json` has none, and then there is
nothing to fire. Only after that is ruled out is `CLAUDE_RC_PTY=on` worth trying.

## Security notes

This host holds a Claude OAuth token in `~/.claude/.credentials.json`, and whoever can log
into that Claude account can drive the machine. Worth doing:

- keep the service user out of `sudo`
- enable 2FA on the Claude account — it is effectively part of this host's access control
- do not set `--permission-mode bypassPermissions` in `CLAUDE_RC_FLAGS`
- keep a `permissions.deny` list in `~/.claude/settings.json` for secrets and destructive
  commands
- do not store unrelated infrastructure credentials on this host

The unit applies `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=full`,
`ProtectHome=read-only` (with the service user's home as the one writable exception),
`ProtectControlGroups`, `ProtectKernelTunables` and `RestrictSUIDSGID`.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Exits `78` immediately | Not logged in — run `claude` interactively as the service user |
| Restarts every minute, journal ends on "Enable Remote Control? (y/n)" | The one-time prompt was never answered — see Install |
| Starts, but no session in the app | Workspace trust prompt not accepted yet |
| Stuck in `activating (auto-restart)` | Starts keep failing (outage, auth); `journalctl -u claude-rc` and `systemctl show claude-rc -p NRestarts` |
| `rate-limit-state.json` never updates | Try `CLAUDE_RC_PTY=on` |

Note that a clean exit code 0 is *not* proof things went well: the unanswered
first-run prompt exits successfully, which is exactly what makes it hard to spot.

```sh
systemctl status claude-rc
journalctl -u claude-rc -f
```

## License

GNU General Public License v3.0 — see [`LICENSE`](LICENSE).
