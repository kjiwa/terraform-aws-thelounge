#!/bin/sh
# Assertion helpers for the script tests. Sourced by each test file.
# shellcheck shell=sh

FAILURES=0

assert_eq() {
  if [ "$2" != "$3" ]; then
    echo "FAIL: $1: expected '$2', got '$3'" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# assert_status NAME EXPECTED COMMAND...
assert_status() {
  _assert_name="$1"
  _assert_want="$2"
  shift 2
  _assert_got=0
  "$@" >/dev/null 2>&1 || _assert_got=$?
  assert_eq "$_assert_name" "$_assert_want" "$_assert_got"
}

finish() {
  [ "$FAILURES" -eq 0 ] || exit 1
  echo "ok"
}
