#!/bin/sh
# Tests for scripts/common.sh: root selection, output reading, and the
# refusals built on them. A stub terraform serves canned outputs and state.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly SCRIPTS="$TESTS_DIR/.."
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/thelounge-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/root"
readonly STUB_OUTPUTS="$WORK/outputs.json"
readonly STUB_STATE="$WORK/state.txt"
export STUB_OUTPUTS STUB_STATE

cat >"$WORK/bin/terraform" <<'STUB'
#!/bin/sh
case "$*" in
*"output -json thelounge"*) [ -z "${STUB_TF_FAIL:-}" ] || exit 1; cat "$STUB_OUTPUTS" ;;
*"state list"*) cat "$STUB_STATE" ;;
esac
STUB
cat >"$WORK/bin/aws" <<'STUB'
#!/bin/sh
echo "${STUB_ACCOUNT:-123456789012}"
STUB
for _tool in curl ssh; do
  printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/$_tool"
done
chmod +x "$WORK/bin/"*

# write_outputs MODE VAULT: the root's `thelounge` output; VAULT "" is null.
write_outputs() {
  jq -n --arg mode "$1" --arg vault "$2" '{
    region: "eu-west-1", url: "https://irc.example.org",
    instance_role_arn: "arn:aws:iam::123456789012:role/thelounge-prod",
    asg_name: "thelounge-prod", data_volume_id: "vol-0123456789abcdef0",
    backup_mode: $mode,
    vault_name: (if $vault == "" then null else $vault end),
    backup_role_name: (if $vault == "" then null else "thelounge-backup" end),
    backup_copy_vault_arn: (if $mode == "cross_account"
      then "arn:aws:backup:us-east-2:000000000000:backup-vault:offsite" else null end)}' \
    >"$STUB_OUTPUTS"
}

# lib CODE: runs CODE in a fresh shell with the common helpers loaded.
lib() {
  env THELOUNGE_ROOT="${TEST_ROOT:-}" PATH="$WORK/bin:$PATH" sh -c \
    "set -eu; . '$SCRIPTS/keel/common.sh'; . '$SCRIPTS/common.sh'; $1" 2>&1
}

# lib_status CODE: the exit status of lib CODE.
lib_status() {
  _lib_status=0
  lib "$1" >/dev/null || _lib_status=$?
  echo "$_lib_status"
}

test_select_root() {
  assert_eq "flag" "$WORK/root 2" \
    "$(lib "select_root --root '$WORK/root' plan; echo \"\$ROOT_DIR \$ROOT_SHIFT\"")"
  assert_eq "env" "$WORK/root 0" \
    "$(TEST_ROOT="$WORK/root" lib "select_root plan; echo \"\$ROOT_DIR \$ROOT_SHIFT\"")"
  assert_eq "flag wins over env" "$WORK/root 2" \
    "$(lib "THELOUNGE_ROOT=/nonexistent; select_root --root '$WORK/root'; echo \"\$ROOT_DIR \$ROOT_SHIFT\"")"
  assert_eq "missing root refused" "1" "$(lib_status "select_root plan")"
  assert_eq "missing root says how" "1" \
    "$(lib 'select_root plan' | grep -c -e '--root')"
  assert_eq "missing root names the variable" "1" \
    "$(lib 'select_root plan' | grep -c 'THELOUNGE_ROOT')"
  assert_eq "nonexistent root refused" "1" "$(lib_status "select_root --root /nonexistent")"
  assert_eq "flag without value refused" "1" "$(lib_status "select_root --root")"
}

test_init_root() {
  write_outputs local thelounge-backup
  assert_eq "region" "eu-west-1" \
    "$(lib "ROOT_DIR='$WORK/root'; init_root; echo \"\$REGION\"")"
  assert_eq "terraform failure refused" "1" \
    "$(STUB_TF_FAIL=1 lib_status "ROOT_DIR='$WORK/root'; init_root")"
  assert_eq "refusal names the output" "1" \
    "$(STUB_TF_FAIL=1 lib "ROOT_DIR='$WORK/root'; init_root" | grep -c 'output \"thelounge\"')"
}

test_tf_output() {
  write_outputs local ""
  _init="ROOT_DIR='$WORK/root'; init_root;"
  assert_eq "value" "https://irc.example.org" "$(lib "$_init tf_output url")"
  assert_eq "unknown output refused" "1" "$(lib_status "$_init tf_output nope")"
  assert_eq "null output refused" "1" "$(lib_status "$_init tf_output vault_name")"
  assert_eq "optional null is empty" "" "$(lib "$_init tf_output_opt vault_name")"
  assert_eq "optional value" "local" "$(lib "$_init tf_output_opt backup_mode")"
  assert_eq "optional unknown output refused" "1" "$(lib_status "$_init tf_output_opt nope")"
}

test_account() {
  write_outputs local ""
  _init="ROOT_DIR='$WORK/root'; init_root;"
  assert_eq "matching account" "123456789012" "$(lib "$_init resolve_account")"
  assert_eq "wrong account refused" "1" \
    "$(STUB_ACCOUNT=000000000000 lib_status "$_init resolve_account")"
}

test_backup() {
  _init="ROOT_DIR='$WORK/root'; init_root;"
  write_outputs local thelounge-backup
  assert_eq "vault" "thelounge-backup" "$(lib "$_init resolve_vault")"
  assert_eq "role comes from the outputs" "thelounge-backup" "$(lib "$_init resolve_backup_role")"
  assert_eq "mode matches" "0" "$(lib_status "$_init require_backup_mode local")"
  assert_eq "mode mismatch refused" "1" "$(lib_status "$_init require_backup_mode cross_account")"
  assert_eq "local mode has no destination" "" "$(lib "$_init tf_output_opt backup_copy_vault_arn")"
  write_outputs disabled ""
  assert_eq "no vault refused" "1" "$(lib_status "$_init resolve_vault")"
  assert_eq "no role refused" "1" "$(lib_status "$_init resolve_backup_role")"
  write_outputs cross_account thelounge-backup
  assert_eq "destination vault name" "offsite" "$(lib "$_init dest_vault_name")"
  assert_eq "destination region" "us-east-2" "$(lib "$_init dest_region")"
  assert_eq "destination account" "000000000000" "$(lib "$_init dest_account_id")"
}

test_volume_arn() {
  write_outputs local thelounge-backup
  assert_eq "volume arn" "arn:aws:ec2:eu-west-1:123456789012:volume/vol-1" \
    "$(lib "ROOT_DIR='$WORK/root'; init_root; volume_arn eu-west-1 vol-1")"
}

test_state_address() {
  _init="ROOT_DIR='$WORK/root';"
  printf 'module.app.module.storage.aws_ebs_volume.this\nmodule.app.module.storage.aws_s3_bucket.x\n' >"$STUB_STATE"
  assert_eq "one match" "module.app.module.storage.aws_ebs_volume.this" \
    "$(lib "$_init state_address module.storage.aws_ebs_volume.this")"
  assert_eq "no match refused" "1" "$(lib_status "$_init state_address module.storage.aws_ebs_volume.other")"
  printf 'module.a.module.storage.aws_ebs_volume.this\nmodule.b.module.storage.aws_ebs_volume.this\n' >"$STUB_STATE"
  assert_eq "ambiguous refused" "1" "$(lib_status "$_init state_address module.storage.aws_ebs_volume.this")"
  printf 'xmodule.storage.aws_ebs_volume.this\n' >"$STUB_STATE"
  assert_eq "partial label refused" "1" "$(lib_status "$_init state_address module.storage.aws_ebs_volume.this")"
}

# script_output SCRIPT ARGS...: combined output of an operator script with the
# stubs and no root in the environment; always succeeds.
script_output() {
  _script="$1"
  shift
  env THELOUNGE_ROOT= AWS_REGION= PATH="$WORK/bin:$PATH" \
    sh "$SCRIPTS/$_script" "$@" 2>&1 || true
}

script_status() {
  _script="$1"
  shift
  _script_status=0
  env THELOUNGE_ROOT= AWS_REGION= PATH="$WORK/bin:$PATH" \
    sh "$SCRIPTS/$_script" "$@" >/dev/null 2>&1 || _script_status=$?
  echo "$_script_status"
}

test_scripts_require_root() {
  write_outputs local thelounge-backup
  for _s in "deploy.sh" "backup.sh status" "restore.sh list" "azmove.sh finish"; do
    # shellcheck disable=SC2086 # the word list is the script and its arguments
    assert_eq "$_s without a root" "1" "$(script_status $_s)"
    # shellcheck disable=SC2086
    assert_eq "$_s names --root" "1" "$(script_output $_s | grep -c -e '--root')"
  done
}

test_usage_needs_no_root() {
  for _s in azmove.sh backup.sh restore.sh; do
    assert_eq "$_s without arguments prints usage" "0" \
      "$(script_output $_s | grep -c 'no root directory')"
    assert_eq "$_s --help prints usage" "0" \
      "$(script_output $_s --help | grep -c 'no root directory')"
  done
  assert_eq "deploy.sh --help prints its usage line" "1" \
    "$(script_output deploy.sh --help | grep -c -x 'Usage: deploy.sh \[--root DIR\]')"
}

test_script_refusals() {
  write_outputs local thelounge-backup
  assert_eq "drill refuses a local-mode stack" "1" \
    "$(script_output restore.sh --root "$WORK/root" drill | grep -c 'not .cross_account')"
  write_outputs disabled ""
  assert_eq "status refuses a stack with no vault" "1" \
    "$(script_output backup.sh --root "$WORK/root" status | grep -c 'no backup vault')"
}

main() {
  test_select_root
  test_init_root
  test_tf_output
  test_account
  test_backup
  test_volume_arn
  test_state_address
  test_scripts_require_root
  test_usage_needs_no_root
  test_script_refusals
  finish
}

main "$@"
