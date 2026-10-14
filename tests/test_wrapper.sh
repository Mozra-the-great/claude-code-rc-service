#!/bin/sh
# Behaviour tests for claude-rc-run, the wrapper the systemd unit starts.
#
# Contract (read from the script):
#   - CLAUDE_RC_WORKDIR (default $HOME/work) must exist, else exit 1 + message.
#   - ~/.claude/.credentials.json must be readable, else exit 78 (EX_CONFIG) + message.
#     The work directory is checked first.
#   - argv is `rc`, then `--name $CLAUDE_RC_NAME` if set, then $CLAUDE_RC_FLAGS
#     word-split.
#   - CLAUDE_RC_PTY=on  -> exec `script -qe -c "<CLAUDE_BIN and argv>" /dev/null`
#     anything else    -> exec "$CLAUDE_BIN" <argv> directly.
#   - exec: the exit status of the child is the exit status of the wrapper.
# The real `claude` and `script` are never called: both are stubs that print their
# arguments, one `ARG:<value>` line each.

# shellcheck source=/dev/null  # tests/lib.sh, linted on its own
. "$(dirname -- "$0")/lib.sh"

WRAPPER=$ROOT/claude-rc-run
STUB_DIR=$TEST_TMP/bin
mkdir -p "$STUB_DIR"

cat > "$STUB_DIR/claude-stub" <<'STUB'
#!/bin/sh
echo "PWD:$(pwd)"
for a in "$@"; do
  printf 'ARG:%s\n' "$a"
done
exit "${STUB_EXIT:-0}"
STUB
cat > "$STUB_DIR/script" <<'STUB'
#!/bin/sh
echo "SCRIPT-CALLED"
for a in "$@"; do
  printf 'ARG:%s\n' "$a"
done
exit "${STUB_EXIT:-0}"
STUB
chmod +x "$STUB_DIR/claude-stub" "$STUB_DIR/script"
CLAUDE_STUB=$STUB_DIR/claude-stub

WORKDIR=$HOME/work
mkdir -p "$WORKDIR" "$HOME/.claude"
echo '{}' > "$HOME/.claude/.credentials.json"

# run_wrapper [VAR=value ...]: runs the wrapper with the stubs first on PATH and only
# the given variables set. Sets OUT (stdout), ERR (stderr) and RC.
run_wrapper() {
  OUT=$(env PATH="$STUB_DIR:$PATH" "$@" "$TEST_SH" "$WRAPPER" 2> "$TEST_TMP/err")
  RC=$?
  ERR=$(cat "$TEST_TMP/err")
}

# args_of <output>: the ARG: lines joined with '|' (rc|--name|x ...)
args_of() {
  printf '%s\n' "$1" | sed -n 's/^ARG://p' | tr '\n' '|' | sed 's/|$//'
}

# ── guard rails ──────────────────────────────────────────────────────────────
run_wrapper CLAUDE_BIN="$CLAUDE_STUB" CLAUDE_RC_WORKDIR="$TEST_TMP/missing"
assert_eq "missing work dir: exit 1" "1" "$RC"
assert_contains "missing work dir: message" "$ERR" "work directory does not exist: $TEST_TMP/missing"
assert_eq "missing work dir: claude not started" "" "$OUT"

# the work directory is checked before the credentials
mv "$HOME/.claude/.credentials.json" "$TEST_TMP/creds.saved"
run_wrapper CLAUDE_BIN="$CLAUDE_STUB" CLAUDE_RC_WORKDIR="$TEST_TMP/missing"
assert_eq "missing work dir and credentials: exit 1 wins" "1" "$RC"

run_wrapper CLAUDE_BIN="$CLAUDE_STUB"
assert_eq "missing credentials: exit 78 (EX_CONFIG)" "78" "$RC"
assert_contains "missing credentials: message" "$ERR" "not logged in"
assert_contains "missing credentials: names the binary to log in with" "$ERR" "$CLAUDE_STUB"
assert_eq "missing credentials: claude not started" "" "$OUT"

mv "$TEST_TMP/creds.saved" "$HOME/.claude/.credentials.json"

# ── argv ─────────────────────────────────────────────────────────────────────
run_wrapper CLAUDE_BIN="$CLAUDE_STUB"
assert_eq "defaults: exit 0" "0" "$RC"
assert_eq "defaults: argv is just 'rc'" "rc" "$(args_of "$OUT")"
assert_not_contains "defaults: no pty shim" "$OUT" "SCRIPT-CALLED"
assert_contains "defaults: runs in \$HOME/work" "$OUT" "PWD:$(cd "$WORKDIR" && pwd)"

CUSTOM=$TEST_TMP/elsewhere
mkdir -p "$CUSTOM"
run_wrapper CLAUDE_BIN="$CLAUDE_STUB" CLAUDE_RC_WORKDIR="$CUSTOM"
assert_contains "CLAUDE_RC_WORKDIR: runs there" "$OUT" "PWD:$(cd "$CUSTOM" && pwd)"

run_wrapper CLAUDE_BIN="$CLAUDE_STUB" CLAUDE_RC_NAME=my-server
assert_eq "CLAUDE_RC_NAME is passed as --name" "rc|--name|my-server" "$(args_of "$OUT")"

run_wrapper CLAUDE_BIN="$CLAUDE_STUB" "CLAUDE_RC_NAME=name with spaces"
assert_eq "CLAUDE_RC_NAME with spaces stays one argument" "rc|--name|name with spaces" "$(args_of "$OUT")"

run_wrapper CLAUDE_BIN="$CLAUDE_STUB" CLAUDE_RC_NAME=
assert_eq "empty CLAUDE_RC_NAME adds nothing" "rc" "$(args_of "$OUT")"

run_wrapper CLAUDE_BIN="$CLAUDE_STUB" "CLAUDE_RC_FLAGS=--spawn=worktree --capacity 8"
assert_eq "CLAUDE_RC_FLAGS is word-split" "rc|--spawn=worktree|--capacity|8" "$(args_of "$OUT")"

run_wrapper CLAUDE_BIN="$CLAUDE_STUB" CLAUDE_RC_NAME=box "CLAUDE_RC_FLAGS=--spawn=worktree"
assert_eq "name comes before the extra flags" "rc|--name|box|--spawn=worktree" "$(args_of "$OUT")"

run_wrapper CLAUDE_BIN="$CLAUDE_STUB" "CLAUDE_RC_FLAGS=--spawn=*"
assert_eq "flags are not glob-expanded" "rc|--spawn=*" "$(args_of "$OUT")"

# ── pseudo-terminal shim ─────────────────────────────────────────────────────
run_wrapper CLAUDE_BIN="$CLAUDE_STUB" CLAUDE_RC_PTY=off
assert_not_contains "PTY=off: no script shim" "$OUT" "SCRIPT-CALLED"
assert_eq "PTY=off: argv" "rc" "$(args_of "$OUT")"

# only the exact value "on" enables the shim
for v in ON 1 yes true; do
  run_wrapper CLAUDE_BIN="$CLAUDE_STUB" CLAUDE_RC_PTY="$v"
  assert_not_contains "PTY=$v is not 'on': no script shim" "$OUT" "SCRIPT-CALLED"
done

run_wrapper CLAUDE_BIN="$CLAUDE_STUB" CLAUDE_RC_PTY=on
assert_contains "PTY=on: script is started" "$OUT" "SCRIPT-CALLED"
assert_eq "PTY=on: script -qe -c '<command line>' /dev/null" "-qe|-c|$CLAUDE_STUB rc |/dev/null" "$(args_of "$OUT")"
assert_not_contains "PTY=on: claude is not started directly" "$OUT" "PWD:"

run_wrapper CLAUDE_BIN="$CLAUDE_STUB" CLAUDE_RC_PTY=on CLAUDE_RC_NAME=box "CLAUDE_RC_FLAGS=--spawn=worktree --capacity 8"
assert_eq "PTY=on: name and flags land in the command line" \
  "-qe|-c|$CLAUDE_STUB rc --name box --spawn=worktree --capacity 8 |/dev/null" "$(args_of "$OUT")"

# ── exit status is the child's (exec) ────────────────────────────────────────
run_wrapper CLAUDE_BIN="$CLAUDE_STUB" STUB_EXIT=7
assert_eq "exit status of claude is propagated" "7" "$RC"

run_wrapper CLAUDE_BIN="$CLAUDE_STUB" CLAUDE_RC_PTY=on STUB_EXIT=9
assert_eq "exit status of script is propagated" "9" "$RC"

# a missing binary fails loudly instead of looping silently
run_wrapper CLAUDE_BIN="$TEST_TMP/no-such-claude"
if [ "$RC" -ne 0 ]; then pass; else fail "missing CLAUDE_BIN: expected a non-zero exit"; fi

finish "test_wrapper"
