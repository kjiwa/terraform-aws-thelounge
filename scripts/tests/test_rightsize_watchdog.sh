#!/bin/sh
# Tests for thelounge-rightsize-watchdog.sh with stub systemctl, aws, sync and
# keel-rightsize-check on PATH and a stub instance.env.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly SCRIPT="$TESTS_DIR/../../build/app/instance/thelounge-rightsize-watchdog.sh"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/thelounge-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
CALLS="$WORK/calls"
export CALLS

for _stub in systemctl aws sync; do
  cat >"$WORK/bin/$_stub" <<'STUB'
#!/bin/sh
echo "$(basename "$0")${*:+ $*}" >>"$CALLS"
STUB
  chmod +x "$WORK/bin/$_stub"
done
cat >"$WORK/bin/keel-rightsize-check" <<'STUB'
#!/bin/sh
echo "keel-rightsize-check $*" >>"$CALLS"
exit "${CHECK_EXIT:-0}"
STUB
cat >"$WORK/bin/curl" <<'STUB'
#!/bin/sh
case "$*" in
*api/token*) echo token ;;
*instance-id) echo i-0123456789abcdef0 ;;
esac
STUB
chmod +x "$WORK/bin/keel-rightsize-check" "$WORK/bin/curl"

# run_script ENV_CONTENT CHECK_EXIT: prints "exit=N"; calls land in $CALLS.
run_script() {
  printf '%s\n' "$1" >"$WORK/instance.env"
  : >"$CALLS"
  _run_script_status=0
  CHECK_EXIT="$2" PATH="$WORK/bin:$PATH" INSTANCE_ENV="$WORK/instance.env" sh "$SCRIPT" >/dev/null 2>&1 ||
    _run_script_status=$?
  echo "exit=$_run_script_status"
}

readonly FULL_ENV='REGION=eu-west-1
ASG_NAME=thelounge-prod
RIGHTSIZE_MIN_UPTIME_HOURS=5'

test_missing_asg_name_does_nothing() {
  assert_eq "exit status" "exit=0" "$(run_script 'REGION=eu-west-1' 0)"
  assert_eq "no systemctl or aws call" "0" "$(wc -l <"$CALLS" | tr -d ' ')"
}

test_missing_region_does_nothing() {
  assert_eq "exit status" "exit=0" "$(run_script 'ASG_NAME=thelounge-prod' 0)"
  assert_eq "no systemctl or aws call" "0" "$(wc -l <"$CALLS" | tr -d ' ')"
}

test_check_declining_means_no_drain() {
  assert_eq "exit status" "exit=0" "$(run_script "$FULL_ENV" 1)"
  assert_eq "only the check ran" "keel-rightsize-check eu-west-1 thelounge-prod 5" "$(cat "$CALLS")"
}

test_check_approving_drains_then_terminates() {
  assert_eq "exit status" "exit=0" "$(run_script "$FULL_ENV" 0)"
  assert_eq "call order" "keel-rightsize-check eu-west-1 thelounge-prod 5
systemctl stop thelounge
sync
aws ec2 terminate-instances --instance-ids i-0123456789abcdef0 --region eu-west-1" "$(cat "$CALLS")"
}

test_uptime_hours_default_to_three() {
  assert_eq "exit status" "exit=0" "$(run_script 'REGION=eu-west-1
ASG_NAME=thelounge-prod' 1)"
  assert_eq "check args" "keel-rightsize-check eu-west-1 thelounge-prod 3" "$(cat "$CALLS")"
}

main() {
  test_missing_asg_name_does_nothing
  test_missing_region_does_nothing
  test_check_declining_means_no_drain
  test_check_approving_drains_then_terminates
  test_uptime_hours_default_to_three
  finish
}

main "$@"
