#!/bin/sh
# Out-of-band surgery on the thelounge data volume: move it to another AZ, or
# re-encrypt it under a new KMS key. Both replace the volume, and the volume
# is prevent_destroy, so neither can be an ordinary apply.
#
# The shape is the same for both: snapshot the live volume, restore the copy
# out-of-band, adopt it into Terraform state, then leave the apply for YOU to
# review. Terraform never destroys the data, and the original volume is kept
# until you delete it.
#
# Subcommands (run in order; stop and inspect between each):
#   score                     Spot placement scores per AZ, to pick a target (read-only)
#   prepare <new-az>          TAKES THE SITE DOWN: scale ASG to 0, snapshot,
#                             restore a gp3 volume from the snapshot in <new-az>
#   rekey   [kms-key-id]      TAKES THE SITE DOWN: scale ASG to 0, snapshot,
#                             copy it re-encrypted under <kms-key-id> (default:
#                             alias/thelounge-data, this stack's data-volume
#                             CMK), restore in the SAME AZ
#   adopt   <new-vol> <az>    back up state, swap the volume in state -> then
#                             YOU set az on the module, run terraform plan /
#                             apply
#   finish  [url]             AFTER your apply: scale ASG to 1, wait InService,
#                             optionally poll <url> for health
#
# So an AZ move is score -> prepare -> adopt -> apply -> finish, and a re-key
# is rekey -> adopt -> apply -> finish. `rekey` is a one-time step for
# deployments whose volume predates opting into cross_account backup: a
# volume on the AWS-managed aws/ebs key cannot be backed up cross-account at
# all, since that key's policy is immutable and unshareable (see
# keel modules/data-volume/main.tf). See docs/cross-account-backup.md. Prod never needs this
# -- it chose cross_account at first apply, so its volume was born on the CMK.
#
# Manual steps this script will NOT do, by design:
#   - choosing the AZ (use `score`, then your judgement)
#   - terraform apply (you review the plan first)
#   - scaling up before apply (the AttachVolume IAM policy is scoped to the
#     volume ARN; it must be updated by apply before the new volume can
#     attach)
#   - deleting the old volume (keep it as a fallback for a few days)
#
# Root: --root DIR, or $THELOUNGE_ROOT, is the Terraform root that
#       instantiates the module (see common.sh). Place it before the subcommand.
# Env:  INSTANCE_TYPES (space-separated, for `score`; default: the live ASG's
#       allow-lists), FORCE=1 (skip prompts).
set -eu

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly SCRIPT_DIR

readonly LOG_PREFIX="azmove"
# shellcheck source=keel/common.sh
. "$SCRIPT_DIR/keel/common.sh"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

# The volume's state address below whatever module call the root names.
readonly VOL_RESOURCE_SUFFIX="module.storage.module.data_volume.aws_ebs_volume.this"
# The Project tag every volume the instance role may attach must carry
# (modules/compute/iam.tf's AttachVolume/DetachVolume condition on
# aws:ResourceTag/Project); a volume created out-of-band by this script must
# set it explicitly since it never goes through the provider's default_tags.
readonly PROJECT_TAG="thelounge"
# cmd_finish's waits: 60 ticks x 10s = ~10 min each, which covers a Spot
# capacity wait plus the on-boot converge tick.
readonly WAIT_TICKS=60
readonly WAIT_SECONDS=10

validate_az() {
  aws ec2 describe-availability-zones --region "$REGION" \
    --query 'AvailabilityZones[].ZoneName' --output text |
    tr '\t' '\n' | grep -qx "$1" || die "'$1' is not an availability zone in $REGION"
}

# volume_attr VOL JMESPATH -> the attribute on stdout, e.g.
# `volume_attr vol-1 AvailabilityZone`.
volume_attr() {
  aws ec2 describe-volumes --region "$REGION" --volume-ids "$1" \
    --query "Volumes[0].$2" --output text
}

# $1 = ASG name, $2 = desired capacity (also the floor, so the ASG cannot
# scale back on its own mid-move).
scale_asg() {
  _scale_asg_asg="$1"
  log "Scaling $_scale_asg_asg to $2..."
  aws autoscaling update-auto-scaling-group --region "$REGION" \
    --auto-scaling-group-name "$_scale_asg_asg" --min-size "$2" --desired-capacity "$2"
}

# --- score -------------------------------------------------------------------

# Instance types to score. $INSTANCE_TYPES (explicit override) wins;
# otherwise read the live ASG's per-arch allow-lists, so the score measures
# what the ASG can actually launch rather than a copy that could drift from
# compute module's derived spec. The ASG carries one override per
# architecture (compute/asg.tf); flattening Overrides[] pulls both.
score_types() {
  if [ -n "${INSTANCE_TYPES:-}" ]; then
    echo "$INSTANCE_TYPES"
    return 0
  fi
  _score_types_asg="$(tf_output asg_name)"
  _score_types_types="$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
    --auto-scaling-group-names "$_score_types_asg" \
    --query 'AutoScalingGroups[0].MixedInstancesPolicy.LaunchTemplate.Overrides[].InstanceRequirements.AllowedInstanceTypes[]' \
    --output text)"
  # shellcheck disable=SC2086
  set -- $_score_types_types
  [ "$#" -gt 0 ] ||
    die "no AllowedInstanceTypes on ASG '$_score_types_asg'; set INSTANCE_TYPES explicitly"
  echo "$*"
}

# $1 = space-separated instance types. Word splitting is the interface here,
# as it is in the ASG config.
fetch_spot_scores() {
  # shellcheck disable=SC2086
  aws ec2 get-spot-placement-scores --region "$REGION" \
    --instance-types $1 \
    --target-capacity 1 \
    --single-availability-zone \
    --region-names "$REGION" \
    --output json
}

# $1 = get-spot-placement-scores JSON. The API reports zone IDs, which are
# per-account; map them back to the zone names the operator actually types.
render_scores() {
  _render_scores_azmap="$(aws ec2 describe-availability-zones --region "$REGION" \
    --query 'AvailabilityZones[].{id:ZoneId,name:ZoneName}' --output json)"
  echo "AZ            SCORE"
  echo "$1" | jq -r --argjson m "$_render_scores_azmap" '
    ($m | map({(.id): .name}) | add) as $names
    | .SpotPlacementScores
    | sort_by(-.Score)[]
    | "\($names[.AvailabilityZoneId] // .AvailabilityZoneId)  \(.Score)"'
}

cmd_score() {
  _cmd_score_types="$(score_types)"
  log "Spot placement scores in $REGION (1-10, higher is better; account- and"
  log "time-specific, NOT a guarantee). Instance types: $_cmd_score_types"
  render_scores "$(fetch_spot_scores "$_cmd_score_types")"
}

# --- prepare -----------------------------------------------------------------

# snapshot_volume VOL DESCRIPTION -> snapshot id on stdout, once complete.
snapshot_volume() {
  log "Creating snapshot of $1..."
  _snapshot_volume_snap="$(aws ec2 create-snapshot --region "$REGION" --volume-id "$1" \
    --description "$2" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Project,Value=$PROJECT_TAG},{Key=Name,Value=thelounge-data-azmove}]" \
    --query 'SnapshotId' --output text)"
  log "Snapshot $_snapshot_volume_snap created; waiting for completion (may take several minutes)..."
  aws ec2 wait snapshot-completed --region "$REGION" --snapshot-ids "$_snapshot_volume_snap"
  echo "$_snapshot_volume_snap"
}

# restore_volume (snapshot -> new gp3 volume, tagged Project=thelounge) is
# shared with scripts/restore.sh and lives in common.sh.

cmd_prepare() {
  [ "$#" -eq 1 ] || die "usage: $0 prepare <new-az>"
  _cmd_prepare_new_az="$1"
  validate_az "$_cmd_prepare_new_az"

  _cmd_prepare_asg="$(tf_output asg_name)"
  _cmd_prepare_vol="$(tf_output data_volume_id)"
  _cmd_prepare_cur_az="$(volume_attr "$_cmd_prepare_vol" AvailabilityZone)"
  [ "$_cmd_prepare_cur_az" != "$_cmd_prepare_new_az" ] || die "volume $_cmd_prepare_vol is already in $_cmd_prepare_new_az"

  log "ASG=$_cmd_prepare_asg  volume=$_cmd_prepare_vol  move $_cmd_prepare_cur_az -> $_cmd_prepare_new_az"
  confirm "Scale the ASG to 0 (THE SITE GOES DOWN), then snapshot and restore the volume into $_cmd_prepare_new_az?"

  scale_asg "$_cmd_prepare_asg" 0
  log "Waiting for the data volume to detach (state: available)..."
  aws ec2 wait volume-available --region "$REGION" --volume-ids "$_cmd_prepare_vol"

  _cmd_prepare_snap="$(snapshot_volume "$_cmd_prepare_vol" "azmove $_cmd_prepare_cur_az->$_cmd_prepare_new_az $(date -u +%Y%m%d%H%M%S)")"
  _cmd_prepare_new_vol="$(restore_volume "$REGION" "$_cmd_prepare_snap" "$_cmd_prepare_new_az")"

  log "New volume ready: $_cmd_prepare_new_vol (in $_cmd_prepare_new_az)"
  log "Original volume $_cmd_prepare_vol is untouched, in $_cmd_prepare_cur_az."
  log "Next: $0 adopt $_cmd_prepare_new_vol $_cmd_prepare_new_az"
}

# --- rekey -------------------------------------------------------------------

# rekey_snapshot SNAP KEY -> re-encrypted snapshot id on stdout, once
# complete. EBS has no re-key-in-place API: copying the snapshot under a new
# key and restoring from the copy is the only path AWS offers. The copy is a
# full one (it crosses a key boundary), so it is slower than the incremental
# snapshot before it -- minutes on this stack's default 8 GB volume.
rekey_snapshot() {
  log "Copying snapshot $1, re-encrypted under $2..."
  _rekey_snapshot_copy="$(aws ec2 copy-snapshot --region "$REGION" \
    --source-region "$REGION" --source-snapshot-id "$1" \
    --encrypted --kms-key-id "$2" \
    --description "rekey of $1" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Project,Value=$PROJECT_TAG},{Key=Name,Value=thelounge-data-rekey}]" \
    --query 'SnapshotId' --output text)"
  log "Snapshot copy $_rekey_snapshot_copy created; waiting for completion (may take several minutes)..."
  aws ec2 wait snapshot-completed --region "$REGION" --snapshot-ids "$_rekey_snapshot_copy"
  echo "$_rekey_snapshot_copy"
}

cmd_rekey() {
  [ "$#" -le 1 ] || die "usage: $0 rekey [kms-key-id]"
  _cmd_rekey_key="${1:-}"
  # Default to alias/thelounge-data, the CMK keel's data-volume module creates for
  # backup.mode = cross_account. A repo constant, not a Terraform output --
  # only resolvable once that apply has created the key (see
  # docs/cross-account-backup.md step 5, a targeted apply before this).
  [ -n "$_cmd_rekey_key" ] || _cmd_rekey_key="$(aws kms describe-key --region "$REGION" \
    --key-id alias/thelounge-data --query KeyMetadata.Arn --output text)" ||
    die "alias/thelounge-data not found; apply backup.mode = cross_account first
(or pass a key id/ARN explicitly): terraform apply -target=<module call>.module.storage.module.data_volume.aws_kms_key.data in $ROOT_DIR"

  _cmd_rekey_asg="$(tf_output asg_name)"
  _cmd_rekey_vol="$(tf_output data_volume_id)"
  _cmd_rekey_cur_az="$(volume_attr "$_cmd_rekey_vol" AvailabilityZone)"
  _cmd_rekey_cur_key="$(volume_attr "$_cmd_rekey_vol" KmsKeyId)"
  [ "$_cmd_rekey_cur_key" != "$_cmd_rekey_key" ] ||
    die "volume $_cmd_rekey_vol is already encrypted under $_cmd_rekey_key; nothing to do"

  log "ASG=$_cmd_rekey_asg  volume=$_cmd_rekey_vol  AZ=$_cmd_rekey_cur_az (unchanged by a re-key)"
  log "  from key: $_cmd_rekey_cur_key"
  log "    to key: $_cmd_rekey_key"
  confirm "Scale the ASG to 0 (THE SITE GOES DOWN), then snapshot the volume and restore it re-encrypted in $_cmd_rekey_cur_az?"

  scale_asg "$_cmd_rekey_asg" 0
  log "Waiting for the data volume to detach (state: available)..."
  aws ec2 wait volume-available --region "$REGION" --volume-ids "$_cmd_rekey_vol"

  _cmd_rekey_snap="$(snapshot_volume "$_cmd_rekey_vol" "rekey $(date -u +%Y%m%d%H%M%S)")"
  _cmd_rekey_copy="$(rekey_snapshot "$_cmd_rekey_snap" "$_cmd_rekey_key")"
  _cmd_rekey_new_vol="$(restore_volume "$REGION" "$_cmd_rekey_copy" "$_cmd_rekey_cur_az")"

  log "New volume ready: $_cmd_rekey_new_vol (in $_cmd_rekey_cur_az, under $_cmd_rekey_key)"
  log "Original volume $_cmd_rekey_vol is untouched, still on $_cmd_rekey_cur_key -- it is your rollback."
  log "Next: $0 adopt $_cmd_rekey_new_vol $_cmd_rekey_cur_az"
}

# --- adopt -------------------------------------------------------------------

# Refuse to adopt a volume that is in the wrong AZ or that the instance role
# could not attach; both are silent-failure-at-boot otherwise.
verify_new_volume() {
  _verify_new_volume_v_az="$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$1" \
    --query 'Volumes[0].AvailabilityZone' --output text)" ||
    die "volume $1 not found"
  [ "$_verify_new_volume_v_az" = "$2" ] || die "$1 is in $_verify_new_volume_v_az, not $2"

  _verify_new_volume_proj="$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$1" \
    --query "Volumes[0].Tags[?Key=='Project']|[0].Value" --output text)"
  [ "$_verify_new_volume_proj" = "$PROJECT_TAG" ] ||
    die "$1 lacks tag Project=$PROJECT_TAG; the instance role cannot attach it"
}

# -> backup path on stdout; the file lands in the current directory.
backup_state() {
  _backup_state_backup="azmove-state-$(date -u +%Y%m%d%H%M%S).json"
  log "Backing up Terraform state to $_backup_state_backup..."
  (umask 077 && tf state pull >"$_backup_state_backup")
  echo "$_backup_state_backup"
}

# Point the volume's state address at the restored volume without letting
# Terraform touch either AWS resource: rm leaves the old volume intact, import
# adopts the new. $1 = state address, $2 = new volume id.
swap_volume_in_state() {
  log "Removing old volume from state (the AWS resource is left intact)..."
  tf state rm "$1"
  log "Importing $2 as $1..."
  tf import "$1" "$2"
}

cmd_adopt() {
  [ "$#" -eq 2 ] || die "usage: $0 adopt <new-vol-id> <new-az>"
  _cmd_adopt_new_vol="$1"
  _cmd_adopt_new_az="$2"
  validate_az "$_cmd_adopt_new_az"
  verify_new_volume "$_cmd_adopt_new_vol" "$_cmd_adopt_new_az"

  _cmd_adopt_address="$(state_address "$VOL_RESOURCE_SUFFIX")"
  _cmd_adopt_backup="$(backup_state)"
  confirm "Swap $_cmd_adopt_address in state to $_cmd_adopt_new_vol? (state surgery; backup at $_cmd_adopt_backup)"
  swap_volume_in_state "$_cmd_adopt_address" "$_cmd_adopt_new_vol"

  log "State updated. NOW DO THIS BY HAND:"
  log "  1) Set az = \"$_cmd_adopt_new_az\" on the module in your root (a re-key leaves az as is)."
  log "  2) terraform plan in $ROOT_DIR"
  log "     Verify: the data volume is a NO-OP (NOT destroyed); the launch"
  log "     template and AttachVolume/DetachVolume IAM policy update to the"
  log "     new volume ARN. After an AZ move the public subnet is also"
  log "     replaced (empty, safe); after a re-key nothing else should move."
  log "     If the volume shows destroy or replace, STOP."
  log "  3) terraform apply in $ROOT_DIR"
  log "  4) $0 --root $ROOT_DIR finish [https://your-site/]"
}

# --- finish ------------------------------------------------------------------

wait_for_inservice() {
  _wait_for_inservice_state=""
  log "Waiting for an InService instance (up to ~10 min)..."
  _wait_for_inservice_i=0
  while [ "$_wait_for_inservice_i" -lt "$WAIT_TICKS" ]; do
    _wait_for_inservice_state="$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
      --auto-scaling-group-names "$1" \
      --query 'AutoScalingGroups[0].Instances[0].LifecycleState' \
      --output text 2>/dev/null || echo None)"
    if [ "$_wait_for_inservice_state" = "InService" ]; then
      log "Instance InService."
      return 0
    fi
    _wait_for_inservice_i=$((_wait_for_inservice_i + 1))
    sleep "$WAIT_SECONDS"
  done
  die "no InService instance after timeout; check the ASG"
}

# Exhausting the poll is a failure, not a pass: an InService instance whose
# converge tick hasn't caught up yet still serves nothing.
wait_for_healthy() {
  log "Polling $1 (the converge timer fires within ~5 min of boot; allow a few minutes)..."
  _wait_for_healthy_code=000
  _wait_for_healthy_i=0
  while [ "$_wait_for_healthy_i" -lt "$WAIT_TICKS" ]; do
    _wait_for_healthy_code="$(curl -o /dev/null -s -w '%{http_code}' --max-time 5 "$1" || echo 000)"
    case "$_wait_for_healthy_code" in
    2[0-9][0-9] | 3[0-9][0-9])
      log "Healthy (HTTP $_wait_for_healthy_code)."
      return 0
      ;;
    esac
    _wait_for_healthy_i=$((_wait_for_healthy_i + 1))
    sleep "$WAIT_SECONDS"
  done
  die "no healthy response from $1 after ~10 min (last: HTTP $_wait_for_healthy_code); the instance is InService but thelounge.service may not be up yet -- check the converge timer's journal over EICE SSH"
}

cmd_finish() {
  _cmd_finish_url="${1:-}"
  _cmd_finish_asg="$(tf_output asg_name)"

  scale_asg "$_cmd_finish_asg" 1
  wait_for_inservice "$_cmd_finish_asg"
  [ -z "$_cmd_finish_url" ] || wait_for_healthy "$_cmd_finish_url"

  log "Move complete. Remaining MANUAL steps:"
  log "  - Verify the site loads and log in works."
  log "  - After a few days of confidence, delete the OLD volume:"
  log "      aws ec2 delete-volume --region $REGION --volume-id <old-vol-id>"
  log "  - prevent_destroy on the volume stays in config; nothing to re-add."
}

# --- dispatch ----------------------------------------------------------------

main() {
  require aws terraform jq curl
  ! wants_usage "$@" || usage
  select_root "$@"
  shift "$ROOT_SHIFT"
  init_root
  [ "$#" -ge 1 ] || usage
  _main_cmd="$1"
  shift
  case "$_main_cmd" in
  score) cmd_score "$@" ;;
  prepare) cmd_prepare "$@" ;;
  rekey) cmd_rekey "$@" ;;
  adopt) cmd_adopt "$@" ;;
  finish) cmd_finish "$@" ;;
  *) die "unknown subcommand '$_main_cmd' (expected: score|prepare|rekey|adopt|finish)" ;;
  esac
}

main "$@"
