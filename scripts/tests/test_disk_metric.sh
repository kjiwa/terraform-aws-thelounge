#!/bin/sh
# Tests for thelounge-disk-metric.sh with a stub aws and a stub instance.env.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly SCRIPT="$TESTS_DIR/../../build/app/instance/thelounge-disk-metric.sh"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/thelounge-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat >"$WORK/bin/aws" <<'STUB'
#!/bin/sh
echo "$*" >"$STUB_ARGS"
STUB
chmod +x "$WORK/bin/aws"
STUB_ARGS="$WORK/aws-args"
export STUB_ARGS

# run_script HOME_DIR: prints "exit=N".
run_script() {
  printf 'REGION=eu-west-1\nTHELOUNGE_HOME=%s\n' "$1" >"$WORK/instance.env"
  _run_script_status=0
  PATH="$WORK/bin:$PATH" INSTANCE_ENV="$WORK/instance.env" sh "$SCRIPT" >/dev/null 2>&1 ||
    _run_script_status=$?
  echo "exit=$_run_script_status"
}

test_missing_data_volume_still_reports_root() {
  rm -f "$STUB_ARGS"
  assert_eq "exit status" "exit=0" "$(run_script "$WORK/not-mounted-yet")"
  assert_eq "a metric is still published" "1" "$(grep -c 'put-metric-data' "$STUB_ARGS")"
}

test_present_data_volume_is_reported() {
  rm -f "$STUB_ARGS"
  mkdir -p "$WORK/data"
  assert_eq "exit status" "exit=0" "$(run_script "$WORK/data")"
  assert_eq "a metric is published" "1" "$(grep -c 'put-metric-data' "$STUB_ARGS")"
}

main() {
  test_missing_data_volume_still_reports_root
  test_present_data_volume_is_reported
  finish
}

main "$@"
