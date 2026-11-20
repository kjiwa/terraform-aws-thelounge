#!/bin/sh
# Tests for the boot order in modules/compute/user_data.sh.tftpl: jq is
# installed before converge starts, converge starts as soon as instance.env
# exists, and dnf-automatic waits for the app. Functions are extracted from
# the template; every step but the one under test is a stub that records its
# name.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly TEMPLATE="$TESTS_DIR/../../modules/compute/user_data.sh.tftpl"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/thelounge-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
CALLS="$WORK/calls"
export CALLS WORK

cat >"$WORK/bin/systemctl" <<'STUB'
#!/bin/sh
echo "systemctl $*" >>"$CALLS"
if [ "$1" = is-active ]; then
  _n="$(cat "$WORK/checks" 2>/dev/null || echo 0)"
  echo $((_n + 1)) >"$WORK/checks"
  [ "$_n" -ge "${ACTIVE_AFTER:-0}" ]
fi
STUB
cat >"$WORK/bin/sleep" <<'STUB'
#!/bin/sh
echo "sleep $*" >>"$CALLS"
STUB
cat >"$WORK/bin/dnf" <<'STUB'
#!/bin/sh
echo "dnf $*" >>"$CALLS"
STUB
chmod +x "$WORK/bin/systemctl" "$WORK/bin/sleep" "$WORK/bin/dnf"

extract() {
  for _extract_fn in "$@"; do
    sed -n "/^$_extract_fn() {\$/,/^}\$/p" "$TEMPLATE"
  done
}

# run_function SNIPPET: runs SNIPPET with the extracted functions loaded.
run_function() {
  : >"$CALLS"
  rm -f "$WORK/checks"
  {
    echo 'set -eu'
    echo 'log() { :; }'
    echo 'readonly APP_WAIT_TRIES=3 APP_WAIT_SECONDS=5'
    extract install_jq start_converge wait_for_app
    echo "$1"
  } >"$WORK/run.sh"
  PATH="$WORK/bin:$PATH" sh "$WORK/run.sh"
}

test_main_order() {
  : >"$CALLS"
  {
    echo 'set -eu'
    echo 'log() { :; }'
    for _step in attach_volume mount_data_volume setup_swap associate_eip install_jq \
      fetch_instance_files install_instance_files configure_rightsize_timer \
      write_instance_env start_converge wait_for_app enable_security_updates; do
      echo "$_step() { echo $_step >>\"\$CALLS\"; }"
    done
    extract main
    echo 'INSTANCE_ID=i-0abc'
    echo 'main'
  } >"$WORK/main.sh"
  PATH="$WORK/bin:$PATH" sh "$WORK/main.sh"
  assert_eq "boot order" "attach_volume
mount_data_volume
setup_swap
associate_eip
install_jq
fetch_instance_files
install_instance_files
configure_rightsize_timer
write_instance_env
start_converge
wait_for_app
enable_security_updates" "$(cat "$CALLS")"
}

test_converge_starts_without_blocking() {
  run_function start_converge
  assert_eq "start call" "systemctl start --no-block thelounge-converge.service" "$(cat "$CALLS")"
}

test_install_jq_skips_when_present() {
  printf '#!/bin/sh\n' >"$WORK/bin/jq"
  chmod +x "$WORK/bin/jq"
  run_function install_jq
  rm -f "$WORK/bin/jq"
  assert_eq "no dnf call" "" "$(cat "$CALLS")"
}

test_install_jq_installs_when_missing() {
  run_function 'command() { return 1; }; install_jq'
  assert_eq "dnf call" "dnf install -y jq" "$(cat "$CALLS")"
}

test_wait_for_app_returns_once_active() {
  ACTIVE_AFTER=1 run_function wait_for_app
  assert_eq "polls until active" "systemctl is-active --quiet thelounge
sleep 5
systemctl is-active --quiet thelounge" "$(cat "$CALLS")"
}

test_wait_for_app_gives_up_without_failing() {
  _status=0
  ACTIVE_AFTER=99 run_function wait_for_app || _status=$?
  assert_eq "exit status" "0" "$_status"
  assert_eq "three checks" "3" "$(grep -c 'is-active' "$CALLS")"
}

main() {
  test_main_order
  test_converge_starts_without_blocking
  test_install_jq_skips_when_present
  test_install_jq_installs_when_missing
  test_wait_for_app_returns_once_active
  test_wait_for_app_gives_up_without_failing
  finish
}

main "$@"
