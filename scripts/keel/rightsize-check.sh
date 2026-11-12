#!/bin/sh
# Read-only decision for the scale-back to the cheapest acceptable Spot pool.
# Usage: rightsize-check.sh REGION ASG_NAME MIN_UPTIME_HOURS
# Exit 0 means replace this instance; any other exit means stay.
#
# An ASG's allocation strategy picks a pool only at launch: once a stockout
# lands the instance on a bigger type, nothing moves it back when the cheap
# pools recover. Periodic forced replacement is the accepted fix; this makes
# it conditional. Callers own the drain and the replacement.
#
# Checks run cheapest first, and any failure or missing datum means stay, so
# a broken API or IAM policy never causes churn:
#   1. is_spot: On-Demand has no allocation to re-run.
#   2. uptime_ok: skip until the instance is MIN_UPTIME_HOURS old. A failed
#      replacement restarts the clock, bounding churn under any schedule.
#   3. cheapest_pool: resolve the ASG's InstanceRequirements to the eligible
#      types and compare current Spot prices in this AZ. Replace only when the
#      cheapest pool costs at most PRICE_MARGIN of this type's price. No type
#      list is kept, so newly released types are judged by price alone.
#   4. capacity_ok: GetSpotPlacementScores must rate the cheapest type in this
#      AZ at least MIN_PLACEMENT_SCORE out of 10; a lower score means the
#      stockout is still on and the replacement would land on another big type.
set -eu

readonly IMDS="http://169.254.169.254/latest"
readonly UPTIME_FILE="${UPTIME_FILE:-/proc/uptime}"
# Intra-tier price spread is about 10-20%, so a 25% margin keeps the cheap
# tier from trading places in a loop.
readonly PRICE_MARGIN="0.75"
readonly MIN_PLACEMENT_SCORE=5

log() {
  echo "[rightsize-check] $*"
}

usage() {
  echo "Usage: rightsize-check.sh REGION ASG_NAME MIN_UPTIME_HOURS" >&2
  exit 2
}

# $1 = path under meta-data.
imds() {
  curl -sf -m 2 -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/meta-data/$1"
}

# An unreadable IMDS also says no.
is_spot() {
  _is_spot_lifecycle="$(imds instance-life-cycle)" || _is_spot_lifecycle=""
  [ "$_is_spot_lifecycle" = "spot" ]
}

# /proc/uptime's first field is seconds with a fractional part; strip it for
# POSIX arithmetic.
uptime_ok() {
  _uptime_ok_min_s=$(($1 * 3600))
  read -r _uptime_ok_s _ <"$UPTIME_FILE"
  _uptime_ok_s="${_uptime_ok_s%.*}"
  [ "$_uptime_ok_s" -ge "$_uptime_ok_min_s" ] && return 0
  log "Uptime (${_uptime_ok_s}s) is under the ${1}h cooldown; staying."
  return 1
}

# Union of the types every ASG override's InstanceRequirements resolves to,
# space-separated. The requirements pass unchanged from
# describe-auto-scaling-groups to get-instance-types-from-instance-requirements.
eligible_types() {
  _eligible_types_count="$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
    --auto-scaling-group-names "$ASG_NAME" \
    --query 'length(AutoScalingGroups[0].MixedInstancesPolicy.LaunchTemplate.Overrides)' \
    --output text)" || return 1
  _eligible_types_req="$(mktemp)"
  _eligible_types_all=""
  _eligible_types_i=0
  while [ "$_eligible_types_i" -lt "$_eligible_types_count" ]; do
    aws autoscaling describe-auto-scaling-groups --region "$REGION" \
      --auto-scaling-group-names "$ASG_NAME" \
      --query "AutoScalingGroups[0].MixedInstancesPolicy.LaunchTemplate.Overrides[$_eligible_types_i].InstanceRequirements" \
      --output json >"$_eligible_types_req" || {
      rm -f "$_eligible_types_req"
      return 1
    }
    _eligible_types_types="$(aws ec2 get-instance-types-from-instance-requirements \
      --region "$REGION" \
      --architecture-types arm64 x86_64 --virtualization-types hvm \
      --instance-requirements "file://$_eligible_types_req" \
      --query 'InstanceTypes[].InstanceType' --output text)" || {
      rm -f "$_eligible_types_req"
      return 1
    }
    _eligible_types_all="$_eligible_types_all $_eligible_types_types"
    _eligible_types_i=$((_eligible_types_i + 1))
  done
  rm -f "$_eligible_types_req"
  echo "$_eligible_types_all" | tr -s ' \t' '\n' | sort -u | tr '\n' ' '
}

# $1 = own instance type, $2 = AZ name. Prints "VERDICT CHEAPEST_TYPE ..." where
# VERDICT is replace, stay or unknown (own or any price missing).
price_verdict() {
  _price_verdict_types="$(eligible_types)" || return 1
  [ -n "$_price_verdict_types" ] || return 1
  # Word splitting of the type list is the interface.
  # shellcheck disable=SC2086
  _price_verdict_prices="$(aws ec2 describe-spot-price-history --region "$REGION" \
    --availability-zone "$2" --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --product-descriptions "Linux/UNIX" --instance-types $_price_verdict_types \
    --query 'SpotPriceHistory[].[InstanceType,SpotPrice]' \
    --output text)" || return 1
  echo "$_price_verdict_prices" | awk -v own="$1" -v margin="$PRICE_MARGIN" '
    NF == 2 {
      if ($1 == own) own_price = $2
      if (min_price == "" || $2 + 0 < min_price + 0) { min_price = $2; min_type = $1 }
    }
    END {
      if (own_price == "" || min_price == "") { print "unknown"; exit }
      printf "%s %s own=%s cheapest=%s\n", \
        (min_price + 0 <= own_price * margin) ? "replace" : "stay", min_type, own_price, min_price
    }'
}

# $1 = type to score, $2 = AZ id. A missing or unparsable score says no.
capacity_ok() {
  _capacity_ok_score="$(aws ec2 get-spot-placement-scores \
    --instance-types "$1" \
    --target-capacity 1 \
    --single-availability-zone \
    --region-names "$REGION" \
    --region "$REGION" \
    --query "SpotPlacementScores[?AvailabilityZoneId=='$2'].Score | [0]" \
    --output text)" || _capacity_ok_score=""
  case "$_capacity_ok_score" in
  '' | None | *[!0-9]*)
    log "Placement score for $1 in $2 unavailable; staying."
    return 1
    ;;
  esac
  if [ "$_capacity_ok_score" -lt "$MIN_PLACEMENT_SCORE" ]; then
    log "Placement score for $1 in $2 is $_capacity_ok_score/10; capacity still short, staying."
    return 1
  fi
  log "Placement score for $1 in $2 is $_capacity_ok_score/10; capacity looks available."
}

main() {
  [ "$#" -eq 3 ] || usage
  case "$3" in
  '' | *[!0-9]*) usage ;;
  esac
  readonly REGION="$1" ASG_NAME="$2"

  TOKEN="$(curl -sf -m 2 -X PUT "$IMDS/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 300")"
  readonly TOKEN

  is_spot || exit 1
  uptime_ok "$3" || exit 1
  _main_type="$(imds instance-type)"
  _main_az="$(imds placement/availability-zone)"
  _main_az_id="$(imds placement/availability-zone-id)"
  _main_verdict="$(price_verdict "$_main_type" "$_main_az")" || {
    log "Could not read the eligible types or Spot prices; staying."
    exit 1
  }
  log "$_main_type in $_main_az: $_main_verdict"
  case "$_main_verdict" in
  replace*) ;;
  *) exit 1 ;;
  esac
  _main_cheapest="${_main_verdict#replace }"
  capacity_ok "${_main_cheapest%% *}" "$_main_az_id" || exit 1
  log "A cheaper pool exists for $_main_type; replace."
}

main "$@"
# Vendored from terraform-aws-keel v0.3.0, scripts/rightsize-check.sh. Do not edit here: change
# keel and re-vendor. scripts/check-keel-drift.sh fails when this copy differs.
