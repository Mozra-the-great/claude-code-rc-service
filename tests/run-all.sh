#!/bin/sh
# Run every test. Usage: sh tests/run-all.sh

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
status=0
for t in "$dir"/test_*.sh; do
  echo "== $(basename "$t")"
  sh "$t" || status=1
done
[ "$status" -eq 0 ] && echo "all suites passed"
exit "$status"
