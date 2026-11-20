#!/bin/sh
# Polls IMDSv2 for the EC2 Spot interruption notice (issued ~2 min before
# reclaim) and, on notice, cleanly stops thelounge.service, detaches the data
# volume and marks the instance Unhealthy in the ASG, so the replacement
# starts at the notice instead of after EC2 terminates the instance. Turns a
# Spot reclaim from a crash-stop (SQLite cut mid-write) into a clean
# shutdown, which is also why the nightly backup can stay crash-consistent the
# rest of the time: the one moment that would actually corrupt state closes
# the database first.
#
# Installed by thelounge-converge.sh as /usr/local/bin/thelounge-spot-drain,
# run by thelounge-spot-drain.service. Covers Spot reclaims only: ASG
# terminations (instance refresh, scale-in, a watchdog's self-terminate) do
# not emit this notice.
set -eu

readonly IMDS="http://169.254.169.254/latest"
readonly POLL_SECONDS=5
readonly DRAIN_MARKER="${DRAIN_MARKER:-/run/thelounge-drained}"
readonly INSTANCE_ENV="${INSTANCE_ENV:-/etc/thelounge/instance.env}"

log() {
  # stdout lands in the journal via the unit.
  echo "[spot-drain] $*"
}

imds_token() {
  curl -sf -m 2 -X PUT "$IMDS/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}

# Best-effort: every step logs its failure and the drain goes on, because
# the one that must still happen is marking the instance Unhealthy. If that
# fails too, the replacement waits for EC2 to terminate the instance, as it
# did before this drain existed.
stop_app() {
  # Before the stop, so a converge tick that sees the unit stopped does not
  # start it again.
  : >"$DRAIN_MARKER" || log "could not write $DRAIN_MARKER; stopping anyway"
  systemctl stop thelounge || log "systemctl stop failed; syncing anyway"
  sync
}

# The status service holds the volume open, the health and disk timers would
# read the vacated mountpoint as the root filesystem or an unhealthy app, and
# converge would re-enable the disk timer and write to the mount.
detach_data_volume() {
  if [ -z "${EBS_VOLUME_ID:-}" ]; then
    log "no EBS_VOLUME_ID; nothing to detach"
    return 0
  fi
  systemctl stop thelounge-status.service thelounge-health-watchdog.timer \
    thelounge-disk-metric.timer thelounge-converge.timer thelounge-converge.service || log "stopping the volume's readers failed; continuing"
  umount "$DATA_ROOT" || log "umount $DATA_ROOT failed; continuing"
  aws ec2 detach-volume --volume-id "$EBS_VOLUME_ID" --region "$REGION" ||
    log "detach-volume failed; the replacement waits for termination"
}

# The group sets no health check grace period, so the 300 s default would make
# this call a silent no-op in the first 5 minutes after launch.
set_unhealthy() {
  _set_unhealthy_token="$(imds_token)"
  _set_unhealthy_id="$(curl -sf -m 2 -H "X-aws-ec2-metadata-token: $_set_unhealthy_token" \
    "$IMDS/meta-data/instance-id")"
  log "Marking $_set_unhealthy_id Unhealthy in the ASG..."
  aws autoscaling set-instance-health --instance-id "$_set_unhealthy_id" \
    --health-status Unhealthy --no-should-respect-grace-period --region "$REGION"
}

drain() {
  log "Spot interruption notice received; stopping thelounge..."
  stop_app
  # Without instance.env the boot glue never finished: nothing was attached
  # and the region is unknown.
  if [ ! -f "$INSTANCE_ENV" ]; then
    log "$INSTANCE_ENV not found; nothing to detach or mark."
    return 0
  fi
  # shellcheck disable=SC1090
  . "$INSTANCE_ENV"
  detach_data_volume
  set_unhealthy || log "set-instance-health failed; the replacement waits for termination"
  log "Drain complete."
}

main() {
  _main_code=""
  _main_token=""
  log "Watching $IMDS/meta-data/spot/instance-action every ${POLL_SECONDS}s..."
  while :; do
    if [ -z "$_main_token" ]; then
      _main_token="$(imds_token)" || _main_token=""
    fi
    if [ -n "$_main_token" ]; then
      _main_code="$(curl -s -o /dev/null -w '%{http_code}' -m 2 \
        -H "X-aws-ec2-metadata-token: $_main_token" \
        "$IMDS/meta-data/spot/instance-action")" || _main_code=000
      case "$_main_code" in
      200)
        drain
        return 0
        ;;
      401) _main_token="" ;; # Token expired; refetch next loop.
      esac
    fi
    sleep "$POLL_SECONDS"
  done
}

main "$@"
