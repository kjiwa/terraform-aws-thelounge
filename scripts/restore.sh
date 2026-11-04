#!/bin/sh
# Getting the data volume back, for every path docs/restore.md describes.
# backup.sh deliberately excludes restores; this is where they live.
#
#   ./restore.sh list                        What's in both vaults (needs
#                                             BACKUP_PROFILE to show the
#                                             off-site one)
#   ./restore.sh local <rp-arn>              Restore from the LOCAL vault,
#                                             into the live subnet's AZ
#   ./restore.sh copy-back <rp-arn>          Pull an off-site recovery point
#                                             back (4-6h), then restore it
#   ./restore.sh offsite <rp-arn>            Restore INSIDE the backup
#                                             account, to a scratch volume
#   ./restore.sh snapshot <snap-id> [az]     Restore a `backup.sh snapshot`
#                                             output into a volume
#   ./restore.sh drill [--with-contents <instance-id>]
#                                             Prove the cross-account pipeline
#                                             end to end; gates locking the
#                                             destination vault
#   ./restore.sh drill-cleanup [manifest]    Remove what `drill` created
#
# Two accounts, two profiles. AWS_PROFILE selects the workload account, same
# as every other script here; BACKUP_PROFILE (new) selects the backup
# account for copy-back, offsite, drill, and drill-cleanup. There is no
# assume_role anywhere in this repo -- a second account always means a
# second profile. Every ARN this script needs (roles, vaults) is
# constructed from the module's outputs + repo-constant resource names, the
# same way backup.sh and the storage module do -- never by reading the backup
# account's own Terraform state, which is exactly what that account exists
# to avoid.
#
# What this script does NOT do, by design:
#   - choose which recovery point to restore (`list` informs; you decide)
#   - scripts/azmove.sh adopt or terraform apply -- putting a restored
#     volume into service is a separate, deliberate gate (docs/az-move.md)
#   - delete the live volume
#   - `drill --with-contents`'s mount and checksum diff need a real shell on
#     a real instance; this script attaches the volume and runs the diff
#     over EICE SSH, but building that instance is on you (the backup
#     account has no VPC or compute of its own, by design)
#
# Restore parameters are not guessable: every recovery point declares what
# it wants (volumeType, volumeSize, encrypted, kmsKeyId), and
# availabilityZone always comes back null. This script reads that metadata
# and patches in the AZ; see restore_metadata below.
#
# Root: --root DIR, or $THELOUNGE_ROOT, is the Terraform root that
#       instantiates the module (see common.sh). Place it before the subcommand.
# Env:  BACKUP_PROFILE (required for copy-back/offsite/drill/drill-cleanup),
#       FORCE=1 (skip prompts).
set -eu

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly SCRIPT_DIR

readonly LOG_PREFIX="restore"
# shellcheck source=keel/common.sh
. "$SCRIPT_DIR/keel/common.sh"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

BACKUP_PROFILE="${BACKUP_PROFILE:-}"
readonly BACKUP_PROFILE

# Repo constants: the backup account's restore role is fixed by keel's
# backup-vault-account module, which this stack's outputs do not describe (a
# name mismatch fails loudly, not silently). The workload account's backup
# role is a module output.
readonly RESTORE_ROLE_NAME="thelounge-restore"   # backup account
readonly BACKUP_PLAN_NAME="thelounge-daily"
readonly DRILL_TAG="thelounge-restore-drill"
# Drill artifacts are throwaway; a short, fixed retention means a failed
# drill-cleanup (an SCP deny -- see "Protecting the backup account with
# SCPs" in docs/cross-account-backup.md -- a transient error, or forgetting
# to run it at all) self-expires in a day instead of riding the full
# production retention window. 1 is the practical minimum AWS Backup accepts
# for a plain (non-cold-storage) EBS lifecycle; if that's ever wrong,
# start-backup-job rejects it immediately and loudly, which beats a silent
# 30-day leak.
readonly DRILL_RETENTION_DAYS=1

# Job polling. Quick jobs (backup/restore/outbound copy) finish in minutes on
# this stack's default 8 GB volume; a copy BACK is documented at 4-6 HOURS,
# sitting in CREATED the whole time with no status message (docs/restore.md)
# -- that is expected, not a hang. One cadence covers both: 30s is fine
# granularity for a multi-hour wait and not too chatty for a multi-minute one.
readonly POLL_SECONDS=30
readonly HEARTBEAT_EVERY=4 # every ~2 min
readonly BACKUP_TICKS=60   # 30 min ceiling
readonly COPY_TICKS=60     # 30 min ceiling
readonly RESTORE_TICKS=60  # 30 min ceiling
readonly COPY_BACK_TICKS=780 # ~6.5h ceiling

# --- shared helpers ------------------------------------------------------

# -> the backup account id from BACKUP_PROFILE's credentials, checked
# against the account in the destination vault ARN. The counterpart to
# common.sh's resolve_account for the second account this script talks to.
resolve_backup_account() {
  require_backup_mode cross_account
  _resolve_backup_account_want="$(dest_account_id)"
  [ -n "$BACKUP_PROFILE" ] ||
    die "BACKUP_PROFILE not set; this needs the backup account's own credentials"
  _resolve_backup_account_got="$(aws_as "$BACKUP_PROFILE" sts get-caller-identity --query Account --output text)" ||
    die "could not read caller identity for BACKUP_PROFILE=$BACKUP_PROFILE"
  [ "$_resolve_backup_account_want" = "$_resolve_backup_account_got" ] ||
    die "wrong account: BACKUP_PROFILE=$BACKUP_PROFILE resolves to $_resolve_backup_account_got, but the stack
copies into $_resolve_backup_account_want."
  echo "$_resolve_backup_account_got"
}

# restore_metadata VAULT RP REGION AZ [PROFILE] -> the --metadata JSON for
# start-restore-job: whatever the recovery point declares
# (get-recovery-point-restore-metadata), with availabilityZone patched in --
# the API returns that field null (docs/restore.md).
restore_metadata() {
  aws_as "${5:-}" backup get-recovery-point-restore-metadata --region "$3" \
    --backup-vault-name "$1" --recovery-point-arn "$2" --query 'RestoreMetadata' --output json |
    jq -c --arg az "$4" '. + {availabilityZone: $az}'
}

# tag_restored_volume REGION VOL [PROFILE]: apply the tag
# start-restore-job's --metadata cannot set. Project=thelounge is required
# before azmove.sh adopt will accept the volume (compute/iam.tf gates
# AttachVolume/DetachVolume on aws:ResourceTag/Project == thelounge).
tag_restored_volume() {
  aws_as "${3:-}" ec2 create-tags --region "$1" --resources "$2" \
    --tags Key=Project,Value=thelounge Key=Name,Value=thelounge-data
}

# restore_into_workload RP -> new volume id on stdout, once available.
# Shared by `local` (restores directly) and `copy-back` (restores what it
# just pulled in) -- both end the same way: restore from the LOCAL vault
# into the live subnet's AZ, then tag it so azmove.sh adopt will take it.
restore_into_workload() {
  _restore_into_workload_rp="$1"
  _restore_into_workload_az="$(aws ec2 describe-volumes --region "$REGION" \
    --volume-ids "$(tf_output data_volume_id)" \
    --query 'Volumes[0].AvailabilityZone' --output text)"

  _restore_into_workload_meta="$(restore_metadata "$VAULT" "$_restore_into_workload_rp" "$REGION" "$_restore_into_workload_az")"
  _restore_into_workload_job="$(aws backup start-restore-job --region "$REGION" \
    --recovery-point-arn "$_restore_into_workload_rp" --iam-role-arn "$ROLE" \
    --resource-type EBS --metadata "$_restore_into_workload_meta" --query 'RestoreJobId' --output text)"
  log "Restore job started: $_restore_into_workload_job"
  poll_job "Restore" "$RESTORE_TICKS" "$_restore_into_workload_job" restore "$REGION"

  _restore_into_workload_vol="$(aws backup describe-restore-job --region "$REGION" --restore-job-id "$_restore_into_workload_job" \
    --query 'CreatedResourceArn' --output text | awk -F/ '{print $NF}')"
  tag_restored_volume "$REGION" "$_restore_into_workload_vol"
  log "Restored volume: $_restore_into_workload_vol (tagged Project=thelounge, in $_restore_into_workload_az -- the live subnet's AZ)"
  echo "$_restore_into_workload_vol"
}

# --- list ------------------------------------------------------------------

cmd_list() {
  [ "$#" -eq 0 ] || die "usage: $0 list"
  _cmd_list_rp_query='reverse(sort_by(RecoveryPoints, &CreationDate))[:10].[CreationDate,Status,RecoveryPointArn]'

  VAULT="$(resolve_vault)"

  log "=== Local vault: $VAULT ($REGION, workload account) ==="
  aws backup list-recovery-points-by-backup-vault --region "$REGION" \
    --backup-vault-name "$VAULT" --query "$_cmd_list_rp_query" --output table

  _cmd_list_mode="$(tf_output backup_mode)"
  _cmd_list_dest="$(tf_output_opt backup_copy_vault_arn)"
  if [ -z "$_cmd_list_dest" ]; then
    log "No off-site copy destination (backup.mode is '$_cmd_list_mode')."
    return 0
  fi
  _cmd_list_dest_vault="$(arn_field "$_cmd_list_dest" 7)"
  _cmd_list_dest_region="$(arn_field "$_cmd_list_dest" 4)"

  if [ "$_cmd_list_mode" = cross_region ]; then
    # Same account, different region -- no second profile needed.
    log "=== Destination vault: $_cmd_list_dest_vault ($_cmd_list_dest_region, same account) ==="
    aws backup list-recovery-points-by-backup-vault --region "$_cmd_list_dest_region" \
      --backup-vault-name "$_cmd_list_dest_vault" --query "$_cmd_list_rp_query" --output table
  elif [ -n "$BACKUP_PROFILE" ]; then
    log "=== Destination vault: $_cmd_list_dest_vault ($_cmd_list_dest_region, backup account) ==="
    aws_as "$BACKUP_PROFILE" backup list-recovery-points-by-backup-vault --region "$_cmd_list_dest_region" \
      --backup-vault-name "$_cmd_list_dest_vault" --query "$_cmd_list_rp_query" --output table
  else
    log "=== Destination vault: $_cmd_list_dest_vault ($_cmd_list_dest_region, backup account) ==="
    log "Set BACKUP_PROFILE to list it -- needs the backup account's own credentials"
    log "(the isolation this design exists for is working as intended)."
  fi
}

# --- local -------------------------------------------------------------------

cmd_local() {
  [ "$#" -eq 1 ] || die "usage: $0 local <recovery-point-arn>"

  _cmd_local_account="$(resolve_account)"
  ROLE="arn:aws:iam::${_cmd_local_account}:role/$(resolve_backup_role)"
  readonly ROLE
  VAULT="$(resolve_vault)"
  readonly VAULT

  _cmd_local_vol="$(restore_into_workload "$1")"
  log "Next: scripts/azmove.sh adopt $_cmd_local_vol <az>  (the AZ is printed above)"
}

# --- copy-back -----------------------------------------------------------------

cmd_copy_back() {
  [ "$#" -eq 1 ] || die "usage: $0 copy-back <recovery-point-arn>"
  _cmd_copy_back_rp="$1"

  _cmd_copy_back_account="$(resolve_account)"
  _cmd_copy_back_backup_account="$(resolve_backup_account)" # also validates BACKUP_PROFILE up front
  ROLE="arn:aws:iam::${_cmd_copy_back_account}:role/$(resolve_backup_role)"
  readonly ROLE
  VAULT="$(resolve_vault)"
  readonly VAULT

  _cmd_copy_back_dest_vault="$(dest_vault_name)"
  [ -n "$_cmd_copy_back_dest_vault" ] ||
    die "the stack has no copy destination; nothing to copy back from"
  _cmd_copy_back_role="arn:aws:iam::${_cmd_copy_back_backup_account}:role/${RESTORE_ROLE_NAME}"

  _cmd_copy_back_lifecycle="$(resolve_plan_retention "$REGION")"
  _cmd_copy_back_retention="$(printf '%s' "$_cmd_copy_back_lifecycle" | cut -f1)"

  log "Copying $_cmd_copy_back_rp back from $_cmd_copy_back_dest_vault ($BACKUP_REGION) to $VAULT ($REGION)..."
  log "This is roughly 60x slower than the outbound direction: budget 4-6 HOURS,"
  log "sitting in CREATED with no status message the whole time. That is"
  log "documented AWS Backup behavior, not a hang -- do not conclude anything"
  log "from a short poll, and do not delete $VAULT while this is queued."
  confirm "Start the copy back?"

  _cmd_copy_back_job="$(aws_as "$BACKUP_PROFILE" backup start-copy-job --region "$BACKUP_REGION" \
    --source-backup-vault-name "$_cmd_copy_back_dest_vault" \
    --destination-backup-vault-arn "arn:aws:backup:${REGION}:${_cmd_copy_back_account}:backup-vault:${VAULT}" \
    --iam-role-arn "$_cmd_copy_back_role" --recovery-point-arn "$_cmd_copy_back_rp" \
    --lifecycle "DeleteAfterDays=$_cmd_copy_back_retention" --query 'CopyJobId' --output text)"
  log "Copy job started: $_cmd_copy_back_job"
  poll_job "Copy back" "$COPY_BACK_TICKS" "$_cmd_copy_back_job" copy "$BACKUP_REGION" "$BACKUP_PROFILE"

  _cmd_copy_back_dest_rp="$(aws_as "$BACKUP_PROFILE" backup describe-copy-job --region "$BACKUP_REGION" \
    --copy-job-id "$_cmd_copy_back_job" --query 'CopyJob.DestinationRecoveryPointArn' --output text)"
  log "Landed in $VAULT as $_cmd_copy_back_dest_rp -- restoring it into the workload account..."

  _cmd_copy_back_new_vol="$(restore_into_workload "$_cmd_copy_back_dest_rp")"
  log "Next: scripts/azmove.sh adopt $_cmd_copy_back_new_vol <az>  (the AZ printed above)"
}

# --- offsite -----------------------------------------------------------------

cmd_offsite() {
  [ "$#" -eq 1 ] || die "usage: $0 offsite <recovery-point-arn>"
  _cmd_offsite_rp="$1"

  _cmd_offsite_backup_account="$(resolve_backup_account)"
  _cmd_offsite_role="arn:aws:iam::${_cmd_offsite_backup_account}:role/${RESTORE_ROLE_NAME}"
  _cmd_offsite_dest_vault="$(dest_vault_name)"

  _cmd_offsite_az="$(aws_as "$BACKUP_PROFILE" ec2 describe-availability-zones --region "$BACKUP_REGION" \
    --query 'AvailabilityZones[0].ZoneName' --output text)"
  log "Restoring $_cmd_offsite_rp to a scratch volume in $_cmd_offsite_az (any AZ is fine -- the backup"
  log "account has no subnet of its own to match)."

  _cmd_offsite_meta="$(restore_metadata "$_cmd_offsite_dest_vault" "$_cmd_offsite_rp" "$BACKUP_REGION" "$_cmd_offsite_az" "$BACKUP_PROFILE")"
  _cmd_offsite_job="$(aws_as "$BACKUP_PROFILE" backup start-restore-job --region "$BACKUP_REGION" \
    --recovery-point-arn "$_cmd_offsite_rp" --iam-role-arn "$_cmd_offsite_role" \
    --resource-type EBS --metadata "$_cmd_offsite_meta" --query 'RestoreJobId' --output text)"
  log "Restore job started: $_cmd_offsite_job"
  poll_job "Offsite restore" "$RESTORE_TICKS" "$_cmd_offsite_job" restore "$BACKUP_REGION" "$BACKUP_PROFILE"

  _cmd_offsite_vol="$(aws_as "$BACKUP_PROFILE" backup describe-restore-job --region "$BACKUP_REGION" \
    --restore-job-id "$_cmd_offsite_job" --query 'CreatedResourceArn' --output text | awk -F/ '{print $NF}')"
  aws_as "$BACKUP_PROFILE" ec2 create-tags --region "$BACKUP_REGION" --resources "$_cmd_offsite_vol" \
    --tags Key=Name,Value=thelounge-data-restored
  log "Restored volume: $_cmd_offsite_vol ($BACKUP_REGION, $_cmd_offsite_az)"
  log "Scratch only -- never attach it anywhere you intend to keep running."
  log "Delete it once you're done:"
  log "  AWS_PROFILE=$BACKUP_PROFILE aws ec2 delete-volume --region $BACKUP_REGION --volume-id $_cmd_offsite_vol"
}

# --- snapshot ------------------------------------------------------------------

cmd_snapshot() {
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    die "usage: $0 snapshot <snapshot-id> [az]"
  fi
  _cmd_snapshot_snap="$1"
  _cmd_snapshot_az="${2:-}"
  [ -n "$_cmd_snapshot_az" ] || _cmd_snapshot_az="$(aws ec2 describe-volumes --region "$REGION" \
    --volume-ids "$(tf_output data_volume_id)" \
    --query 'Volumes[0].AvailabilityZone' --output text)"

  _cmd_snapshot_vol="$(restore_volume "$REGION" "$_cmd_snapshot_snap" "$_cmd_snapshot_az")"
  log "Restored volume: $_cmd_snapshot_vol (in $_cmd_snapshot_az)"
  log "Next: scripts/azmove.sh adopt $_cmd_snapshot_vol $_cmd_snapshot_az"
}

# --- drill -------------------------------------------------------------------
#
# Proves the cross-account pipeline end to end and gates locking the
# destination vault (docs/cross-account-backup.md). Run `drill-cleanup`
# BEFORE locking: once the vault is locked and the OU's SCP denies
# DeleteRecoveryPoint, the drill's own recovery points cannot be removed for
# the full retention window.

DRILL_ACCOUNT=""
DRILL_BACKUP_ACCOUNT=""
DRILL_VAULT=""
DRILL_DEST_VAULT=""
DRILL_EBS_JOB=""
DRILL_EBS_RP=""
DRILL_COPY_JOB=""
DRILL_DEST_RP=""
DRILL_OFFSITE_VOL=""

drill_preflight() {
  require_backup_mode cross_account

  DRILL_ACCOUNT="$(resolve_account)"
  DRILL_BACKUP_ACCOUNT="$(resolve_backup_account)"
  DRILL_VAULT="$(resolve_vault)"
  DRILL_DEST_VAULT="$(dest_vault_name)"

  _drill_preflight_locked="$(aws_as "$BACKUP_PROFILE" backup describe-backup-vault --region "$BACKUP_REGION" \
    --backup-vault-name "$DRILL_DEST_VAULT" --query Locked --output text 2>/dev/null || echo false)"
  [ "$_drill_preflight_locked" != "True" ] ||
    die "$DRILL_DEST_VAULT is already locked. The drill creates recovery points
it must delete afterward; a locked vault won't allow that. Run the drill
BEFORE locking (docs/cross-account-backup.md)."

  log "Preflight OK: workload=$DRILL_ACCOUNT ($REGION), backup=$DRILL_BACKUP_ACCOUNT ($BACKUP_REGION)"
  log "Vault: $DRILL_DEST_VAULT (unlocked)"
}

drill_seed() {
  _drill_seed_role="arn:aws:iam::${DRILL_ACCOUNT}:role/$(resolve_backup_role)"
  _drill_seed_dest="$(tf_output backup_copy_vault_arn)"
  _drill_seed_vol_id="$(tf_output data_volume_id)"
  _drill_seed_vol_arn="$(volume_arn "$REGION" "$_drill_seed_vol_id")"

  # DRILL_RETENTION_DAYS, not the live plan's production retention: this
  # recovery point is throwaway, and a short lifecycle is the backstop when
  # drill-cleanup can't remove it (see the constant's own comment above).
  log "Seeding a recovery point for the drill (crash-consistent, no downtime)..."
  _drill_seed_tags="{\"Project\":\"thelounge\",\"Name\":\"$DRILL_TAG\"}"
  DRILL_EBS_JOB="$(aws backup start-backup-job --region "$REGION" \
    --backup-vault-name "$DRILL_VAULT" --resource-arn "$_drill_seed_vol_arn" --iam-role-arn "$_drill_seed_role" \
    --lifecycle "DeleteAfterDays=$DRILL_RETENTION_DAYS" --recovery-point-tags "$_drill_seed_tags" \
    --query 'BackupJobId' --output text)"
  poll_job "Seed backup" "$BACKUP_TICKS" "$DRILL_EBS_JOB" backup "$REGION"
  DRILL_EBS_RP="$(aws backup describe-backup-job --region "$REGION" \
    --backup-job-id "$DRILL_EBS_JOB" --query RecoveryPointArn --output text)"
  log "Local recovery point: $DRILL_EBS_RP"

  DRILL_COPY_JOB="$(aws backup start-copy-job --region "$REGION" \
    --source-backup-vault-name "$DRILL_VAULT" --destination-backup-vault-arn "$_drill_seed_dest" \
    --iam-role-arn "$_drill_seed_role" --recovery-point-arn "$DRILL_EBS_RP" \
    --lifecycle "DeleteAfterDays=$DRILL_RETENTION_DAYS" --query 'CopyJobId' --output text)"
  poll_job "Outbound copy" "$COPY_TICKS" "$DRILL_COPY_JOB" copy "$REGION"
  DRILL_DEST_RP="$(aws backup describe-copy-job --region "$REGION" \
    --copy-job-id "$DRILL_COPY_JOB" --query 'CopyJob.DestinationRecoveryPointArn' --output text)"
  log "PASS: outbound KMS grants and the copy pipeline work. Landed as $DRILL_DEST_RP"
}

drill_confirm_landing() {
  aws_as "$BACKUP_PROFILE" backup describe-recovery-point --region "$BACKUP_REGION" \
    --backup-vault-name "$DRILL_DEST_VAULT" --recovery-point-arn "$DRILL_DEST_RP" \
    --query 'Status' --output text >/dev/null ||
    die "$DRILL_DEST_RP is not visible in $DRILL_DEST_VAULT from the backup
account's own credentials -- landing did not confirm."
  log "PASS: recovery point confirmed in $DRILL_DEST_VAULT from the backup account's own credentials"
}

drill_restore_offsite() {
  _drill_restore_offsite_role="arn:aws:iam::${DRILL_BACKUP_ACCOUNT}:role/${RESTORE_ROLE_NAME}"
  _drill_restore_offsite_az="$(aws_as "$BACKUP_PROFILE" ec2 describe-availability-zones --region "$BACKUP_REGION" \
    --query 'AvailabilityZones[0].ZoneName' --output text)"

  _drill_restore_offsite_meta="$(restore_metadata "$DRILL_DEST_VAULT" "$DRILL_DEST_RP" "$BACKUP_REGION" "$_drill_restore_offsite_az" "$BACKUP_PROFILE")"
  _drill_restore_offsite_job="$(aws_as "$BACKUP_PROFILE" backup start-restore-job --region "$BACKUP_REGION" \
    --recovery-point-arn "$DRILL_DEST_RP" --iam-role-arn "$_drill_restore_offsite_role" \
    --resource-type EBS --metadata "$_drill_restore_offsite_meta" --query 'RestoreJobId' --output text)"
  poll_job "Offsite restore" "$RESTORE_TICKS" "$_drill_restore_offsite_job" restore "$BACKUP_REGION" "$BACKUP_PROFILE"

  DRILL_OFFSITE_VOL="$(aws_as "$BACKUP_PROFILE" backup describe-restore-job --region "$BACKUP_REGION" \
    --restore-job-id "$_drill_restore_offsite_job" --query 'CreatedResourceArn' --output text | awk -F/ '{print $NF}')"
  _drill_restore_offsite_size="$(aws_as "$BACKUP_PROFILE" ec2 describe-volumes --region "$BACKUP_REGION" \
    --volume-ids "$DRILL_OFFSITE_VOL" --query 'Volumes[0].Size' --output text)"
  case "$_drill_restore_offsite_size" in
  [1-9]*) ;;
  *) die "restored volume $DRILL_OFFSITE_VOL reports size '$_drill_restore_offsite_size', not a positive
number of GiB -- the recovery point may be empty." ;;
  esac
  log "PASS: restored to $DRILL_OFFSITE_VOL ($BACKUP_REGION, $_drill_restore_offsite_az, ${_drill_restore_offsite_size}GiB) --"
  log "the destination CMK and the restore role both work."
}

# The workload account, using its OWN default credentials (not
# BACKUP_PROFILE), attempts to delete from the DESTINATION vault it does not
# own. AccessDeniedException is the pass -- the vault policy grants it
# CopyIntoBackupVault and nothing else (the vault policy in keel's
# backup-vault-account module).
drill_negative_test() {
  set +e
  _drill_negative_test_out="$(aws backup delete-recovery-point --region "$BACKUP_REGION" \
    --backup-vault-name "$DRILL_DEST_VAULT" --recovery-point-arn "$DRILL_DEST_RP" 2>&1)"
  _drill_negative_test_status=$?
  set -e
  [ "$_drill_negative_test_status" -ne 0 ] ||
    die "FAIL: the workload account deleted $DRILL_DEST_RP from $DRILL_DEST_VAULT --
the isolation this design exists for is not real. Check
the backup account's vault policy."
  case "$_drill_negative_test_out" in
  *AccessDenied*)
    log "PASS: the workload account cannot delete from $DRILL_DEST_VAULT (AccessDeniedException, as designed)"
    ;;
  *)
    die "drill inconclusive: delete-recovery-point failed, but not with AccessDenied:
$_drill_negative_test_out"
    ;;
  esac
}

# --with-contents <instance-id>: attach the restored volume to an existing
# instance IN THE BACKUP ACCOUNT and diff its contents against a manifest
# taken from the live volume. Opt-in -- the backup account deliberately has
# no VPC or compute of its own, so this needs an instance you built for the
# purpose, and phases 2-5 above already prove every grant that can fail at
# runtime. Needs live-manifest.txt in the current directory, taken from the
# workload instance beforehand:
#   sudo find /srv/thelounge/data -type f -exec sha256sum {} \; | sort >live-manifest.txt
drill_verify_contents() {
  _drill_verify_contents_instance_id="$1"
  [ -f live-manifest.txt ] ||
    die "live-manifest.txt not found. On the WORKLOAD instance, first run:
  sudo find /srv/thelounge/data -type f -exec sha256sum {} \\; | sort >live-manifest.txt
then copy it here and re-run with --with-contents."
  _drill_verify_contents_dev="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$(printf '%s' "$DRILL_OFFSITE_VOL" | sed 's/-//g')"

  confirm "Attach $DRILL_OFFSITE_VOL to $_drill_verify_contents_instance_id and diff its contents against live-manifest.txt?"
  aws_as "$BACKUP_PROFILE" ec2 attach-volume --region "$BACKUP_REGION" \
    --volume-id "$DRILL_OFFSITE_VOL" --instance-id "$_drill_verify_contents_instance_id" --device /dev/sdf
  aws_as "$BACKUP_PROFILE" ec2 wait volume-in-use --region "$BACKUP_REGION" \
    --volume-ids "$DRILL_OFFSITE_VOL"

  log "Mounting and hashing over EICE SSH (needs an EICE endpoint reachable from $_drill_verify_contents_instance_id)..."
  eice_run "$BACKUP_PROFILE" "$BACKUP_REGION" "$_drill_verify_contents_instance_id" \
    "sudo mkdir -p /mnt/restore && sudo mount -o ro $_drill_verify_contents_dev /mnt/restore && sudo find /mnt/restore -type f -exec sha256sum {} \; | sort" \
    >restored-manifest.txt
  eice_run "$BACKUP_PROFILE" "$BACKUP_REGION" "$_drill_verify_contents_instance_id" \
    "sudo umount /mnt/restore"
  aws_as "$BACKUP_PROFILE" ec2 detach-volume --region "$BACKUP_REGION" \
    --volume-id "$DRILL_OFFSITE_VOL"

  if diff -q live-manifest.txt restored-manifest.txt >/dev/null 2>&1; then
    log "PASS: restored contents match live-manifest.txt byte-for-byte"
  else
    die "FAIL: restored-manifest.txt differs from live-manifest.txt:
$(diff live-manifest.txt restored-manifest.txt || true)"
  fi
}

drill_write_manifest() {
  _drill_write_manifest_manifest="restore-drill-$(date -u +%Y%m%d%H%M%S).json"
  jq -n \
    --arg local_rp "$DRILL_EBS_RP" --arg dest_rp "$DRILL_DEST_RP" \
    --arg dest_vault "$DRILL_DEST_VAULT" --arg backup_region "$BACKUP_REGION" \
    --arg offsite_vol "$DRILL_OFFSITE_VOL" \
    '{local_recovery_point: $local_rp, destination_recovery_point: $dest_rp,
      destination_vault: $dest_vault, backup_region: $backup_region,
      offsite_volume: $offsite_vol, local_recovery_point_deleted: false,
      destination_recovery_point_deleted: false, offsite_volume_deleted: false,
      cleaned: false}' \
    >"$_drill_write_manifest_manifest"
  echo "$_drill_write_manifest_manifest"
}

cmd_drill() {
  _cmd_drill_with_contents=""
  _cmd_drill_instance_id=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --with-contents)
      [ "$#" -ge 2 ] || die "usage: $0 drill [--with-contents <instance-id>]"
      _cmd_drill_with_contents=1
      _cmd_drill_instance_id="$2"
      shift 2
      ;;
    *) die "usage: $0 drill [--with-contents <instance-id>]" ;;
    esac
  done

  drill_preflight
  drill_seed
  drill_confirm_landing
  drill_restore_offsite
  drill_negative_test
  [ -z "$_cmd_drill_with_contents" ] || drill_verify_contents "$_cmd_drill_instance_id"

  _cmd_drill_manifest="$(drill_write_manifest)"
  log ""
  log "=== DRILL PASSED ==="
  log "Artifacts recorded in $_cmd_drill_manifest."
  log "Run '$0 drill-cleanup' BEFORE locking the vault -- a locked vault"
  log "cannot delete what this drill just created. If the protective SCPs"
  log "from docs/cross-account-backup.md are already attached, cleanup may"
  log "not be able to remove the destination recovery point either -- it's"
  log "on a $DRILL_RETENTION_DAYS-day lifecycle and expires on its own regardless."
  log "Once cleanup is done, lock it (docs/cross-account-backup.md):"
  log "  vault_lock = { mode = \"governance\", min_retention_days = 7, max_retention_days = 365 }"
  log "  then apply the backup account's root with AWS_PROFILE=$BACKUP_PROFILE"
}

# CLEANUP_ERR: set by the delete_* helpers below on failure, read by
# explain_cleanup_failure. A plain global since it crosses
# from a helper's return status back to its caller's log message.
CLEANUP_ERR=""

# delete_offsite_volume REGION VOL: 0 if deleted or already gone, 1
# otherwise (CLEANUP_ERR set).
delete_offsite_volume() {
  _delete_offsite_volume_out="$(aws_as "$BACKUP_PROFILE" ec2 delete-volume --region "$1" --volume-id "$2" 2>&1)"
  _delete_offsite_volume_status=$?
  [ "$_delete_offsite_volume_status" -eq 0 ] && return 0
  case "$_delete_offsite_volume_out" in
  *InvalidVolume.NotFound*) return 0 ;; # already gone -- idempotent success
  esac
  CLEANUP_ERR="$_delete_offsite_volume_out"
  return 1
}

# delete_recovery_point PROFILE REGION VAULT RP: 0 if deleted or already
# gone, 1 otherwise (CLEANUP_ERR set). PROFILE may be empty (workload
# account, no override -- see aws_as).
delete_recovery_point() {
  _delete_recovery_point_out="$(aws_as "$1" backup delete-recovery-point --region "$2" \
    --backup-vault-name "$3" --recovery-point-arn "$4" 2>&1)"
  _delete_recovery_point_status=$?
  [ "$_delete_recovery_point_status" -eq 0 ] && return 0
  case "$_delete_recovery_point_out" in
  *ResourceNotFoundException* | *"Cannot find recovery point"*) return 0 ;;
  esac
  CLEANUP_ERR="$_delete_recovery_point_out"
  return 1
}

# explain_cleanup_failure LABEL: logs why a delete_* helper failed, reading
# CLEANUP_ERR it left behind. An SCP explicit deny gets a specific,
# reassuring explanation (this is the exact trap "Protecting the backup
# account with SCPs" in docs/cross-account-backup.md sets, if attached
# before a drill/cleanup cycle has run clean); anything else is a plain WARN.
explain_cleanup_failure() {
  case "$CLEANUP_ERR" in
  *"explicit deny"*"service control policy"*)
    log "  $1: BLOCKED by an SCP explicit deny (the protective SCP from"
    log "    docs/cross-account-backup.md). It can't be deleted manually while"
    log "    that's attached -- but it's on a $DRILL_RETENTION_DAYS-day lifecycle and"
    log "    expires on its own via AWS Backup's service-linked role, which"
    log "    SCPs don't reach. To remove it sooner, detach or scope down that"
    log "    SCP from the management account first."
    ;;
  *)
    log "  $1: WARN -- could not delete: $CLEANUP_ERR"
    ;;
  esac
}

cmd_drill_cleanup() {
  _cmd_drill_cleanup_all_done=""
  [ "$#" -le 1 ] || die "usage: $0 drill-cleanup [manifest]"
  _cmd_drill_cleanup_manifest="${1:-}"
  if [ -z "$_cmd_drill_cleanup_manifest" ]; then
    _cmd_drill_cleanup_manifest="$(find . -maxdepth 1 -name 'restore-drill-*.json' 2>/dev/null | sort | tail -n 1)"
  fi
  [ -f "$_cmd_drill_cleanup_manifest" ] ||
    die "no drill manifest found. Pass one explicitly, or run '$0 drill' first."

  _cmd_drill_cleanup_local_rp="$(jq -r '.local_recovery_point // ""' "$_cmd_drill_cleanup_manifest")"
  _cmd_drill_cleanup_dest_rp="$(jq -r '.destination_recovery_point // ""' "$_cmd_drill_cleanup_manifest")"
  _cmd_drill_cleanup_dest_vault="$(jq -r '.destination_vault // ""' "$_cmd_drill_cleanup_manifest")"
  _cmd_drill_cleanup_backup_region="$(jq -r '.backup_region // ""' "$_cmd_drill_cleanup_manifest")"
  _cmd_drill_cleanup_offsite_vol="$(jq -r '.offsite_volume // ""' "$_cmd_drill_cleanup_manifest")"
  # Per-artifact flags are new; an older manifest without them just means
  # "nothing confirmed deleted yet" -- a harmless retry of whatever remains.
  _cmd_drill_cleanup_local_done="$(jq -r '.local_recovery_point_deleted // false' "$_cmd_drill_cleanup_manifest")"
  _cmd_drill_cleanup_dest_done="$(jq -r '.destination_recovery_point_deleted // false' "$_cmd_drill_cleanup_manifest")"
  _cmd_drill_cleanup_offsite_done="$(jq -r '.offsite_volume_deleted // false' "$_cmd_drill_cleanup_manifest")"

  VAULT="$(tf_output_opt vault_name)"

  log "Manifest: $_cmd_drill_cleanup_manifest"
  log "  local recovery point:       ${_cmd_drill_cleanup_local_rp:-(none)}"
  log "  destination recovery point: ${_cmd_drill_cleanup_dest_rp:-(none)}"
  log "  offsite scratch volume:     ${_cmd_drill_cleanup_offsite_vol:-(none)}"
  confirm "Delete what's left of these drill artifacts?"

  if [ -z "$_cmd_drill_cleanup_offsite_vol" ] || [ "$_cmd_drill_cleanup_offsite_vol" = null ]; then
    _cmd_drill_cleanup_offsite_done=true
  elif [ "$_cmd_drill_cleanup_offsite_done" != true ]; then
    if delete_offsite_volume "$_cmd_drill_cleanup_backup_region" "$_cmd_drill_cleanup_offsite_vol"; then
      _cmd_drill_cleanup_offsite_done=true
      log "  offsite volume $_cmd_drill_cleanup_offsite_vol: deleted (or already gone)"
    else
      explain_cleanup_failure "offsite volume $_cmd_drill_cleanup_offsite_vol"
    fi
  fi

  if [ -z "$_cmd_drill_cleanup_dest_rp" ] || [ "$_cmd_drill_cleanup_dest_rp" = null ]; then
    _cmd_drill_cleanup_dest_done=true
  elif [ "$_cmd_drill_cleanup_dest_done" != true ]; then
    if delete_recovery_point "$BACKUP_PROFILE" "$_cmd_drill_cleanup_backup_region" "$_cmd_drill_cleanup_dest_vault" "$_cmd_drill_cleanup_dest_rp"; then
      _cmd_drill_cleanup_dest_done=true
      log "  destination recovery point $_cmd_drill_cleanup_dest_rp: deleted (or already gone)"
    else
      explain_cleanup_failure "destination recovery point $_cmd_drill_cleanup_dest_rp"
    fi
  fi

  if [ -z "$_cmd_drill_cleanup_local_rp" ] || [ "$_cmd_drill_cleanup_local_rp" = null ] || [ -z "$VAULT" ]; then
    _cmd_drill_cleanup_local_done=true
  elif [ "$_cmd_drill_cleanup_local_done" != true ]; then
    if delete_recovery_point "" "$REGION" "$VAULT" "$_cmd_drill_cleanup_local_rp"; then
      _cmd_drill_cleanup_local_done=true
      log "  local recovery point $_cmd_drill_cleanup_local_rp: deleted (or already gone)"
    else
      explain_cleanup_failure "local recovery point $_cmd_drill_cleanup_local_rp"
    fi
  fi

  if [ "$_cmd_drill_cleanup_local_done" = true ] && [ "$_cmd_drill_cleanup_dest_done" = true ] && [ "$_cmd_drill_cleanup_offsite_done" = true ]; then
    _cmd_drill_cleanup_all_done=true
  else
    _cmd_drill_cleanup_all_done=false
  fi

  jq --argjson local_done "$_cmd_drill_cleanup_local_done" --argjson dest_done "$_cmd_drill_cleanup_dest_done" \
    --argjson offsite_done "$_cmd_drill_cleanup_offsite_done" --argjson cleaned "$_cmd_drill_cleanup_all_done" \
    '.local_recovery_point_deleted = $_cmd_drill_cleanup_local_done
     | .destination_recovery_point_deleted = $_cmd_drill_cleanup_dest_done
     | .offsite_volume_deleted = $_cmd_drill_cleanup_offsite_done
     | .cleaned = $cleaned' \
    "$_cmd_drill_cleanup_manifest" >"$_cmd_drill_cleanup_manifest.tmp" && mv "$_cmd_drill_cleanup_manifest.tmp" "$_cmd_drill_cleanup_manifest"

  if [ "$_cmd_drill_cleanup_all_done" = true ]; then
    log "Cleanup done. Verify: $0 list"
  else
    log "Cleanup incomplete -- see above for what's blocking it and why."
    log "Re-run '$0 drill-cleanup $_cmd_drill_cleanup_manifest' to retry; anything already"
    log "deleted is skipped."
  fi
}

# --- dispatch ----------------------------------------------------------------

main() {
  require aws terraform jq
  ! wants_usage "$@" || usage
  select_root "$@"
  shift "$ROOT_SHIFT"
  init_root
  BACKUP_REGION="$(dest_region)"
  readonly BACKUP_REGION
  [ "$#" -ge 1 ] || usage
  _main_cmd="$1"
  shift
  case "$_main_cmd" in
  list) cmd_list "$@" ;;
  local) cmd_local "$@" ;;
  copy-back) cmd_copy_back "$@" ;;
  offsite) cmd_offsite "$@" ;;
  snapshot) cmd_snapshot "$@" ;;
  drill) cmd_drill "$@" ;;
  drill-cleanup) cmd_drill_cleanup "$@" ;;
  *) die "unknown subcommand '$_main_cmd' (expected: list|local|copy-back|offsite|snapshot|drill|drill-cleanup)" ;;
  esac
}

main "$@"
