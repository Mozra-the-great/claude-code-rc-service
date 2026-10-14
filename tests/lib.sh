#!/bin/sh
# Shared helpers for the tests. Sourced, never executed on its own.
#
# Safety: nothing here may touch the host. Sourcing this file repoints HOME at a
# throw-away dir and clears every CLAUDE_* setting that could leak in from the
# environment. The real `claude` binary is never called (tests pass a stub as
# CLAUDE_BIN); install.sh only ever runs with --destdir.

# shellcheck disable=SC2034  # used by the sourcing test files
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# Shell that runs the scripts under test (they are #!/bin/sh POSIX).
TEST_SH=${TEST_SH:-sh}

TEST_TMP=$(mktemp -d)
HOME=$TEST_TMP/home
export HOME
unset CLAUDE_BIN CLAUDE_RC_WORKDIR CLAUDE_RC_NAME CLAUDE_RC_FLAGS CLAUDE_RC_PTY
mkdir -p "$HOME"
trap 'rm -rf "$TEST_TMP"' EXIT
trap 'exit 130' INT TERM

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1" >&2
}

# assert_eq <name> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then
    pass
  else
    fail "$1: expected '$2', got '$3'"
  fi
}

# assert_contains <name> <haystack> <needle>
assert_contains() {
  case "$2" in
    *"$3"*) pass ;;
    *) fail "$1: expected to contain '$3', got '$2'" ;;
  esac
}

# assert_not_contains <name> <haystack> <needle>
assert_not_contains() {
  case "$2" in
    *"$3"*) fail "$1: expected NOT to contain '$3', got '$2'" ;;
    *) pass ;;
  esac
}

# assert_file <name> <path>      assert_no_file <name> <path>
assert_file() {
  if [ -e "$2" ]; then pass; else fail "$1: missing $2"; fi
}
assert_no_file() {
  if [ -e "$2" ] || [ -L "$2" ]; then fail "$1: unexpected $2"; else pass; fi
}

# finish <suite name>: print the result and exit non-zero on any failure
finish() {
  if [ "$FAIL" -gt 0 ]; then
    echo "$1: $FAIL failed, $PASS passed" >&2
    exit 1
  fi
  echo "$1: $PASS passed"
}
