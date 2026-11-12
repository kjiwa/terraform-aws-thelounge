#!/bin/sh
# Scale-back to the cheapest acceptable Spot pool, on
# thelounge-rightsize-watchdog.timer (the rightsize_schedule module input).
# keel-rightsize-check (vendored from keel) decides whether to replace; this
# script only actuates: it stops thelounge cleanly, syncs, and terminates the
# instance directly rather than marking it Unhealthy -- see
# thelounge-health-watchdog for why. If TerminateInstances then errors,
# nothing here restarts thelounge: the health watchdog sees localhost down
# and forces the same replacement shortly after.
#
# Installed by thelounge-converge.sh as
# /usr/local/bin/thelounge-rightsize-watchdog.
set -eu

readonly IMDS="http://169.254.169.254/latest"
readonly INSTANCE_ENV="${INSTANCE_ENV:-/etc/thelounge/instance.env}"

log() {
  echo "[rightsize-watchdog] $*"
}

# Boot glue not finished, or ASG_NAME missing (instance.env predates this
# script): skip quietly, the next replacement writes it.
load_env() {
  [ -f "$INSTANCE_ENV" ] || exit 0
  # shellcheck disable=SC1090
  . "$INSTANCE_ENV"
  if [ -z "${REGION:-}" ] || [ -z "${ASG_NAME:-}" ]; then
    log "REGION or ASG_NAME not in $INSTANCE_ENV; skipping."
    exit 0
  fi
}

# Exit 1 is the check's ordinary "stay"; any other status (usage, missing
# binary, an API error under its set -e) also stays but is logged, so a broken
# check shows in the journal.
check_says_replace() {
  _check_says_replace_status=0
  keel-rightsize-check "$REGION" "$ASG_NAME" "${RIGHTSIZE_MIN_UPTIME_HOURS:-3}" ||
    _check_says_replace_status=$?
  [ "$_check_says_replace_status" -eq 0 ] && return 0
  [ "$_check_says_replace_status" -eq 1 ] ||
    log "keel-rightsize-check exited $_check_says_replace_status; staying."
  return 1
}

# $1 = path under meta-data.
imds() {
  curl -sf -m 2 -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/meta-data/$1"
}

drain() {
  log "Stopping thelounge before replacement..."
  systemctl stop thelounge || log "systemctl stop failed; syncing anyway"
  sync
}

replace_instance() {
  _replace_instance_instance_id="$(imds instance-id)"
  log "Replacing $_replace_instance_instance_id."
  drain
  aws ec2 terminate-instances \
    --instance-ids "$_replace_instance_instance_id" \
    --region "$REGION"
  log "Terminated; the ASG replaces from the cheapest available pool."
}

main() {
  load_env
  check_says_replace || exit 0

  TOKEN="$(curl -sf -m 2 -X PUT "$IMDS/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60")"
  readonly TOKEN

  replace_instance
}

main "$@"
