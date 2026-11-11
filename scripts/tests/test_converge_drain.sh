#!/bin/sh
# Tests that thelounge-converge.sh stands down once the Spot drain marker
# exists, whether the marker predates the tick or appears while it runs. The
# script is sourced with THELOUNGE_CONVERGE_SOURCE_ONLY=1 and every step
# before the service decision is stubbed; a stub systemctl records its calls.
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
readonly MARKER="$WORK/drained"
export MARKER

cat >"$WORK/bin/systemctl" <<'STUB'
#!/bin/sh
echo "$*" >>"$STUB/calls"
[ "$1" != is-active ] || [ ! -f "$STUB/service-down" ]
STUB
chmod +x "$WORK/bin/systemctl"

reset() {
  rm -rf "$STUB" "$MARKER"
  mkdir -p "$STUB"
  : >"$STUB/calls"
  : >"$STUB/records"
}

records() {
  tr '\n' ',' <"$STUB/records" | sed 's/,$//'
}

# converge STEPS: runs main with every step stubbed to a no-op except for the
# overrides in STEPS (shell code, run after the stubs); prints the systemctl
# calls it made, comma-separated, ignoring is-active.
converge() {
  env PATH="$WORK/bin:$PATH" THELOUNGE_CONVERGE_SOURCE_ONLY=1 \
    CONFIG_BUCKET=bucket REGION=eu-west-1 DRAIN_MARKER="$MARKER" \
    sh -c "
      set -eu
      . '$CONVERGE'
      load_env() { :; }
      ensure_thelounge_user() { :; }
      ensure_jq() { :; }
      sync_instance_files() { :; }
      install_changed() { :; }
      fetch_desired_config() { :; }
      sync_release() { :; }
      converge_data() { :; }
      mark_applied() { echo mark >>'$STUB/records'; }
      ack_release() { echo ack >>'$STUB/records'; }
      $1
      main" >/dev/null 2>&1 || true
  grep -v '^is-active' "$STUB/calls" | tr '\n' ',' | sed 's/,$//'
}

test_without_a_marker_converge_restarts_and_starts() {
  reset
  assert_eq "restart when changed" "restart thelounge" "$(converge 'RESTART_NEEDED=1')"
  reset
  : >"$STUB/service-down"
  assert_eq "start when stopped" "start thelounge" "$(converge ':')"
}

test_marker_present_at_start_blocks_restart_and_start() {
  reset
  : >"$MARKER"
  assert_eq "no restart" "" "$(converge 'RESTART_NEEDED=1')"
  reset
  : >"$MARKER"
  : >"$STUB/service-down"
  assert_eq "no start" "" "$(converge ':')"
}

test_marker_created_mid_run_blocks_restart_and_start() {
  reset
  assert_eq "no restart" "" "$(converge "sync_release() { RESTART_NEEDED=1; : >'$MARKER'; }")"
  reset
  : >"$STUB/service-down"
  assert_eq "no start" "" "$(converge "converge_data() { : >'$MARKER'; }")"
}

test_a_drained_tick_does_not_record_or_acknowledge_the_release() {
  reset
  : >"$MARKER"
  converge 'RESTART_NEEDED=1' >/dev/null
  assert_eq "no mark or ack when drained" "" "$(records)"
  reset
  converge ':' >/dev/null
  assert_eq "mark and ack otherwise" "mark,ack" "$(records)"
}

test_a_failed_restart_fails_the_tick() {
  reset
  _t_rc=0
  env PATH="$WORK/bin:$PATH" THELOUNGE_CONVERGE_SOURCE_ONLY=1 \
    CONFIG_BUCKET=bucket REGION=eu-west-1 DRAIN_MARKER="$MARKER" \
    sh -c "
      set -eu
      . '$CONVERGE'
      load_env() { :; }
      ensure_thelounge_user() { :; }
      ensure_jq() { :; }
      sync_instance_files() { :; }
      install_changed() { :; }
      fetch_desired_config() { :; }
      sync_release() { RESTART_NEEDED=1; }
      converge_data() { :; }
      mark_applied() { :; }
      ack_release() { :; }
      systemctl() { return 1; }
      main" >/dev/null 2>&1 || _t_rc=$?
  assert_eq "failed restart exits non-zero" "yes" "$([ "$_t_rc" -ne 0 ] && echo yes || echo no)"
}

main() {
  test_without_a_marker_converge_restarts_and_starts
  test_marker_present_at_start_blocks_restart_and_start
  test_marker_created_mid_run_blocks_restart_and_start
  test_a_drained_tick_does_not_record_or_acknowledge_the_release
  test_a_failed_restart_fails_the_tick
  finish
}

main "$@"
