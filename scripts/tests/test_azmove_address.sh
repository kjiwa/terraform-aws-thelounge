#!/bin/sh
# azmove.sh adopts the data volume by the tail of its state address. That tail
# must be where the module keeps the volume: `storage` is the root's module
# call and `data_volume` is the module call inside modules/storage, so a
# relocation breaks this test rather than the first AZ move.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly ROOT="$TESTS_DIR/../.."
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

main() {
  _main_storage="$(sed -n 's/^module "\(storage\)" {$/\1/p' "$ROOT/main.tf")"
  _main_volume="$(sed -n 's/^module "\(data_volume\)" {$/\1/p' "$ROOT/modules/storage/main.tf")"
  _main_suffix="$(sed -n 's/^readonly VOL_RESOURCE_SUFFIX="\(.*\)"$/\1/p' "$ROOT/scripts/azmove.sh")"
  assert_eq "azmove adopts the volume where the module keeps it" \
    "module.$_main_storage.module.$_main_volume.aws_ebs_volume.this" "$_main_suffix"
  finish
}

main "$@"
