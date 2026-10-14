# claude-code-rc-service

## Type
Public repo: a POSIX `sh` wrapper (`claude-rc-run`), a systemd unit template
(`claude-rc.service.in`), `install.sh` / `uninstall.sh` and an env example. Runs
`claude rc` (Remote Control) as a service on a Linux host.

## Important
- Never run `install.sh` / `uninstall.sh` without `--destdir` on a dev machine: without it they
  need root and change the live system (user, /usr/local/bin, /etc, systemd).
- Never call the real `claude` in tests; use a stub as `CLAUDE_BIN`.
- Wrapper contract: exit 1 = work dir missing, exit 78 (`EX_CONFIG`) = not logged in.

## Commands
```sh
sh tests/run-all.sh                  # wrapper + install tests (no dependencies)
shellcheck --shell=sh install.sh uninstall.sh claude-rc-run tests/*.sh
```

## CI (`.github/workflows/`)
- `ci.yml`: jobs `shellcheck` (+ `systemd-analyze verify` of the rendered unit) and `test`;
  stable names, no path filter.
- `workflow-lint.yml`: actionlint + zizmor. `secret-scan.yml`: gitleaks on PRs.
- No Claude workflows by design. Actions pinned by SHA; Dependabot keeps them fresh.

## Conventions
- Conventional commits in English, feature branches, no direct pushes to `main`.
- A change to an exit code, the argv built by `claude-rc-run`, or a placeholder in the unit
  template must come with a matching change in `tests/`.
