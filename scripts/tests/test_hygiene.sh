#!/bin/sh
# Tests for scripts/hygiene.sh. Offending strings are assembled at run time so
# this file itself stays clean.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly HYGIENE="$TESTS_DIR/../hygiene.sh"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

# check_line NAME EXPECTED_STATUS CONTENT [FILE_NAME]
check_line() {
  _check_file="$WORK/${4:-case.txt}"
  mkdir -p "$(dirname "$_check_file")"
  printf '%s\n' "$3" >"$_check_file"
  assert_status "$1" "$2" sh "$HYGIENE" "$_check_file"
}

main() {
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/hygiene-test.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT

  check_line "clean text" 0 "terraform apply with var.account_id"
  check_line "account id" 1 "account $(printf '%s%s' 9876 54321098) here"
  check_line "documented example id" 0 "account 123456789012"
  check_line "zero placeholder id" 0 "account 000000000000"
  check_line "uuid is not an id" 0 "id 00000000-0000-4000-8000-000000000001"
  check_line "instance home is not a person's" 0 "rm -f $(printf '%s' /home)/ec2-user/.ssh/authorized_keys"
  check_line "example id repeated" 0 "123456789012 123456789012"
  check_line "example id with digit prefix is not an id" 0 "n 9123456789012 x"
  check_line "example id in longer run is not an id" 0 "n 123456789012345678 x"
  check_line "real id after example id" 1 "123456789012,$(printf '%s%s' 9876 54321098)"
  check_line "real id sharing digits with example" 1 "n $(printf '%s%s' 1234567890 99) x 123456789012"
  check_line "13 digits is not an id" 0 "serial $(printf '%s%s' 1234 567890123)"
  check_line "hex run is not an id" 0 "sha ab$(printf '%s%s' 9876 54321098)cd"
  check_line "profile env" 1 "export AWS_PROFILE=$(printf 'my%s' admin)"
  check_line "profile flag" 1 "aws s3 ls --profile $(printf 'my%s' admin)"
  check_line "profile hcl" 1 "profile = \"$(printf 'my%s' admin)\""
  # shellcheck disable=SC2016 # the line under test must stay literal
  check_line "profile variable" 0 'AWS_PROFILE="$profile" aws "$@"'
  check_line "personal email" 1 "mail $(printf 'someone@%s.com' gmail)"
  check_line "other email" 0 "mail someone@example.com"
  check_line "home path" 1 "cd /$(printf 'Users')/someone/src"
  check_line "linux home path" 1 "cd /$(printf 'home')/someone/src"
  check_line "operator deployment name" 1 "repo $(printf 'arithraz%s' ine)"
  check_line "operator first name" 1 "by $(printf 'Kam%s' il)"
  check_line "operator email" 1 "mail $(printf 'ji%s@example.com' wa)"
  check_line "repository owner URL" 0 "https://github.com/kjiwa/terraform-aws-thelounge"
  # shellcheck disable=SC2016 # the line under test must stay literal
  check_line "bcrypt hash" 1 "hash $(printf '%s' '$2b')$(printf '$11$%s' abcdefghijklmnopqrstuv)"
  check_line "bcrypt placeholder" 0 "hash <bcrypt hash>"
  check_line "operator time zone" 1 "tz America/$(printf 'Los_%s' Angeles)"
  check_line "other time zone" 0 "tz Europe/Berlin"
  check_line "operator region" 1 "region $(printf 'us-west-%s' 1)"
  check_line "other region" 0 "region us-west-2"
  check_line "region in examples" 0 "region $(printf 'us-west-%s' 1)" examples/minimal/main.tf

  printf '%s\n' "x" >"$WORK/a.txt"
  printf '%s\n' "/$(printf 'Users')/someone/x" >"$WORK/b.txt"
  assert_status "any dirty file fails" 1 sh "$HYGIENE" "$WORK/a.txt" "$WORK/b.txt"
  assert_status "missing file is skipped" 0 sh "$HYGIENE" "$WORK/none.txt"
  printf '\000\377 %s%s\n' 9876 54321098 >"$WORK/image.png"
  assert_status "binary file is skipped" 0 sh "$HYGIENE" "$WORK/image.png"
  assert_eq "binary file prints nothing" "" "$(sh "$HYGIENE" "$WORK/image.png" 2>&1 || true)"
  finish
}

main "$@"
