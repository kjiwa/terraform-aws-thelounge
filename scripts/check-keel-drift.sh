#!/bin/sh
# Fails when a vendored file under scripts/keel differs from the same file at
# the terraform-aws-keel tag it names. Needs network access to fetch the tag.
#
#   ./check-keel-drift.sh
set -eu

readonly KEEL_URL="https://github.com/kjiwa/terraform-aws-keel.git"
readonly VENDOR_MARKER='^# (Vendored from terraform-aws-keel |keel and re-vendor\.)'

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly SCRIPT_DIR
readonly LOG_PREFIX="check-keel-drift"
# shellcheck source=keel/common.sh
. "$SCRIPT_DIR/keel/common.sh"

# The tag the vendored copies name; they must all name the same one.
vendored_tag() {
  _vendored_tags="$(sed -n 's/^# Vendored from terraform-aws-keel \(v[0-9][0-9.]*\),.*/\1/p' "$SCRIPT_DIR"/keel/*.sh | sort -u)"
  [ -n "$_vendored_tags" ] || die "no vendored file names a keel tag"
  [ "$(printf '%s\n' "$_vendored_tags" | wc -l)" -eq 1 ] ||
    die "vendored files name different keel tags: $_vendored_tags"
  printf '%s\n' "$_vendored_tags"
}

# $1 = tag, $2 = destination directory.
fetch_keel_scripts() {
  _fetch_clone="$2/keel"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$1" "$KEEL_URL" "$_fetch_clone" ||
    die "could not fetch $KEEL_URL at $1"
}

# $1 = tag, $2 = directory holding the checkout.
compare_files() {
  _compare_status=0
  for _compare_file in "$SCRIPT_DIR"/keel/*.sh; do
    _compare_name="$(basename "$_compare_file")"
    if ! grep -Ev -e "$VENDOR_MARKER" "$_compare_file" | diff -u "$2/keel/scripts/$_compare_name" - >&2; then
      log "scripts/keel/$_compare_name differs from keel $1 scripts/$_compare_name"
      _compare_status=1
    fi
  done
  return "$_compare_status"
}

main() {
  require git diff
  _main_tag="$(vendored_tag)"
  _main_work="$(mktemp -d "${TMPDIR:-/tmp}/keel-drift.XXXXXX")"
  trap 'rm -rf "$_main_work"' EXIT
  fetch_keel_scripts "$_main_tag" "$_main_work"
  compare_files "$_main_tag" "$_main_work" || die "vendored keel scripts have drifted; re-vendor from keel $_main_tag"
  log "scripts/keel matches keel $_main_tag"
}

main "$@"
