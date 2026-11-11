#!/bin/sh
# Polls IMDSv2 for the EC2 Spot interruption notice (issued ~2 min before
# reclaim) and, on notice, cleanly stops thelounge.service before reclaim
# takes the instance out from under it. Turns a Spot reclaim from a
# crash-stop (SQLite cut mid-write) into a clean shutdown, which is also why
# the nightly backup can stay crash-consistent the rest of the time: the one
# moment that would actually corrupt state closes the database first.
#
# Installed by thelounge-converge.sh as /usr/local/bin/thelounge-spot-drain,
# run by thelounge-spot-drain.service. Covers Spot reclaims only: ASG
# terminations (instance refresh, scale-in, a watchdog's self-terminate) do
# not emit this notice.
set -eu

readonly IMDS="http://169.254.169.254/latest"
readonly POLL_SECONDS=5
readonly DRAIN_MARKER="/run/thelounge-drained"

log() {
  # stdout lands in the journal via the unit.
  echo "[spot-drain] $*"
}

imds_token() {
  curl -sf -m 2 -X PUT "$IMDS/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}

drain() {
  log "Spot interruption notice received; stopping thelounge..."
  # Before the stop, so a converge tick that sees the unit stopped does not
  # start it again.
  : >"$DRAIN_MARKER"
  systemctl stop thelounge || log "systemctl stop failed; syncing anyway"
  sync
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
