#!/bin/sh
# Tests for thelounge-spot-drain.sh with stub curl, systemctl, sync, umount,
# aws and sleep on PATH and a stub instance.env.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly SCRIPT="$TESTS_DIR/../../build/app/instance/thelounge-spot-drain.sh"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/thelounge-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
CALLS="$WORK/calls"
export CALLS WORK

for _stub in systemctl sync umount aws sleep; do
  cat >"$WORK/bin/$_stub" <<'STUB'
#!/bin/sh
echo "$(basename "$0")${*:+ $*}" >>"$CALLS"
case "$(basename "$0") $*" in
"aws ec2 detach-volume"*) [ -z "${DETACH_FAILS:-}" ] || exit 1 ;;
"umount"*) [ -z "${UMOUNT_FAILS:-}" ] || exit 1 ;;
"systemctl stop thelounge") [ -z "${STOP_FAILS:-}" ] || exit 1 ;;
esac
STUB
  chmod +x "$WORK/bin/$_stub"
done

# Answers the interruption notice with 404 for the first $QUIET_POLLS polls,
# then 200.
cat >"$WORK/bin/curl" <<'STUB'
#!/bin/sh
case "$*" in
*api/token*) echo token ;;
*meta-data/instance-id*) echo i-0123456789abcdef0 ;;
*instance-action*)
  _n="$(cat "$WORK/polls" 2>/dev/null || echo 0)"
  echo $((_n + 1)) >"$WORK/polls"
  if [ "$_n" -ge "${QUIET_POLLS:-0}" ]; then printf 200; else printf 404; fi
  ;;
esac
STUB
chmod +x "$WORK/bin/curl"

# run_script ENV_CONTENT: prints "exit=N"; calls land in $CALLS.
run_script() {
  if [ -n "$1" ]; then printf '%s\n' "$1" >"$WORK/instance.env"; else rm -f "$WORK/instance.env"; fi
  : >"$CALLS"
  rm -f "$WORK/polls" "$WORK/drained"
  _run_script_status=0
  PATH="$WORK/bin:$PATH" INSTANCE_ENV="$WORK/instance.env" DRAIN_MARKER="$WORK/drained" \
    sh "$SCRIPT" >/dev/null 2>&1 || _run_script_status=$?
  echo "exit=$_run_script_status"
}

readonly FULL_ENV='REGION=eu-west-1
ASG_NAME=thelounge-prod
EBS_VOLUME_ID=vol-0123456789abcdef0
DATA_ROOT=/srv/thelounge'

readonly DRAIN_CALLS='systemctl stop thelounge
sync
systemctl stop thelounge-status.service thelounge-health-watchdog.timer thelounge-disk-metric.timer
umount /srv/thelounge
aws ec2 detach-volume --volume-id vol-0123456789abcdef0 --region eu-west-1
aws autoscaling set-instance-health --instance-id i-0123456789abcdef0 --health-status Unhealthy --region eu-west-1'

test_notice_stops_detaches_then_marks_unhealthy() {
  assert_eq "exit status" "exit=0" "$(QUIET_POLLS=0 run_script "$FULL_ENV")"
  assert_eq "call order" "$DRAIN_CALLS" "$(grep -v '^sleep' "$CALLS")"
  assert_eq "drain marker" "yes" "$([ -e "$WORK/drained" ] && echo yes || echo no)"
}

test_polls_until_the_notice() {
  assert_eq "exit status" "exit=0" "$(QUIET_POLLS=3 run_script "$FULL_ENV")"
  assert_eq "slept between polls" "3" "$(grep -c '^sleep' "$CALLS")"
  assert_eq "call order" "$DRAIN_CALLS" "$(grep -v '^sleep' "$CALLS")"
}

test_no_notice_touches_nothing() {
  printf '%s\n' "$FULL_ENV" >"$WORK/instance.env"
  : >"$CALLS"
  rm -f "$WORK/polls"
  # Four quiet polls, then the stub sleep fails the loop out.
  cat >"$WORK/bin/sleep" <<'STUB'
#!/bin/sh
echo "sleep $*" >>"$CALLS"
[ "$(grep -c '^sleep' "$CALLS")" -lt 4 ] || exit 99
STUB
  _status=0
  QUIET_POLLS=100 PATH="$WORK/bin:$PATH" INSTANCE_ENV="$WORK/instance.env" DRAIN_MARKER="$WORK/drained" \
    sh "$SCRIPT" >/dev/null 2>&1 || _status=$?
  assert_eq "loop ended by the sleep stub" "99" "$_status"
  assert_eq "no drain action" "0" "$(grep -vc '^sleep' "$CALLS" || true)"
  cat >"$WORK/bin/sleep" <<'STUB'
#!/bin/sh
echo "$(basename "$0")${*:+ $*}" >>"$CALLS"
STUB
}

test_failed_detach_still_marks_unhealthy() {
  assert_eq "exit status" "exit=0" "$(DETACH_FAILS=1 UMOUNT_FAILS=1 run_script "$FULL_ENV")"
  assert_eq "unhealthy still set" "aws autoscaling set-instance-health --instance-id i-0123456789abcdef0 --health-status Unhealthy --region eu-west-1" "$(tail -n 1 "$CALLS")"
}

test_failed_stop_still_detaches_and_marks_unhealthy() {
  assert_eq "exit status" "exit=0" "$(STOP_FAILS=1 run_script "$FULL_ENV")"
  assert_eq "call order" "$DRAIN_CALLS" "$(grep -v '^sleep' "$CALLS")"
}

test_without_a_volume_id_it_only_marks_unhealthy() {
  assert_eq "exit status" "exit=0" "$(run_script 'REGION=eu-west-1
DATA_ROOT=/srv/thelounge')"
  assert_eq "no detach" "0" "$(grep -c 'detach-volume' "$CALLS" || true)"
  assert_eq "unhealthy set" "1" "$(grep -c 'set-instance-health' "$CALLS")"
}

test_without_instance_env_it_only_stops_the_app() {
  assert_eq "exit status" "exit=0" "$(run_script '')"
  assert_eq "call order" "systemctl stop thelounge
sync" "$(grep -v '^sleep' "$CALLS")"
}

main() {
  test_notice_stops_detaches_then_marks_unhealthy
  test_polls_until_the_notice
  test_no_notice_touches_nothing
  test_failed_detach_still_marks_unhealthy
  test_failed_stop_still_detaches_and_marks_unhealthy
  test_without_a_volume_id_it_only_marks_unhealthy
  test_without_instance_env_it_only_stops_the_app
  finish
}

main "$@"
