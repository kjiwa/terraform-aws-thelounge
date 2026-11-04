#!/bin/sh
# Usage: deploy.sh [--root DIR]
#
# Returns once the instance runs the release the last `terraform apply` wrote.
# An apply that changes thelounge_version, node_version or the plugins writes
# desired/desired.zip, which starts the delivery pipeline; this script joins
# that run (or starts one when none followed the object, or the one that did
# failed), then waits through four stages and names the one that fails:
#
#   source           desired/desired.zip exists
#   pipeline         the execution reaches Succeeded; a failed stage and
#                    action are named
#   acknowledgement  the instance writes deployed/current-<arch>.json with the
#                    pointer's sha256 (thelounge-converge.sh does, once
#                    thelounge.service is active on it), at or after the
#                    execution's start; an acknowledgement that already holds
#                    the pointer's sha256 from earlier means the release is
#                    unchanged and counts. Up to 15 minutes.
#   site             the site's URL answers HTTP 200. Up to 2 minutes.
#
# Root: --root DIR, or $THELOUNGE_ROOT, is the Terraform root that
#       instantiates the module (see common.sh). AWS_PROFILE picks the account.
# Needs: aws, terraform, jq, curl.
set -eu

readonly DESIRED_KEY="desired/desired.zip"
readonly ARTIFACT_PREFIX="artifacts"
readonly DEPLOYED_PREFIX="deployed"
readonly ARCHES="arm64 x86_64"
readonly POLL_SECONDS=5
# The S3 event starts the pipeline within seconds of the object being written;
# past this, nothing is coming and the script starts an execution itself.
readonly TRIGGER_WINDOW_SECONDS=60
# GetPipelineExecution is eventually consistent with StartPipelineExecution:
# for a short window after start it can throw
# PipelineExecutionNotFoundException for an execution that exists. Keep
# polling through that error for this long before treating it as real.
readonly NOT_FOUND_GRACE_SECONDS=60
# DEPLOY_TIMEOUT_SECONDS shortens the pipeline and acknowledgement waits; it
# exists for the tests.
readonly PIPELINE_TIMEOUT_SECONDS="${DEPLOY_TIMEOUT_SECONDS:-900}"
readonly ACK_TIMEOUT_SECONDS="${DEPLOY_TIMEOUT_SECONDS:-900}"
readonly SITE_TIMEOUT_SECONDS=120

# Timestamps arrive as ISO 8601 strings with any UTC offset, or as epoch
# numbers; `epoch` reduces both to epoch seconds.
# shellcheck disable=SC2016 # jq variables, not shell
readonly JQ_EPOCH='def epoch:
  if type == "number" then floor
  else
    capture("^(?<base>[0-9T:-]+)(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:[0-9]{2})$") as $c
    | ($c.base + "Z" | fromdateiso8601) as $t
    | (if $c.z == "Z" then 0
       else (($c.z[1:3] | tonumber) * 3600 + ($c.z[4:6] | tonumber) * 60)
            * (if $c.z[0:1] == "-" then -1 else 1 end)
       end) as $o
    | $t - $o
  end;'

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly SCRIPT_DIR
readonly LOG_PREFIX="deploy"
# shellcheck source=keel/common.sh
. "$SCRIPT_DIR/keel/common.sh"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

# Resolved from the root's outputs by main.
PIPELINE_NAME=""
BUCKET=""
URL=""

# Captures stderr from the polling calls, which must be inspected (not just
# printed) to tell a transient error from a real one. Created by main.
ERR=""
WORK=""

# --- source ------------------------------------------------------------------

# object_epoch KEY -> the object's LastModified, as epoch seconds.
object_epoch() {
  aws s3api head-object --bucket "$BUCKET" --key "$1" --region "$REGION" --output json |
    jq -r "$JQ_EPOCH"' .LastModified | epoch'
}

# --- pipeline ----------------------------------------------------------------

# find_execution SINCE -> the id of the latest execution that started at or
# after SINCE (epoch seconds) and is running or succeeded; nothing if none.
# A failed one is not joined: re-running is how a failed build is retried.
find_execution() {
  aws codepipeline list-pipeline-executions --pipeline-name "$PIPELINE_NAME" \
    --region "$REGION" --max-results 20 --output json |
    jq -r --argjson since "$1" "$JQ_EPOCH"'
      [.pipelineExecutionSummaries[]
       | select((.startTime | epoch) >= $since and (.status == "InProgress" or .status == "Succeeded"))]
      | sort_by(.startTime | epoch) | (last // empty) | .pipelineExecutionId'
}

# execution_start ID -> the execution's start, as epoch seconds.
execution_start() {
  aws codepipeline list-pipeline-executions --pipeline-name "$PIPELINE_NAME" \
    --region "$REGION" --max-results 20 --output json |
    jq -r --arg id "$1" "$JQ_EPOCH"'
      .pipelineExecutionSummaries[] | select(.pipelineExecutionId == $id) | .startTime | epoch'
}

start_pipeline() {
  aws codepipeline start-pipeline-execution \
    --name "$PIPELINE_NAME" --region "$REGION" \
    --query 'pipelineExecutionId' --output text
}

# resolve_execution -> the id of the execution for the current desired.zip:
# one that followed it, else (after the trigger window) a new one.
resolve_execution() {
  _resolve_execution_written="$(object_epoch "$DESIRED_KEY")" ||
    die "stage source: s3://$BUCKET/$DESIRED_KEY not found; has the stack been applied?"
  _resolve_execution_age=$(($(date -u +%s) - _resolve_execution_written))
  _resolve_execution_waited=0
  while :; do
    _resolve_execution_id="$(find_execution "$_resolve_execution_written")"
    if [ -n "$_resolve_execution_id" ]; then
      echo "$_resolve_execution_id"
      return 0
    fi
    if [ $((_resolve_execution_age + _resolve_execution_waited)) -ge "$TRIGGER_WINDOW_SECONDS" ]; then
      log "no running or succeeded execution since $DESIRED_KEY was written; starting one."
      start_pipeline
      return 0
    fi
    sleep "$POLL_SECONDS"
    _resolve_execution_waited=$((_resolve_execution_waited + POLL_SECONDS))
  done
}

# One compact "Stage=Status" summary across all stages. Best-effort: a query
# failure here yields an empty summary rather than breaking the watch loop,
# since pipelineExecution.status is what actually decides success or failure.
stage_status_line() {
  aws codepipeline get-pipeline-state \
    --name "$PIPELINE_NAME" --region "$REGION" \
    --query 'stageStates[].[stageName,latestExecution.status]' \
    --output text 2>/dev/null |
    awk '{printf "%s%s=%s", (NR > 1 ? " " : ""), $1, $2}'
}

# failed_actions ID -> "Stage/Action" for each failed action of the execution.
failed_actions() {
  # shellcheck disable=SC2016 # JMESPath backticks, not command substitution
  aws codepipeline list-action-executions --pipeline-name "$PIPELINE_NAME" \
    --region "$REGION" --filter "pipelineExecutionId=$1" \
    --query 'actionExecutionDetails[?status==`Failed`].[stageName,actionName]' \
    --output text 2>/dev/null |
    awk '{printf "%s%s/%s", (NR > 1 ? ", " : ""), $1, $2}'
}

# watch_pipeline ID: returns when the execution succeeds; dies on any other
# terminal status, naming the failed stage and action.
watch_pipeline() {
  _watch_pipeline_waited=0
  _watch_pipeline_prev=""
  while :; do
    if _watch_pipeline_status="$(aws codepipeline get-pipeline-execution \
      --pipeline-name "$PIPELINE_NAME" \
      --pipeline-execution-id "$1" \
      --region "$REGION" \
      --query 'pipelineExecution.status' --output text 2>"$ERR")"; then
      _watch_pipeline_stages="$(stage_status_line)"
      if [ "$_watch_pipeline_status $_watch_pipeline_stages" != "$_watch_pipeline_prev" ]; then
        log "execution $1: $_watch_pipeline_status ($_watch_pipeline_stages)"
        _watch_pipeline_prev="$_watch_pipeline_status $_watch_pipeline_stages"
      fi
      case "$_watch_pipeline_status" in
      Succeeded)
        log "pipeline execution $1 succeeded."
        return 0
        ;;
      Failed | Cancelled | Superseded | Stopped | Stopping)
        die "stage pipeline: execution $1 ended $_watch_pipeline_status (failed: $(failed_actions "$1"))"
        ;;
      esac
    elif grep -q PipelineExecutionNotFoundException "$ERR" &&
      [ "$_watch_pipeline_waited" -lt "$NOT_FOUND_GRACE_SECONDS" ]; then
      : # Read replica hasn't caught up to the start yet; keep polling.
    else
      die "stage pipeline: get-pipeline-execution failed after ${_watch_pipeline_waited}s: $(cat "$ERR")"
    fi
    [ "$_watch_pipeline_waited" -lt "$PIPELINE_TIMEOUT_SECONDS" ] ||
      die "stage pipeline: execution $1 still $_watch_pipeline_status after ${PIPELINE_TIMEOUT_SECONDS}s"
    sleep "$POLL_SECONDS"
    _watch_pipeline_waited=$((_watch_pipeline_waited + POLL_SECONDS))
  done
}

# --- acknowledgement ---------------------------------------------------------

# fetch_object KEY FILE -> the object's LastModified as epoch seconds, with its
# body in FILE; fails when the object does not exist.
fetch_object() {
  _fetch_object_meta="$(aws s3api get-object --bucket "$BUCKET" --key "$1" \
    --region "$REGION" "$2" 2>/dev/null)" || return 1
  printf '%s' "$_fetch_object_meta" | jq -r "$JQ_EPOCH"' .LastModified | epoch'
}

# ack_state ARCH START -> acknowledged | unchanged | nothing, for the
# architecture's acknowledgement against its pointer: the same sha256 written
# at or after START is acknowledged; the same sha256 from before START means
# the pipeline rebuilt the release unchanged.
ack_state() {
  fetch_object "$ARTIFACT_PREFIX/current-$1.json" "$WORK/pointer" >/dev/null || return 0
  _ack_state_acked_at="$(fetch_object "$DEPLOYED_PREFIX/current-$1.json" "$WORK/ack")" || return 0
  [ "$(jq -r '.sha256' "$WORK/pointer")" = "$(jq -r '.sha256 // empty' "$WORK/ack")" ] || return 0
  if [ "$_ack_state_acked_at" -ge "$2" ]; then
    echo "acknowledged"
  else
    echo "unchanged"
  fi
}

# pending_shas -> each architecture's pointer sha256, for messages.
pending_shas() {
  for _pending_shas_arch in $ARCHES; do
    if fetch_object "$ARTIFACT_PREFIX/current-$_pending_shas_arch.json" "$WORK/pointer" >/dev/null; then
      printf '%s=%s ' "$_pending_shas_arch" "$(jq -r '.sha256' "$WORK/pointer")"
    fi
  done
}

# wait_for_ack START: returns once an instance has acknowledged a release.
wait_for_ack() {
  _wait_for_ack_waited=0
  while :; do
    for _wait_for_ack_arch in $ARCHES; do
      case "$(ack_state "$_wait_for_ack_arch" "$1")" in
      acknowledged)
        log "instance acknowledged the $_wait_for_ack_arch release."
        return 0
        ;;
      unchanged)
        log "release unchanged: the $_wait_for_ack_arch instance already runs it."
        return 0
        ;;
      esac
    done
    [ "$_wait_for_ack_waited" -lt "$ACK_TIMEOUT_SECONDS" ] ||
      die "stage acknowledgement: no instance acknowledged the release in ${ACK_TIMEOUT_SECONDS}s (pointers: $(pending_shas)); check that an instance is running and that its converge timer fires (journalctl -u thelounge-converge)"
    sleep "$POLL_SECONDS"
    _wait_for_ack_waited=$((_wait_for_ack_waited + POLL_SECONDS))
  done
}

# --- site --------------------------------------------------------------------

# Only a 200 passes; a redirect or an error page means the app is not serving.
wait_for_site() {
  _wait_for_site_waited=0
  _wait_for_site_code=000
  while :; do
    _wait_for_site_code="$(curl -o /dev/null -s -w '%{http_code}' --max-time 5 "$URL" || echo 000)"
    if [ "$_wait_for_site_code" = 200 ]; then
      log "$URL answers HTTP 200."
      return 0
    fi
    [ "$_wait_for_site_waited" -lt "$SITE_TIMEOUT_SECONDS" ] ||
      die "stage site: $URL answered HTTP $_wait_for_site_code after ${SITE_TIMEOUT_SECONDS}s"
    sleep "$POLL_SECONDS"
    _wait_for_site_waited=$((_wait_for_site_waited + POLL_SECONDS))
  done
}

main() {
  require aws terraform jq curl
  case "${1:-}" in
  -h | --help) usage ;;
  esac
  select_root "$@"
  shift "$ROOT_SHIFT"
  [ "$#" -eq 0 ] || usage
  init_root

  PIPELINE_NAME="$(tf_output pipeline_name)"
  BUCKET="$(tf_output delivery_bucket)"
  URL="$(tf_output url)"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/thelounge-deploy.XXXXXX")"
  ERR="$WORK/err"
  trap 'rm -rf "$WORK"' EXIT

  _main_execution="$(resolve_execution)"
  log "pipeline $PIPELINE_NAME, execution $_main_execution. Watching..."
  watch_pipeline "$_main_execution"
  wait_for_ack "$(execution_start "$_main_execution")"
  wait_for_site
  log "done."
}

main "$@"
