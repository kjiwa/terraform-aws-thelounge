#!/bin/sh
# Tests for release installation, activation and pruning in
# thelounge-converge.sh. The script is sourced with
# THELOUNGE_CONVERGE_SOURCE_ONLY=1; a stub aws serves the pointer and tarball.
# The instance is Linux, and so are the tools these functions use (mv -T,
# sha256sum, find -printf), so other systems skip.
# shellcheck disable=SC2016 # code strings are expanded by the shell under test
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly CONVERGE="$TESTS_DIR/../../build/app/instance/thelounge-converge.sh"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

if [ "$(uname -s)" != Linux ]; then
  echo "skip: needs Linux"
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/thelounge-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
STUB="$WORK/stub"
export STUB
readonly RELEASES="$WORK/opt/releases"
readonly CURRENT="$WORK/opt/current"
readonly APPLIED="$WORK/opt/applied.sha"

cat >"$WORK/bin/aws" <<'STUB'
#!/bin/sh
# aws s3 cp s3://BUCKET/KEY DEST ...  copies $STUB/get/KEY to DEST ("-" is stdout)
key="${3#s3://*/}"
[ -f "$STUB/get/$key" ] || exit 1
if [ "$4" = "-" ]; then cat "$STUB/get/$key"; else cp "$STUB/get/$key" "$4"; fi
STUB
chmod +x "$WORK/bin/aws"

reset() {
  rm -rf "$WORK/opt" "$STUB"
  mkdir -p "$RELEASES" "$STUB/get/artifacts"
}

# publish NAME: serves a release tarball containing NAME as the arm64 pointer;
# prints its sha256.
publish() {
  rm -rf "$WORK/src"
  mkdir -p "$WORK/src"
  echo "$1" >"$WORK/src/app.txt"
  tar -czf "$STUB/get/artifacts/$1.tar.gz" -C "$WORK/src" .
  _publish_sha="$(sha256sum "$STUB/get/artifacts/$1.tar.gz" | cut -d' ' -f1)"
  printf '{"artifact_key":"artifacts/%s.tar.gz","sha256":"%s"}' "$1" "$_publish_sha" \
    >"$STUB/get/artifacts/current-arm64.json"
  echo "$_publish_sha"
}

# converge CODE: runs CODE with the script's functions loaded, as an arm64
# instance; prints its output.
converge() {
  env PATH="$WORK/bin:$PATH" THELOUNGE_CONVERGE_SOURCE_ONLY=1 \
    CONFIG_BUCKET=bucket REGION=eu-west-1 ARTIFACT_PREFIX=artifacts \
    RELEASES_DIR="$RELEASES" CURRENT_LINK="$CURRENT" APPLIED_FILE="$APPLIED" \
    sh -c "
      set -eu
      . '$CONVERGE'
      resolve_arch() { echo arm64; }
      $1" 2>&1
}

test_new_release_is_installed_and_activated() {
  reset
  _sha="$(publish one)"
  _out="$(converge 'sync_release; echo "changed=$RELEASE_CHANGED restart=$RESTART_NEEDED"')"
  assert_eq "release is flagged" "changed=1 restart=1" "$(printf '%s\n' "$_out" | tail -1)"
  assert_eq "current points at the release" "$RELEASES/$_sha" "$(readlink "$CURRENT")"
  assert_eq "release content" "one" "$(cat "$CURRENT/app.txt")"
  assert_eq "no staging leftovers" "$_sha" "$(ls -A "$RELEASES")"
  assert_eq "no leftover link" "current" "$(basename "$WORK"/opt/current*)"
}

test_failed_extraction_leaves_the_running_release_alone() {
  reset
  _old="$(publish old)"
  converge 'sync_release' >/dev/null
  publish new >/dev/null
  printf 'not a tarball' >"$STUB/get/artifacts/new.tar.gz"
  _bad="$(sha256sum "$STUB/get/artifacts/new.tar.gz" | cut -d' ' -f1)"
  printf '{"artifact_key":"artifacts/new.tar.gz","sha256":"%s"}' "$_bad" \
    >"$STUB/get/artifacts/current-arm64.json"
  converge 'sync_release' >/dev/null || true
  assert_eq "current still points at the old release" "$RELEASES/$_old" "$(readlink "$CURRENT")"
  assert_eq "no half-extracted release remains" "$_old" "$(ls -A "$RELEASES")"
}

test_activated_but_never_started_release_is_restarted() {
  reset
  publish one >/dev/null
  converge 'sync_release; mark_applied' >/dev/null
  publish two >/dev/null
  converge 'sync_release' >/dev/null
  _out="$(converge 'sync_release; echo "changed=$RELEASE_CHANGED restart=$RESTART_NEEDED"')"
  assert_eq "next tick restarts the unstarted release" "changed=1 restart=1" "$(printf '%s\n' "$_out" | tail -1)"
  converge 'sync_release; mark_applied' >/dev/null
  _out="$(converge 'sync_release; echo "changed=$RELEASE_CHANGED restart=$RESTART_NEEDED"')"
  assert_eq "once started it is quiet" "changed=0 restart=0" "$(printf '%s\n' "$_out" | tail -1)"
}

test_upgrade_tick_that_fails_after_activation_is_retried() {
  reset
  publish one >/dev/null
  converge 'sync_release' >/dev/null
  rm -f "$APPLIED"
  publish two >/dev/null
  converge 'sync_release' >/dev/null
  _out="$(converge 'sync_release; echo "restart=$RESTART_NEEDED"')"
  assert_eq "an instance that predates the marker still restarts" "restart=1" "$(printf '%s\n' "$_out" | tail -1)"
}

test_first_tick_without_a_marker_does_not_restart() {
  reset
  publish one >/dev/null
  converge 'sync_release' >/dev/null
  rm -f "$APPLIED"
  _out="$(converge 'sync_release; echo "restart=$RESTART_NEEDED"')"
  assert_eq "no marker means no restart" "restart=0" "$(printf '%s\n' "$_out" | tail -1)"
}

test_prune_never_removes_the_current_release() {
  reset
  mkdir -p "$RELEASES/a" "$RELEASES/b" "$RELEASES/c" "$RELEASES/.incoming-x"
  touch -d '2020-01-01' "$RELEASES/a"
  touch -d '2021-01-01' "$RELEASES/b"
  touch -d '2022-01-01' "$RELEASES/c"
  ln -s "$RELEASES/a" "$CURRENT"
  converge 'prune_releases' >/dev/null
  assert_eq "current plus one previous remain, staging gone" "a c" \
    "$(find "$RELEASES" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort | tr '\n' ' ' | sed 's/ $//')"
}

main() {
  test_new_release_is_installed_and_activated
  test_failed_extraction_leaves_the_running_release_alone
  test_activated_but_never_started_release_is_restarted
  test_upgrade_tick_that_fails_after_activation_is_retried
  test_first_tick_without_a_marker_does_not_restart
  test_prune_never_removes_the_current_release
  finish
}

main "$@"
