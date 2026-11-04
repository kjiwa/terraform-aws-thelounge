#!/bin/sh
# Tests for the release acknowledgement in thelounge-converge.sh. The script
# is sourced with THELOUNGE_CONVERGE_SOURCE_ONLY=1 so only its functions load;
# stub aws, systemctl and sleep stand in for the instance.
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
mkdir -p "$WORK/bin"
STUB="$WORK/stub"
export STUB

cat >"$WORK/bin/aws" <<'STUB'
#!/bin/sh
# aws s3 cp - s3://BUCKET/KEY ...  writes stdin to $STUB/put/KEY
# aws s3 cp s3://BUCKET/KEY -  ...  reads $STUB/get/KEY
if [ "$1 $2 $3" = "s3 cp -" ]; then
  [ ! -f "$STUB/put-fails" ] || { echo "An error occurred (AccessDenied)" >&2; exit 1; }
  key="${4#s3://*/}"
  mkdir -p "$STUB/put/$(dirname "$key")"
  cat >"$STUB/put/$key"
  echo "$*" >"$STUB/put-args"
elif [ "$1 $2" = "s3 cp" ] && [ "$4" = "-" ]; then
  key="${3#s3://*/}"
  cat "$STUB/get/$key" 2>/dev/null || exit 1
else
  echo "unstubbed aws $*" >&2
  exit 99
fi
STUB
cat >"$WORK/bin/systemctl" <<'STUB'
#!/bin/sh
[ ! -f "$STUB/service-down" ]
STUB
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/sleep"
chmod +x "$WORK/bin/"*

readonly POINTER='{"artifact_key":"artifacts/thelounge-aaaa.tar.gz","sha256":"aaaa","thelounge_version":"4.5.2","node_version":"22.1.0","built_at":"2026-11-04T10:00:00Z"}'

reset() {
  rm -rf "$STUB"
  mkdir -p "$STUB/get/deployed"
}

# converge CODE: runs CODE with the script's functions loaded, as an arm64
# instance with the pointer above; prints its output, then "exit=N".
converge() {
  _converge_status=0
  _converge_out="$(env PATH="$WORK/bin:$PATH" THELOUNGE_CONVERGE_SOURCE_ONLY=1 \
    CONFIG_BUCKET=bucket REGION=eu-west-1 sh -c "
      set -eu
      . '$CONVERGE'
      instance_id() { echo i-0123456789abcdef0; }
      RELEASE_POINTER='$POINTER'
      RELEASE_ARCH=arm64
      $1" 2>&1)" || _converge_status=$?
  printf '%s\nexit=%s\n' "$_converge_out" "$_converge_status"
}

assert_contains() {
  if ! printf '%s\n' "$2" | grep -qF -e "$3"; then
    echo "FAIL: $1: output lacks '$3'" >&2
    printf '%s\n' "$2" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

wrote() {
  [ -f "$STUB/put/deployed/current-arm64.json" ] && echo yes || echo no
}

test_build_ack() {
  reset
  # shellcheck disable=SC2016 # expanded by the shell under test
  _out="$(converge 'build_ack "$RELEASE_POINTER" i-1 2026-11-04T10:05:00Z')"
  assert_contains "ack keeps the pointer's sha" "$_out" '"sha256":"aaaa"'
  assert_contains "ack keeps the artifact key" "$_out" '"artifact_key":"artifacts/thelounge-aaaa.tar.gz"'
  assert_contains "ack names the instance" "$_out" '"instance_id":"i-1"'
  assert_contains "ack carries the time" "$_out" '"acked_at":"2026-11-04T10:05:00Z"'
}

test_new_release_is_acknowledged() {
  reset
  echo '{"sha256":"aaaa"}' >"$STUB/get/deployed/current-arm64.json"
  _out="$(converge 'RELEASE_CHANGED=1; ack_release')"
  assert_contains "new release exits 0" "$_out" "exit=0"
  assert_eq "new release rewrites the ack even when it matches" "yes" "$(wrote)"
  assert_eq "ack body" "aaaa i-0123456789abcdef0" \
    "$(jq -r '"\(.sha256) \(.instance_id)"' "$STUB/put/deployed/current-arm64.json")"
  assert_eq "ack goes under deployed/ only" "1" \
    "$(grep -c 's3://bucket/deployed/current-arm64.json' "$STUB/put-args")"
}

test_current_ack_is_left_alone() {
  reset
  echo '{"sha256":"aaaa"}' >"$STUB/get/deployed/current-arm64.json"
  _out="$(converge 'RELEASE_CHANGED=0; ack_release')"
  assert_contains "current ack exits 0" "$_out" "exit=0"
  assert_eq "matching ack is not rewritten" "no" "$(wrote)"
}

test_missing_ack_is_written() {
  reset
  _out="$(converge 'RELEASE_CHANGED=0; ack_release')"
  assert_contains "missing ack exits 0" "$_out" "exit=0"
  assert_eq "missing ack is written" "yes" "$(wrote)"
}

test_stale_ack_is_written() {
  reset
  echo '{"sha256":"oldaa"}' >"$STUB/get/deployed/current-arm64.json"
  _out="$(converge 'RELEASE_CHANGED=0; ack_release')"
  assert_contains "stale ack exits 0" "$_out" "exit=0"
  assert_eq "differing ack is rewritten" "yes" "$(wrote)"
}

test_write_failure_does_not_fail_the_tick() {
  reset
  touch "$STUB/put-fails"
  _out="$(converge 'RELEASE_CHANGED=1; ack_release; echo after')"
  assert_contains "failed write exits 0" "$_out" "exit=0"
  assert_contains "failed write is logged" "$_out" "WARNING: could not write"
  assert_contains "the tick continues" "$_out" "after"
}

test_inactive_service_is_not_acknowledged() {
  reset
  touch "$STUB/service-down"
  _out="$(converge 'RELEASE_CHANGED=1; ack_release')"
  assert_contains "inactive service exits 0" "$_out" "exit=0"
  assert_contains "inactive service is logged" "$_out" "not active"
  assert_eq "nothing is acknowledged while the service is down" "no" "$(wrote)"
}

test_no_pointer_is_a_no_op() {
  reset
  _out="$(converge 'RELEASE_POINTER=""; RELEASE_CHANGED=1; ack_release')"
  assert_contains "no pointer exits 0" "$_out" "exit=0"
  assert_eq "no pointer writes nothing" "no" "$(wrote)"
}

main() {
  test_build_ack
  test_new_release_is_acknowledged
  test_current_ack_is_left_alone
  test_missing_ack_is_written
  test_stale_ack_is_written
  test_write_failure_does_not_fail_the_tick
  test_inactive_service_is_not_acknowledged
  test_no_pointer_is_a_no_op
  finish
}

main "$@"
