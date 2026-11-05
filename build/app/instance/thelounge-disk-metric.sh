#!/bin/sh
# Publishes the larger used-space percentage of / and the data volume as the
# TheLounge/DiskUsedPercent metric, which thelounge-disk-used alarms on. One
# metric covers both mounts; run df on the instance to see which is full.
# Runs hourly from thelounge-disk-metric.timer. Reaches CloudWatch over IPv6
# via AWS_USE_DUALSTACK_ENDPOINT=true (instance.env).
#
# Installed by thelounge-converge.sh as /usr/local/bin/thelounge-disk-metric.
set -eu

readonly INSTANCE_ENV="${INSTANCE_ENV:-/etc/thelounge/instance.env}"
readonly NAMESPACE="TheLounge"
readonly METRIC_NAME="DiskUsedPercent"

_used_percent() {
  df -P "$1" | awk 'NR == 2 { sub(/%/, "", $5); print $5 }'
}

main() {
  # Boot glue not finished: nothing to report yet.
  [ -f "$INSTANCE_ENV" ] || exit 0
  # shellcheck disable=SC1090
  . "$INSTANCE_ENV"

  _main_max="$(_used_percent /)"
  # The data volume mounts during boot glue; before that only / is measured.
  if [ -d "$THELOUNGE_HOME" ]; then
    _main_data="$(_used_percent "$THELOUNGE_HOME")"
    if [ "$_main_data" -gt "$_main_max" ]; then
      _main_max="$_main_data"
    fi
  fi

  aws cloudwatch put-metric-data \
    --namespace "$NAMESPACE" \
    --metric-name "$METRIC_NAME" \
    --unit Percent \
    --value "$_main_max" \
    --region "$REGION"
}

main "$@"
