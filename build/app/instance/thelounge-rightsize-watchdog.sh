#!/bin/sh
# Scale-back to the cheapest acceptable Spot pool. The ASG's
# price-capacity-optimized strategy picks a pool only at launch: once a
# stockout lands us on a bigger type, nothing moves us back when the cheap
# pools recover, so a one-day stockout becomes a month of overpaying. This
# makes the accepted fix -- periodic forced replacement -- conditional.
#
# Fires on thelounge-rightsize-watchdog.timer, on a schedule from
# the rightsize_schedule module input (daily by default, down to hourly). Spot only
# -- On-Demand has no allocation to re-run. A no-op if the instance's own
# type is already in PREFERRED_INSTANCE_TYPES (from instance.env).
# Otherwise, two guards bound replacement churn under an aggressive
# schedule (price-capacity-optimized can pick a large pool even while
# smaller ones have capacity):
#
#   1. Uptime cooldown (uptime_ok): skip until the instance is
#      RIGHTSIZE_MIN_UPTIME_HOURS old (default 3). A failed rightsize
#      restarts the clock on the replacement, bounding worst-case churn
#      under any schedule.
#   2. Capacity gate (capacity_ok): skip unless GetSpotPlacementScores rates
#      the preferred types in this AZ >= 5/10 -- do nothing during a genuine
#      stockout and let the next tick act once capacity recovers. If the API
#      errors, proceed as if the gate passed (the cooldown still bounds churn).
#
# Past the guards it stops thelounge cleanly, syncs, and terminates the
# instance directly rather than marking it Unhealthy -- see
# thelounge-health-watchdog for why. If TerminateInstances then errors,
# nothing here restarts thelounge: the health watchdog sees localhost down
# and forces the same replacement shortly after.
#
# Installed by thelounge-converge.sh as
# /usr/local/bin/thelounge-rightsize-watchdog.
set -eu

readonly IMDS="http://169.254.169.254/latest"
readonly INSTANCE_ENV="/etc/thelounge/instance.env"
readonly MIN_PLACEMENT_SCORE=5

log() {
  echo "[rightsize-watchdog] $*"
}

# $1 = path under meta-data.
imds() {
  curl -sf -m 2 -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/meta-data/$1"
}

# Boot glue not finished, or PREFERRED_INSTANCE_TYPES missing (instance.env
# predates this feature): skip quietly, the next replacement writes it.
load_env() {
  [ -f "$INSTANCE_ENV" ] || exit 0
  # shellcheck disable=SC1090
  . "$INSTANCE_ENV"
  if [ -z "${PREFERRED_INSTANCE_TYPES:-}" ]; then
    log "PREFERRED_INSTANCE_TYPES not in $INSTANCE_ENV; skipping."
    exit 0
  fi
}

# On On-Demand (spot_enabled = false) there's no cheaper pool to fall back
# to, only a pointless replacement. An unreadable IMDS also says no (the
# safe direction: no churn, retry next tick).
is_spot() {
  _is_spot_lifecycle="$(imds instance-life-cycle)" || _is_spot_lifecycle=""
  [ "$_is_spot_lifecycle" = "spot" ]
}

is_preferred() {
  case " $PREFERRED_INSTANCE_TYPES " in
  *" $1 "*) return 0 ;;
  esac
  return 1
}

# Guard 1. /proc/uptime's first field has a fractional part; strip it for
# POSIX arithmetic.
uptime_ok() {
  _uptime_ok_min_uptime_s=$((${RIGHTSIZE_MIN_UPTIME_HOURS:-3} * 3600))
  read -r _uptime_ok_uptime_s _ </proc/uptime
  _uptime_ok_uptime_s="${_uptime_ok_uptime_s%.*}"
  [ "$_uptime_ok_uptime_s" -ge "$_uptime_ok_min_uptime_s" ] && return 0
  log "$1 is not preferred, but uptime (${_uptime_ok_uptime_s}s) is under the ${RIGHTSIZE_MIN_UPTIME_HOURS:-3}h cooldown; retrying next tick."
  return 1
}

# Guard 2. A low score means the stockout that bumped us up is still on, so
# replacing now would just land on another big type. An unavailable score
# passes the gate.
capacity_ok() {
  _capacity_ok_az_id="$(imds placement/availability-zone-id)" || _capacity_ok_az_id=""
  _capacity_ok_score=""
  if [ -n "$_capacity_ok_az_id" ]; then
    # Word splitting of the type list is the interface, as in the ASG config.
    # shellcheck disable=SC2086
    _capacity_ok_score="$(aws ec2 get-spot-placement-scores \
      --instance-types $PREFERRED_INSTANCE_TYPES \
      --target-capacity 1 \
      --single-availability-zone \
      --region-names "$REGION" \
      --region "$REGION" \
      --query "SpotPlacementScores[?AvailabilityZoneId=='$_capacity_ok_az_id'].Score | [0]" \
      --output text)" || _capacity_ok_score=""
  fi

  case "$_capacity_ok_score" in
  '' | None)
    log "placement score unavailable; proceeding without the capacity gate."
    return 0
    ;;
  esac
  if [ "$_capacity_ok_score" -lt "$MIN_PLACEMENT_SCORE" ]; then
    log "$1 is not preferred, but the preferred-pool score is $_capacity_ok_score/10; capacity still short, retrying next tick."
    return 1
  fi
  log "preferred-pool placement score $_capacity_ok_score/10; capacity looks available."
}

drain() {
  log "Stopping thelounge before replacement..."
  systemctl stop thelounge || log "systemctl stop failed; syncing anyway"
  sync
}

replace_instance() {
  _replace_instance_instance_id="$(imds instance-id)"
  log "$1 is not preferred ($PREFERRED_INSTANCE_TYPES); replacing $_replace_instance_instance_id."
  drain
  aws ec2 terminate-instances \
    --instance-ids "$_replace_instance_instance_id" \
    --region "$REGION"
  log "Terminated; the ASG replaces from the cheapest available pool."
}

main() {
  load_env

  TOKEN="$(curl -sf -m 2 -X PUT "$IMDS/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60")"
  readonly TOKEN

  is_spot || exit 0
  _main_current_type="$(imds instance-type)"
  is_preferred "$_main_current_type" && exit 0
  uptime_ok "$_main_current_type" || exit 0
  capacity_ok "$_main_current_type" || exit 0
  replace_instance "$_main_current_type"
}

main "$@"
