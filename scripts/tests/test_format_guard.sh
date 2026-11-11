#!/bin/sh
# Tests for format_if_needed in modules/compute/user_data.sh.tftpl: it formats
# only when blkid reports no filesystem (exit 2), and fails on any other error
# instead of wiping the data volume.
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
STUB_LOG="$WORK/calls.log"
export STUB_LOG

cat >"$WORK/bin/blkid" <<'STUB'
#!/bin/sh
exit "${STUB_BLKID_EXIT:-0}"
STUB
cat >"$WORK/bin/mkfs.ext4" <<'STUB'
#!/bin/sh
echo "mkfs.ext4 $*" >>"$STUB_LOG"
STUB
chmod +x "$WORK/bin/blkid" "$WORK/bin/mkfs.ext4"
PATH="$WORK/bin:$PATH"

sed -n '/^format_if_needed() {$/,/^}$/p' "$TEMPLATE" >"$WORK/func.sh"

# run_guard BLKID_EXIT: runs the extracted function; prints the mkfs calls.
run_guard() {
  : >"$STUB_LOG"
  STUB_BLKID_EXIT="$1" sh -c "set -eu; log() { :; }; . '$WORK/func.sh'; format_if_needed /dev/xvdf" || return 1
}

main() {
  assert_status "an existing filesystem is left alone" 0 run_guard 0
  assert_eq "no mkfs on an existing filesystem" "" "$(cat "$STUB_LOG")"

  assert_status "no filesystem formats" 0 run_guard 2
  assert_eq "mkfs runs on exit 2" \
    "mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0 /dev/xvdf" "$(cat "$STUB_LOG")"

  for _main_rc in 1 4 8 127; do
    assert_status "blkid exit $_main_rc fails" 1 run_guard "$_main_rc"
    assert_eq "no mkfs on blkid exit $_main_rc" "" "$(cat "$STUB_LOG")"
  done
  finish
}

main "$@"
