#!/bin/sh
# Helpers for the operator scripts in this directory. Source keel/common.sh
# first (log, die, require, confirm, aws_as), then this file, then call
# select_root and init_root before anything that reads module outputs.
#
# The operator scripts take the Terraform root that instantiates this module:
# --root DIR as the first argument, or $THELOUNGE_ROOT. They read its outputs
# with `terraform output -json thelounge`, so the root must export the module
# object:
#
#   output "thelounge" { value = module.thelounge }
#
# Terraform runs with -chdir=DIR and inherits TF_DATA_DIR and TF_CLI_ARGS_*
# from the environment, so a root with a non-default data dir or required
# variables works by setting those. No `set -eu` here: callers own it.
# shellcheck shell=sh

readonly OUTPUT_NAME="thelounge"

# select_root ARGS...: sets ROOT_DIR from a leading `--root DIR` or
# $THELOUNGE_ROOT, and ROOT_SHIFT to the arguments consumed (0 or 2).
# shellcheck disable=SC2034 # ROOT_SHIFT is read by the caller
select_root() {
  ROOT_SHIFT=0
  ROOT_DIR="${THELOUNGE_ROOT:-}"
  if [ "${1:-}" = "--root" ]; then
    [ "$#" -ge 2 ] || die "--root needs a directory"
    ROOT_DIR="$2"
    ROOT_SHIFT=2
  fi
  [ -n "$ROOT_DIR" ] ||
    die "no root directory: pass --root DIR or set THELOUNGE_ROOT to the Terraform root that instantiates the module"
  [ -d "$ROOT_DIR" ] || die "root directory not found: $ROOT_DIR"
}

# wants_usage ARGS...: true when, past a leading `--root DIR`, there is no
# subcommand or it is -h or --help.
wants_usage() {
  [ "${1:-}" != "--root" ] || shift 2 2>/dev/null || true
  case "${1:-}" in
  '' | -h | --help) return 0 ;;
  esac
  return 1
}

# Terraform against the selected root.
tf() {
  terraform -chdir="$ROOT_DIR" "$@"
}

# init_root: reads the module object from the root's outputs into OUTPUTS_JSON
# and sets REGION from it.
# shellcheck disable=SC2034 # REGION is read by the sourcing script
init_root() {
  require terraform jq
  OUTPUTS_JSON="$(tf output -json "$OUTPUT_NAME")" ||
    die "could not read output '$OUTPUT_NAME' from $ROOT_DIR: the root must be initialized and applied, and export the module as output \"$OUTPUT_NAME\" { value = module.<name> }"
  REGION="$(tf_output region)"
}

# tf_output_opt NAME -> the module output NAME, or nothing when it is null.
# An output the module does not export at all is an error, not an empty value.
tf_output_opt() {
  printf '%s' "$OUTPUTS_JSON" | jq -e --arg k "$1" 'has($k)' >/dev/null 2>&1 ||
    die "output '$1' not found in the '$OUTPUT_NAME' output of $ROOT_DIR (module version too old, or not applied?)"
  printf '%s' "$OUTPUTS_JSON" | jq -r --arg k "$1" '.[$k] // empty'
}

# tf_output NAME -> the module output NAME; null is an error.
tf_output() {
  _tf_output_value="$(tf_output_opt "$1")" || exit 1
  [ -n "$_tf_output_value" ] || die "output '$1' is null in $ROOT_DIR"
  printf '%s\n' "$_tf_output_value"
}

# arn_field ARN N -> the Nth colon-separated field (4 region, 5 account, 7 name
# for a vault ARN, 6 resource for an IAM ARN).
arn_field() {
  printf '%s' "$1" | cut -d: -f"$2"
}

# resolve_account -> the caller's account id, checked against the stack's (the
# account of the instance role). Catches the right-permissions-wrong-account
# case before it surfaces as an AccessDeniedException from whatever AWS call
# follows.
resolve_account() {
  _resolve_account_got="$(aws sts get-caller-identity --query 'Account' --output text)" ||
    die "could not read caller identity; is AWS_PROFILE set?"
  _resolve_account_want="$(arn_field "$(tf_output instance_role_arn)" 5)"
  [ "$_resolve_account_want" = "$_resolve_account_got" ] ||
    die "wrong account: credentials are for $_resolve_account_got, but the stack is in $_resolve_account_want.
Set AWS_PROFILE to that account's admin profile."
  echo "$_resolve_account_got"
}

# resolve_vault -> the local backup vault name; dies when the stack has none.
resolve_vault() {
  _resolve_vault_name="$(tf_output_opt vault_name)" || exit 1
  [ -n "$_resolve_vault_name" ] ||
    die "no backup vault: backup.mode is 'disabled' (or the stack is not applied)."
  echo "$_resolve_vault_name"
}

# resolve_backup_role -> the name of the AWS Backup service role in this
# account; dies when the stack has none.
resolve_backup_role() {
  _resolve_backup_role_name="$(tf_output_opt backup_role_name)" || exit 1
  [ -n "$_resolve_backup_role_name" ] ||
    die "no backup role: backup.mode is 'disabled' (or the stack is not applied)."
  echo "$_resolve_backup_role_name"
}

# require_backup_mode MODE: dies unless the stack's backup.mode is MODE.
require_backup_mode() {
  _require_backup_mode_have="$(tf_output backup_mode)" || exit 1
  [ "$_require_backup_mode_have" = "$1" ] ||
    die "backup.mode is '$_require_backup_mode_have', not '$1'; this needs a stack with backup.mode = $1."
}

# dest_vault_name, dest_region, dest_account_id -> parts of the off-site copy
# destination vault ARN (backup_copy_vault_arn); empty when the stack has no
# destination.
dest_vault_name() {
  arn_field "$(tf_output_opt backup_copy_vault_arn)" 7
}

dest_region() {
  arn_field "$(tf_output_opt backup_copy_vault_arn)" 4
}

dest_account_id() {
  arn_field "$(tf_output_opt backup_copy_vault_arn)" 5
}

# volume_arn REGION VOLUME_ID -> its ARN. EC2 volume ARNs are fully determined
# by region + account + id (describe-volumes does not return one directly).
volume_arn() {
  printf 'arn:aws:ec2:%s:%s:volume/%s\n' "$1" "$(resolve_account)" "$2"
}

# state_address SUFFIX -> the one state address ending in SUFFIX at a module
# boundary, so scripts need not know what the root named the module.
state_address() {
  _state_address_matches="$(tf state list | awk -v s="$1" '
    $0 == s || (length($0) > length(s) && substr($0, length($0) - length(s) + 1) == s &&
      substr($0, length($0) - length(s), 1) == ".")')"
  [ -n "$_state_address_matches" ] || die "no state address ending in $1 in $ROOT_DIR"
  [ "$(printf '%s\n' "$_state_address_matches" | wc -l)" -eq 1 ] ||
    die "more than one state address ends in $1: $_state_address_matches"
  printf '%s\n' "$_state_address_matches"
}

# eice_run PROFILE REGION INSTANCE_ID CMD: run CMD on the instance over EICE
# SSH and return its exit code. `aws ec2-instance-connect ssh` has no remote
# command option (aws-cli 2.33.20 and 2.37.10), so this pushes a throwaway key
# and drives plain ssh through the same open-tunnel ProxyCommand the CLI uses.
# Host keys are not checked: IAM authenticates the tunnel, and a Spot
# replacement presents a new host key every time.
eice_run() {
  _eice_run_profile="$1"
  _eice_run_region="$2"
  _eice_run_dir="$(mktemp -d)" || return 1
  _eice_run_rc=0
  ssh-keygen -q -t ed25519 -N '' -f "$_eice_run_dir/key" &&
    aws_as "$_eice_run_profile" ec2-instance-connect send-ssh-public-key \
      --region "$_eice_run_region" --instance-id "$3" --instance-os-user ec2-user \
      --ssh-public-key "file://$_eice_run_dir/key.pub" >/dev/null &&
    (
      [ -z "$_eice_run_profile" ] || export AWS_PROFILE="$_eice_run_profile"
      exec ssh -n -i "$_eice_run_dir/key" -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o "ProxyCommand=aws ec2-instance-connect open-tunnel --region $_eice_run_region --instance-id %h" \
        "ec2-user@$3" "$4"
    ) || _eice_run_rc=$?
  rm -rf "$_eice_run_dir"
  return "$_eice_run_rc"
}

# resolve_plan_retention REGION -> "LOCAL_DAYS\tREMOTE_DAYS", read from the
# live plan, so a recovery point taken outside the schedule expires exactly
# like a nightly one. Rules[0] and CopyActions[0] are safe indexes: keel's
# data-volume backup.tf declares exactly one rule with at most one
# copy_action. Callers set BACKUP_PLAN_NAME (repo constant "thelounge-daily")
# before use.
resolve_plan_retention() {
  _resolve_plan_retention_region="$1"
  _resolve_plan_retention_id="$(aws backup list-backup-plans --region "$_resolve_plan_retention_region" \
    --query "BackupPlansList[?BackupPlanName=='$BACKUP_PLAN_NAME'].BackupPlanId | [0]" \
    --output text 2>/dev/null || echo None)"
  if [ -z "$_resolve_plan_retention_id" ] || [ "$_resolve_plan_retention_id" = None ]; then
    die "no backup plan '$BACKUP_PLAN_NAME' in $_resolve_plan_retention_region; is the stack applied?"
  fi
  aws backup get-backup-plan --region "$_resolve_plan_retention_region" --backup-plan-id "$_resolve_plan_retention_id" \
    --query 'BackupPlan.Rules[0].[Lifecycle.DeleteAfterDays, CopyActions[0].Lifecycle.DeleteAfterDays]' \
    --output text
}

# --- AWS Backup / EC2 job polling --------------------------------------------
#
# Shared by backup.sh and restore.sh. KIND is backup|copy|restore -- each
# hides its state in a different place in the describe-*-job response.
# Callers set POLL_SECONDS and HEARTBEAT_EVERY (job-polling cadence) before
# use; PROFILE is optional and only needed when polling a job in another
# account (restore.sh, which juggles two).

job_state() {
  _job_state_id="$1"
  _job_state_kind="$2"
  _job_state_region="$3"
  _job_state_profile="${4:-}"
  case "$_job_state_kind" in
  backup)
    aws_as "$_job_state_profile" backup describe-backup-job --region "$_job_state_region" \
      --backup-job-id "$_job_state_id" --query 'State' --output text 2>/dev/null || echo UNKNOWN
    ;;
  copy)
    aws_as "$_job_state_profile" backup describe-copy-job --region "$_job_state_region" \
      --copy-job-id "$_job_state_id" --query 'CopyJob.State' --output text 2>/dev/null || echo UNKNOWN
    ;;
  restore)
    aws_as "$_job_state_profile" backup describe-restore-job --region "$_job_state_region" \
      --restore-job-id "$_job_state_id" --query 'Status' --output text 2>/dev/null || echo UNKNOWN
    ;;
  esac
}

job_status_message() {
  _job_status_message_id="$1"
  _job_status_message_kind="$2"
  _job_status_message_region="$3"
  _job_status_message_profile="${4:-}"
  case "$_job_status_message_kind" in
  backup)
    aws_as "$_job_status_message_profile" backup describe-backup-job --region "$_job_status_message_region" \
      --backup-job-id "$_job_status_message_id" --query 'StatusMessage' --output text 2>/dev/null || echo "(no status message)"
    ;;
  copy)
    aws_as "$_job_status_message_profile" backup describe-copy-job --region "$_job_status_message_region" \
      --copy-job-id "$_job_status_message_id" --query 'CopyJob.StatusMessage' --output text 2>/dev/null || echo "(no status message)"
    ;;
  restore)
    aws_as "$_job_status_message_profile" backup describe-restore-job --region "$_job_status_message_region" \
      --restore-job-id "$_job_status_message_id" --query 'StatusMessage' --output text 2>/dev/null || echo "(no status message)"
    ;;
  esac
}

job_percent() {
  aws_as "${3:-}" backup describe-backup-job --region "$2" \
    --backup-job-id "$1" --query 'PercentDone' --output text 2>/dev/null || echo "?"
}

# poll_job LABEL TICKS ID KIND REGION [PROFILE]: poll until the job reaches a
# terminal state. Dies on anything but COMPLETED.
poll_job() {
  _poll_job_state=""
  _poll_job_detail=""
  _poll_job_label="$1"
  _poll_job_ticks="$2"
  _poll_job_id="$3"
  _poll_job_kind="$4"
  _poll_job_region="$5"
  _poll_job_profile="${6:-}"

  _poll_job_i=0
  _poll_job_last=""
  while [ "$_poll_job_i" -lt "$_poll_job_ticks" ]; do
    _poll_job_state="$(job_state "$_poll_job_id" "$_poll_job_kind" "$_poll_job_region" "$_poll_job_profile")"

    case "$_poll_job_state" in
    COMPLETED)
      log "$_poll_job_label: COMPLETED"
      return 0
      ;;
    FAILED | PARTIAL | ABORTED | ABORTING | EXPIRED)
      die "$_poll_job_label: $_poll_job_state -- $(job_status_message "$_poll_job_id" "$_poll_job_kind" "$_poll_job_region" "$_poll_job_profile")"
      ;;
    esac

    if [ "$_poll_job_state" != "$_poll_job_last" ] || [ $((_poll_job_i % HEARTBEAT_EVERY)) -eq 0 ]; then
      _poll_job_detail=""
      [ "$_poll_job_kind" != backup ] || _poll_job_detail=" ($(job_percent "$_poll_job_id" "$_poll_job_region" "$_poll_job_profile")% done)"
      log "$_poll_job_label: $_poll_job_state$_poll_job_detail"
      _poll_job_last="$_poll_job_state"
    fi
    _poll_job_i=$((_poll_job_i + 1))
    sleep "$POLL_SECONDS"
  done
  die "$_poll_job_label: still '$_poll_job_state' after ~$((_poll_job_ticks * POLL_SECONDS / 60)) min; giving up
waiting, but the job may still land."
}

# restore_volume REGION SNAPSHOT AZ -> new gp3 volume id on stdout, once
# available. Project=thelounge is REQUIRED: the instance role's AttachVolume
# is gated on that tag (modules/compute/iam.tf). Persistent=true
# drives nothing but is kept so the restored volume matches what the storage
# module declares.
restore_volume() {
  log "Creating gp3 volume from $2 in $3..."
  _restore_volume_new_vol="$(aws ec2 create-volume --region "$1" \
    --snapshot-id "$2" --availability-zone "$3" --volume-type gp3 \
    --tag-specifications "ResourceType=volume,Tags=[{Key=Project,Value=thelounge},{Key=Persistent,Value=true},{Key=Name,Value=thelounge-data}]" \
    --query 'VolumeId' --output text)"
  aws ec2 wait volume-available --region "$1" --volume-ids "$_restore_volume_new_vol"
  echo "$_restore_volume_new_vol"
}
