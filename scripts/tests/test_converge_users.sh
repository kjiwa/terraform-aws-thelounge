#!/bin/sh
# Tests for install_new_users in thelounge-converge.sh. The script is sourced
# with THELOUNGE_CONVERGE_SOURCE_ONLY=1 so only its functions load.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly CONVERGE="$TESTS_DIR/../../build/app/instance/thelounge-converge.sh"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/thelounge-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
readonly HOME_DIR="$WORK/home"
readonly LIB="$WORK/lib"

# converge_users USERS_JSON: runs install_new_users against a fresh
# THELOUNGE_HOME; prints "restart=N".
converge_users() {
  rm -rf "$HOME_DIR" "$LIB"
  mkdir -p "$LIB"
  printf '%s' "$1" >"$LIB/users.json"
  env THELOUNGE_CONVERGE_SOURCE_ONLY=1 LIB_DIR="$LIB" THELOUNGE_HOME="$HOME_DIR" sh -c "
    set -eu
    . '$CONVERGE'
    install_new_users >/dev/null
    echo restart=\$RESTART_NEEDED"
}

test_creates_a_user_file() {
  _out="$(converge_users '{"alice":"hash-one"}')"
  assert_eq "restart is requested" "restart=1" "$_out"
  assert_eq "password" 'hash-one' "$(jq -r .password "$HOME_DIR/users/alice.json")"
  assert_eq "log" "true" "$(jq -r .log "$HOME_DIR/users/alice.json")"
}

test_hash_with_json_metacharacters_round_trips() {
  converge_users '{"alice":"a\"b\\c"}' >/dev/null
  assert_eq "password survives" 'a"b\c' "$(jq -r .password "$HOME_DIR/users/alice.json")"
}

test_unsafe_names_are_skipped() {
  _out="$(converge_users '{"../escape":"h","a/b":"h","-rf":"h",".hidden":"h","ok.name-1":"h","kamil@example.org":"h","a+b@x.io":"h"}')"
  assert_eq "only the safe names are created" "a+b@x.io.json kamil@example.org.json ok.name-1.json" \
    "$(find "$HOME_DIR/users" -type f -exec basename {} \; | sort | tr '\n' ' ' | sed 's/ $//')"
  assert_eq "nothing is written outside users/" "users" "$(ls "$HOME_DIR")"
  assert_eq "restart is requested" "restart=1" "$_out"
}

test_existing_user_is_left_alone() {
  converge_users '{"alice":"new"}' >/dev/null
  echo kept >"$HOME_DIR/users/alice.json"
  env THELOUNGE_CONVERGE_SOURCE_ONLY=1 LIB_DIR="$LIB" THELOUNGE_HOME="$HOME_DIR" sh -c "
    set -eu
    . '$CONVERGE'
    install_new_users >/dev/null
    echo restart=\$RESTART_NEEDED" >"$WORK/out"
  assert_eq "file is not overwritten" "kept" "$(cat "$HOME_DIR/users/alice.json")"
  assert_eq "no restart" "restart=0" "$(cat "$WORK/out")"
}

main() {
  test_creates_a_user_file
  test_hash_with_json_metacharacters_round_trips
  test_unsafe_names_are_skipped
  test_existing_user_is_left_alone
  finish
}

main "$@"
