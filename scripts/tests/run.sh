#!/bin/sh
# Runs every scripts/tests/test_*.sh and fails if any fails.
set -eu

main() {
  _main_dir="$(
    unset CDPATH
    cd -- "$(dirname -- "$0")" && pwd
  )"
  _main_failed=0
  for _main_test in "$_main_dir"/test_*.sh; do
    echo "== $(basename "$_main_test")"
    sh "$_main_test" || _main_failed=1
  done
  return "$_main_failed"
}

main "$@"
