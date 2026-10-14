#!/bin/sh
# Smoke tests for install.sh / uninstall.sh via --destdir, which stages the files
# under a temp dir instead of the live system.
#
# Contract: with --destdir DIR the scripts need no root, do not create users or
# directories, never call systemctl/useradd, and write
#   DIR/usr/local/bin/claude-rc-run       (the wrapper, executable)
#   DIR/etc/default/claude-rc             (env example, never overwritten)
#   DIR/etc/systemd/system/claude-rc.service (the unit with @USER@/@HOME@/@WORKDIR@ filled in)
# The service user must already exist; its home comes from `getent passwd`.
#
# systemctl, useradd and getent are stubs on PATH: the first two fail the test if
# they are ever called, getent answers with a fixed home so the expected unit
# content does not depend on the machine running the test.

# shellcheck source=/dev/null  # tests/lib.sh, linted on its own
. "$(dirname -- "$0")/lib.sh"

INSTALL=$ROOT/install.sh
UNINSTALL=$ROOT/uninstall.sh
STUB_DIR=$TEST_TMP/bin
CALL_LOG=$TEST_TMP/forbidden-calls.log
DESTDIR=$TEST_TMP/stage
FAKE_HOME=/home/svc-test
SVC_USER=$(id -un)

mkdir -p "$STUB_DIR"
for cmd in systemctl useradd; do
  cat > "$STUB_DIR/$cmd" <<STUB
#!/bin/sh
echo "$cmd \$*" >> "$CALL_LOG"
exit 1
STUB
  chmod +x "$STUB_DIR/$cmd"
done
cat > "$STUB_DIR/getent" <<STUB
#!/bin/sh
# getent passwd <user>
echo "\$2:x:1000:1000::$FAKE_HOME:/bin/sh"
STUB
chmod +x "$STUB_DIR/getent"
PATH=$STUB_DIR:$PATH
export PATH

# run_script <script> [args...] -> OUT (stdout+stderr), RC
run_script() {
  script=$1
  shift
  OUT=$("$TEST_SH" "$script" "$@" 2>&1)
  RC=$?
}

# forbidden_calls -> the systemctl/useradd invocations seen so far
forbidden_calls() {
  if [ -f "$CALL_LOG" ]; then cat "$CALL_LOG"; fi
}

unit=$DESTDIR/etc/systemd/system/claude-rc.service
wrapper=$DESTDIR/usr/local/bin/claude-rc-run
envfile=$DESTDIR/etc/default/claude-rc

# ── argument handling ────────────────────────────────────────────────────────
run_script "$INSTALL" --help
assert_eq "install --help: exit 0" "0" "$RC"
assert_contains "install --help: documents --destdir" "$OUT" "--destdir"

run_script "$INSTALL" --bogus
assert_eq "install: unknown argument exits 2" "2" "$RC"
assert_contains "install: unknown argument message" "$OUT" "unknown argument: --bogus"

run_script "$UNINSTALL" --help
assert_eq "uninstall --help: exit 0" "0" "$RC"
assert_contains "uninstall --help: documents --destdir" "$OUT" "--destdir"

run_script "$UNINSTALL" --bogus
assert_eq "uninstall: unknown argument exits 2" "2" "$RC"

# without --destdir both scripts insist on root (skipped when the tests run as root)
if [ "$(id -u)" -ne 0 ]; then
  run_script "$INSTALL" --user "$SVC_USER"
  assert_eq "install: non-root without --destdir exits 1" "1" "$RC"
  assert_contains "install: non-root message" "$OUT" "must run as root"
  run_script "$UNINSTALL"
  assert_eq "uninstall: non-root without --destdir exits 1" "1" "$RC"
  assert_contains "uninstall: non-root message" "$OUT" "must run as root"
fi

# ── staged install ───────────────────────────────────────────────────────────
run_script "$INSTALL" --destdir "$DESTDIR" --user "$SVC_USER"
assert_eq "staged install: exit 0" "0" "$RC"
assert_contains "staged install: says so" "$OUT" "staged"
assert_file "staged install: wrapper" "$wrapper"
assert_file "staged install: env file" "$envfile"
assert_file "staged install: unit" "$unit"
if [ -x "$wrapper" ]; then pass; else fail "staged install: wrapper is not executable"; fi
if cmp -s "$ROOT/claude-rc-run" "$wrapper"; then pass; else fail "staged install: wrapper differs from the source"; fi
if cmp -s "$ROOT/claude-rc.env.example" "$envfile"; then pass; else fail "staged install: env file differs from the example"; fi

unit_text=$(cat "$unit")
assert_contains "unit: User=" "$unit_text" "User=$SVC_USER"
assert_contains "unit: WorkingDirectory defaults to ~/work" "$unit_text" "WorkingDirectory=$FAKE_HOME/work"
assert_contains "unit: HOME" "$unit_text" "Environment=HOME=$FAKE_HOME"
assert_contains "unit: ReadWritePaths is the home" "$unit_text" "ReadWritePaths=$FAKE_HOME"
assert_contains "unit: ExecStart is the installed wrapper" "$unit_text" "ExecStart=/usr/local/bin/claude-rc-run"
assert_contains "unit: reads /etc/default/claude-rc" "$unit_text" "EnvironmentFile=-/etc/default/claude-rc"
assert_eq "unit: no unresolved placeholder" "" "$(printf '%s\n' "$unit_text" | grep -o '@[A-Z_]*@' | sort -u | tr '\n' ' ' | sed 's/ $//')"
assert_eq "staged install: systemctl/useradd never called" "" "$(forbidden_calls)"

# the template only uses placeholders install.sh knows how to fill
placeholders=$(grep -o '@[A-Z_]*@' "$ROOT/claude-rc.service.in" | sort -u | tr '\n' ' ' | sed 's/ $//')
assert_eq "template placeholders are exactly @HOME@, @USER@, @WORKDIR@" "@HOME@ @USER@ @WORKDIR@" "$placeholders"

# --workdir
run_script "$INSTALL" --destdir "$DESTDIR" --user "$SVC_USER" --workdir /srv/claude-work
assert_eq "--workdir: exit 0" "0" "$RC"
assert_contains "--workdir: lands in the unit" "$(cat "$unit")" "WorkingDirectory=/srv/claude-work"

# idempotent, and an edited env file is never overwritten
echo 'CLAUDE_RC_NAME=edited' > "$envfile"
run_script "$INSTALL" --destdir "$DESTDIR" --user "$SVC_USER"
assert_eq "re-install: exit 0" "0" "$RC"
assert_eq "re-install: edited env file kept" "CLAUDE_RC_NAME=edited" "$(cat "$envfile")"
assert_not_contains "re-install: does not claim to write the env file" "$OUT" "wrote"
assert_contains "re-install: unit is re-rendered" "$(cat "$unit")" "WorkingDirectory=$FAKE_HOME/work"

# the service user must exist; --destdir never creates it
rm -rf "$TEST_TMP/stage2"
run_script "$INSTALL" --destdir "$TEST_TMP/stage2" --user no-such-user-for-the-test
assert_eq "unknown user: exit 1" "1" "$RC"
assert_contains "unknown user: message" "$OUT" "does not exist"
assert_no_file "unknown user: nothing staged" "$TEST_TMP/stage2/usr/local/bin/claude-rc-run"
assert_eq "unknown user: useradd never called" "" "$(forbidden_calls)"

# ── staged uninstall ─────────────────────────────────────────────────────────
run_script "$UNINSTALL" --destdir "$DESTDIR"
assert_eq "staged uninstall: exit 0" "0" "$RC"
assert_no_file "staged uninstall: unit removed" "$unit"
assert_no_file "staged uninstall: wrapper removed" "$wrapper"
assert_file "staged uninstall: env file kept (configuration)" "$envfile"
assert_contains "staged uninstall: says what stays" "$OUT" "Left in place on purpose"

run_script "$UNINSTALL" --destdir "$DESTDIR"
assert_eq "staged uninstall twice: exit 0" "0" "$RC"
assert_eq "staged uninstall: systemctl never called" "" "$(forbidden_calls)"

finish "test_install"
