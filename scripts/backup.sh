#!/bin/sh
# On-demand backups of the irreplaceable data: the EBS data volume (users,
# IRC network configs, sqlite message logs, uploads). There is no media
# bucket -- everything The Lounge needs lives on this one volume, so this
# script (and the daily plan it complements) is EBS-only.
#
# The daily AWS Backup plan (keel modules/data-volume/backup.tf) already
# takes a crash-consistent recovery point of the volume at 03:00 UTC and
# copies it wherever backup.mode points. This
# script is for what a schedule cannot do: take a restore point RIGHT NOW,
# and take an APP-CONSISTENT one.
#
#   ./backup.sh snapshot [reason]  Raw EBS snapshot of the data volume, taken
#                                  with thelounge.service stopped. App-
#                                  consistent, local only, ~30-60s of
#                                  downtime.
#   ./backup.sh run [reason]       AWS Backup job for the data volume into
#                                  the vault, then copied off-site if
#                                  backup.mode says so. Crash-consistent, no
#                                  downtime, a few minutes.
#   ./backup.sh status             Recent jobs, what is in the local vault,
#                                  and any `snapshot` output still lying
#                                  around.
#
# Picking one:
#
#   snapshot  Before a risky change you might undo within the hour: a
#             thelounge_version bump, a plugin install, manual surgery on
#             the volume. It is the only path that stops the writer first,
#             so it is the only one that captures a quiet filesystem. It is
#             also the only one that is neither off-site nor on a retention
#             clock -- delete it yourself; `status` lists what has piled up.
#
#   run       When you want a real, off-site, retention-managed recovery
#             point without waiting for 03:00: seeding the pipeline after a
#             migration (docs/cross-account-backup.md step 6), or
#             re-proving the copy path still works.
#
# Why `run` does NOT stop the app: `snapshot` can restart the app the moment
# create-snapshot returns, because that call closes the point-in-time
# synchronously. start-backup-job only QUEUES a job, and nothing in its API
# says when the underlying snapshot's point-in-time closes -- holding the
# site down for that would mean inferring it from undocumented job-state
# transitions. So `run` is crash-consistent on purpose, the same consistency
# the daily plan takes. If you need app-consistency, that's `snapshot`.
#
# Two AWS Backup behaviours `run` encodes so you do not have to remember them:
#   - copy_action fires for PLAN-driven jobs ONLY. An on-demand backup job
#     lands in the local vault and stops there; `run` issues the copy itself.
#   - A job started without --lifecycle produces a recovery point that NEVER
#     expires -- silently permanent in the local vault, rejected outright by
#     a locked destination. `run` passes the stack's retention on both halves.
#
# `run` and `status` need the workload account's ADMIN credentials: reading
# Terraform outputs decrypts state, which a ReadOnly profile cannot do. Both
# check the account up front (resolve_account), since the failure otherwise
# surfaces as an AccessDeniedException from start-backup-job.
#
# Restores are deliberately not here: scripts/restore.sh (docs/restore.md)
# covers every recovery scenario, including the restore drill that gates
# locking the destination vault (docs/cross-account-backup.md). Adopting a
# restored volume into the live stack is scripts/azmove.sh (docs/az-move.md).
#
# Root: --root DIR, or $THELOUNGE_ROOT, is the Terraform root that
#       instantiates the module (see common.sh). Place it before the subcommand.
# Env:  FORCE=1 (skip prompts).
set -eu

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly SCRIPT_DIR

readonly LOG_PREFIX="backup"
# shellcheck source=keel/common.sh
. "$SCRIPT_DIR/keel/common.sh"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

# The plan keel's data-volume backup.tf declares: a repo constant. A name
# mismatch fails loudly (resolve_plan_retention dies on the plan). The backup
# role's name is a module output.
readonly BACKUP_PLAN_NAME="thelounge-daily"

# Job polling. EBS-only, so a backup job on this stack's default 8 GB volume
# typically completes in well under 5 min; 60 x 10s = 10 min gives room
# without hanging forever. Outbound copies are faster still, so 10 min is
# generous there too. (A copy BACK runs 4-6 HOURS -- see docs/restore.md --
# but this script never issues one.)
readonly POLL_SECONDS=10
readonly BACKUP_TICKS=60
readonly COPY_TICKS=60
# Heartbeat every 6th tick (~1 min), so a job that sits at one state for
# several minutes still shows a pulse without spamming every tick.
readonly HEARTBEAT_EVERY=6

# The remote commands, run over EC2 Instance Connect Endpoint SSH (no SSM in
# this design -- see network/eice.tf). thelounge.service is the only writer
# to the data volume.
readonly STOP_CMD="sudo systemctl stop thelounge && sync"
readonly START_CMD="sudo systemctl start thelounge"

# Cross-function state: the EXIT trap needs both to decide whether the site
# was left down.
APP_STOPPED=0
INSTANCE_ID=""

# --- snapshot ----------------------------------------------------------------

# run_on_instance COMMENT CMD: run CMD on $INSTANCE_ID over EICE SSH (no SSM in
# this design; see network/eice.tf) and wait for it. Streams stdout/stderr
# directly; the exit code is the remote command's.
run_on_instance() {
  log "$1"
  eice_run "" "$REGION" "$INSTANCE_ID" "$2"
}

start_app() {
  log "Restarting thelounge.service..."
  run_on_instance "backup: restart app" "$START_CMD"
}

# EXIT trap: if anything dies between stop and restart, bring the site back
# up before exiting. `systemctl start` is idempotent, so a spurious restart
# is a no-op.
cleanup() {
  _cleanup_status=$?
  if [ "$APP_STOPPED" = 1 ]; then
    log "Backup did not complete cleanly; bringing the app back up..."
    start_app ||
      log "ERROR: restart failed. On the instance, run: $START_CMD"
  fi
  exit "$_cleanup_status"
}

# $1 = volume id. Stop thelounge.service (the only writer on the volume) on
# the attached instance, so the snapshot is app-consistent. Sets
# INSTANCE_ID and APP_STOPPED.
quiesce_app() {
  INSTANCE_ID="$(aws ec2 describe-volumes --region "$REGION" \
    --volume-ids "$1" \
    --query 'Volumes[0].Attachments[0].InstanceId' --output text)"
  if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
    die "volume $1 has no attached instance to quiesce"
  fi

  confirm "Stop thelounge.service on $INSTANCE_ID for a consistent snapshot? (THE SITE GOES DOWN for ~30-60s)"
  log "Stopping thelounge.service (the writer on the volume)..."
  APP_STOPPED=1
  run_on_instance "backup: stop app" "$STOP_CMD" ||
    die "could not stop the app cleanly; not snapshotting.
If the instance is unreachable over EICE SSH, take a crash-consistent
recovery point instead, with no downtime and off-site: $0 run"
}

# create_snapshot VOLUME REASON -> snapshot id on stdout. Its point-in-time
# is locked in as soon as this returns, so the app can restart before the
# upload.
create_snapshot() {
  _create_snapshot_ts="$(date -u +%Y%m%d%H%M%S)"
  aws ec2 create-snapshot --region "$REGION" --volume-id "$1" \
    --description "on-demand backup $_create_snapshot_ts${2:+: $2}" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Project,Value=thelounge},{Key=Name,Value=thelounge-data-ondemand}]" \
    --query 'SnapshotId' --output text
}

# $1 = snapshot id. The upload runs server-side; the app is already back up.
wait_for_snapshot() {
  log "Waiting for $1 to complete (upload runs server-side)..."
  if aws ec2 wait snapshot-completed --region "$REGION" --snapshot-ids "$1"; then
    return 0
  fi
  _wait_for_snapshot_state="$(aws ec2 describe-snapshots --region "$REGION" \
    --snapshot-ids "$1" --query 'Snapshots[0].State' --output text)"
  [ "$_wait_for_snapshot_state" != "error" ] ||
    die "snapshot $1 failed (state: error); NO backup exists"
  die "snapshot $1 still '$_wait_for_snapshot_state' after ~10 min; the app is back up. Re-check with:
  aws ec2 wait snapshot-completed --region $REGION --snapshot-ids $1"
}

cmd_snapshot() {
  [ "$#" -le 1 ] || die "usage: $0 snapshot [reason]"
  _cmd_snapshot_reason="${1:-}"

  _cmd_snapshot_vol="$(tf_output data_volume_id)"
  _cmd_snapshot_state="$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$_cmd_snapshot_vol" \
    --query 'Volumes[0].State' --output text)"

  trap cleanup EXIT

  case "$_cmd_snapshot_state" in
  available) log "Volume $_cmd_snapshot_vol is detached: snapshotting cold, no downtime." ;;
  in-use) quiesce_app "$_cmd_snapshot_vol" ;;
  *) die "volume $_cmd_snapshot_vol is in state '$_cmd_snapshot_state'; refusing to snapshot" ;;
  esac

  log "Creating snapshot of $_cmd_snapshot_vol..."
  _cmd_snapshot_snap="$(create_snapshot "$_cmd_snapshot_vol" "$_cmd_snapshot_reason")"
  log "Snapshot $_cmd_snapshot_snap initiated; its point-in-time is now locked in."

  if [ "$APP_STOPPED" = 1 ]; then
    start_app
    APP_STOPPED=0
  fi

  wait_for_snapshot "$_cmd_snapshot_snap"
  log "Backup complete: $_cmd_snapshot_snap"
  log "This snapshot is local-only and on NO retention clock; delete it when stale:"
  log "  aws ec2 delete-snapshot --region $REGION --snapshot-id $_cmd_snapshot_snap"
  log "To restore it into a volume, see docs/az-move.md."
}

# --- run ---------------------------------------------------------------------

# start_backup_job RESOURCE_ARN REASON RETENTION -> backup job id.
# --lifecycle is not optional: without it the recovery point never expires.
start_backup_job() {
  _start_backup_job_tags="$(jq -n --arg r "$2" '
    {Project: "thelounge", Name: "thelounge-data-ondemand"}
    + (if $r == "" then {} else {Reason: $r} end)')"
  log "Starting backup job for the data volume (retention ${3}d)"
  aws backup start-backup-job --region "$REGION" \
    --backup-vault-name "$VAULT" \
    --resource-arn "$1" \
    --iam-role-arn "$ROLE" \
    --lifecycle "DeleteAfterDays=$3" \
    --recovery-point-tags "$_start_backup_job_tags" \
    --query 'BackupJobId' --output text
}

# start_copy_job RECOVERY_POINT_ARN RETENTION -> copy job id.
# Note there is NO --resource-arn here, unlike start-backup-job: the
# recovery point ARN already identifies the resource, and passing one is an
# "Unknown options" error. --lifecycle is again mandatory in practice --
# omitted, the copy is rejected outright by a locked destination vault.
start_copy_job() {
  log "Starting copy job for the data volume (remote retention ${2}d)"
  aws backup start-copy-job --region "$REGION" \
    --source-backup-vault-name "$VAULT" \
    --destination-backup-vault-arn "$DEST" \
    --iam-role-arn "$ROLE" \
    --recovery-point-arn "$1" \
    --lifecycle "DeleteAfterDays=$2" \
    --query 'CopyJobId' --output text
}

# $1 = completed backup job id -> the recovery point ARN it produced.
job_recovery_point() {
  aws backup describe-backup-job --region "$REGION" --backup-job-id "$1" \
    --query 'RecoveryPointArn' --output text
}

cmd_run() {
  [ "$#" -le 1 ] || die "usage: $0 run [reason]"
  _cmd_run_reason="${1:-}"

  _cmd_run_account="$(resolve_account)"
  ROLE="arn:aws:iam::${_cmd_run_account}:role/$(resolve_backup_role)"
  readonly ROLE

  VAULT="$(resolve_vault)"
  readonly VAULT

  DEST="$(tf_output_opt backup_copy_vault_arn)"
  readonly DEST

  _cmd_run_lifecycle="$(resolve_plan_retention "$REGION")"
  _cmd_run_retention="$(printf '%s' "$_cmd_run_lifecycle" | cut -f1)"
  _cmd_run_remote_retention="$(printf '%s' "$_cmd_run_lifecycle" | cut -f2)"
  # Belt and braces: a copy destination with no copy_action retention would
  # mean the plan and the stack's mode disagree, and copying without a
  # retention is the one mistake this script exists to prevent.
  [ -z "$DEST" ] || [ "$_cmd_run_remote_retention" != None ] ||
    die "plan '$BACKUP_PLAN_NAME' has no copy_action retention, but backup.mode
implies a copy destination ($DEST). Apply the stack before running this."

  _cmd_run_vol_id="$(tf_output data_volume_id)"
  _cmd_run_vol_arn="$(volume_arn "$REGION" "$_cmd_run_vol_id")"

  log "Vault:   $VAULT ($REGION, account $_cmd_run_account)"
  if [ -n "$DEST" ]; then
    log "Copy to: $DEST"
  else
    log "Copy to: (none -- backup.mode is 'local'; this recovery point stays in"
    log "         this account and region)"
  fi
  log "This is CRASH-consistent, like the daily plan. The site stays up."
  log "For an app-consistent point instead, see: $0 snapshot"
  confirm "Take an on-demand recovery point of the data volume ($_cmd_run_vol_id)?"

  _cmd_run_ebs_job="$(start_backup_job "$_cmd_run_vol_arn" "$_cmd_run_reason" "$_cmd_run_retention")"
  log "Backup job started: $_cmd_run_ebs_job"

  poll_job "EBS data volume backup" "$BACKUP_TICKS" "$_cmd_run_ebs_job" backup "$REGION"

  _cmd_run_ebs_rp="$(job_recovery_point "$_cmd_run_ebs_job")"
  log "Recovery point in $VAULT: $_cmd_run_ebs_rp"

  if [ -z "$DEST" ]; then
    log "Done. No copy configured (backup.mode = local)."
    return 0
  fi

  # The copy is this script's job, not the plan's: copy_action fires for
  # plan-driven jobs only, so this recovery point would otherwise expire in
  # the local vault having never gone off-site -- which would make an
  # on-demand backup silently weaker than a scheduled one, in the one way
  # that matters.
  _cmd_run_ebs_copy="$(start_copy_job "$_cmd_run_ebs_rp" "$_cmd_run_remote_retention")"
  log "Copy job started: $_cmd_run_ebs_copy (outbound runs a few minutes)"
  poll_job "EBS data volume copy" "$COPY_TICKS" "$_cmd_run_ebs_copy" copy "$REGION"

  log "Done. The data volume is backed up locally and copied to:"
  log "  $DEST"
  log "Local copy expires in ${_cmd_run_retention}d, remote in ${_cmd_run_remote_retention}d."
  # `status` cannot show the far side: listing another account's vault needs
  # that account's credentials, which is the isolation working as designed.
  log "Confirm the far side from the DESTINATION account's profile:"
  log "  AWS_PROFILE=<backup-admin> aws backup list-recovery-points-by-backup-vault \\"
  log "    --backup-vault-name $(printf '%s' "$DEST" | cut -d: -f7) \\"
  log "    --region $(printf '%s' "$DEST" | cut -d: -f4)"
}

# --- status ------------------------------------------------------------------

cmd_status() {
  [ "$#" -eq 0 ] || die "usage: $0 status"

  _cmd_status_vault="$(resolve_vault)"
  _cmd_status_dest="$(tf_output_opt backup_copy_vault_arn)"

  log "=== Recent backup jobs ($_cmd_status_vault, $REGION) ==="
  aws backup list-backup-jobs --region "$REGION" \
    --by-backup-vault-name "$_cmd_status_vault" --max-results 10 \
    --query 'reverse(sort_by(BackupJobs, &CreationDate))[].[CreationDate,ResourceType,State,PercentDone]' \
    --output table

  if [ -n "$_cmd_status_dest" ]; then
    log "=== Recent copy jobs -> $_cmd_status_dest ==="
    # A copy job stuck in CREATED here is the documented trap: outbound is
    # a few minutes, but a copy BACK from the backup account runs 4-6
    # HOURS in CREATED with no status message. Do not read CREATED as
    # broken (docs/restore.md).
    aws backup list-copy-jobs --region "$REGION" \
      --by-destination-vault-arn "$_cmd_status_dest" --max-results 10 \
      --query 'reverse(sort_by(CopyJobs, &CreationDate))[].[CreationDate,ResourceType,State,StatusMessage]' \
      --output table
  fi

  log "=== Recovery points in $_cmd_status_vault ==="
  aws backup list-recovery-points-by-backup-vault --region "$REGION" \
    --backup-vault-name "$_cmd_status_vault" \
    --query 'reverse(sort_by(RecoveryPoints, &CreationDate))[:10].[CreationDate,ResourceType,Status,RecoveryPointArn]' \
    --output table

  # The one thing here with no retention clock, so the one thing that
  # silently accumulates. Empty is the good state and is stated outright:
  # `--output table` prints NOTHING for an empty list, which reads as a
  # broken command rather than as "you have no stale snapshots".
  log "=== Raw on-demand snapshots from '$0 snapshot' (NO retention clock) ==="
  _cmd_status_snaps="$(aws ec2 describe-snapshots --region "$REGION" --owner-ids self \
    --filters "Name=tag:Name,Values=thelounge-data-ondemand" \
    --query 'reverse(sort_by(Snapshots, &StartTime))[].[StartTime,SnapshotId,State,Description]' \
    --output table)"
  if [ -n "$_cmd_status_snaps" ]; then
    echo "$_cmd_status_snaps"
    log "Delete any you no longer want: aws ec2 delete-snapshot --region $REGION --snapshot-id <id>"
  else
    log "(none -- nothing to clean up)"
  fi
}

# --- dispatch ----------------------------------------------------------------

main() {
  require aws terraform jq
  ! wants_usage "$@" || usage
  select_root "$@"
  shift "$ROOT_SHIFT"
  init_root
  [ "$#" -ge 1 ] || usage
  _main_cmd="$1"
  shift
  case "$_main_cmd" in
  snapshot) cmd_snapshot "$@" ;;
  run) cmd_run "$@" ;;
  status) cmd_status "$@" ;;
  *) die "unknown subcommand '$_main_cmd' (expected: snapshot|run|status)" ;;
  esac
}

main "$@"
