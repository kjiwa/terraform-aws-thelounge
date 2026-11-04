#!/bin/sh
# App-level self-healing. The ASG's EC2 health check only catches a broken
# instance; a dead app on a healthy instance (node wedged, thelounge.service
# crash-looped past its Restart= budget) is invisible to it. Runs every
# minute from thelounge-health-watchdog.timer and, after THRESHOLD
# consecutive local failures, terminates the instance so the ASG replaces it
# (the new instance's converge timer redeploys the last release).
#
# THRESHOLD=10 (~10 min) is deliberately generous: first boot reaches
# healthy within a few minutes, and a Spot drain stops thelounge well before
# that -- only a genuinely stuck app gets near 10. If the bug ships in the
# release itself, the replacement fails too and this fires again every ~10
# min.
#
# Drains before terminating, same as thelounge-rightsize-watchdog.sh: a
# failed local HTTP health check does not imply the IRC connections are
# dead or that SQLite has nothing buffered, so there is usually still a
# clean QUIT and a flushed database worth getting. thelounge.service's
# TimeoutStopSec=20 caps the cost when the app truly is wedged, so this
# stays a bounded add to an already-generous threshold, not an open-ended
# hang.
#
# Terminates directly rather than marking Unhealthy: one EC2 call needs no
# Auto Scaling grant, and the ASG notices the loss and replaces the instance.
# EC2 is reached over IPv6 via AWS_USE_DUALSTACK_ENDPOINT=true (instance.env).
#
# Installed by thelounge-converge.sh as
# /usr/local/bin/thelounge-health-watchdog.
set -eu

readonly URL="http://127.0.0.1:9000/"
readonly COUNT_FILE="/run/thelounge-health-failcount"
readonly INSTANCE_ENV="/etc/thelounge/instance.env"
readonly THRESHOLD=10
readonly IMDS="http://169.254.169.254/latest"
readonly CURRENT_RELEASE="/opt/thelounge/current"
readonly NO_RELEASE_GRACE_SECONDS=1200

log() {
  echo "[health-watchdog] $*"
}

# Well past the first converge tick plus a normal first-boot install.
past_release_grace() {
  read -r _past_release_grace_up _ </proc/uptime
  [ "${_past_release_grace_up%%.*}" -ge "$NO_RELEASE_GRACE_SECONDS" ]
}

# Boot glue not finished: the app legitimately isn't up yet; don't count.
load_env() {
  [ -f "$INSTANCE_ENV" ] || exit 0
  # shellcheck disable=SC1090
  . "$INSTANCE_ENV"
}

app_healthy() {
  if curl -sf -m 5 -o /dev/null "$URL"; then
    return 0
  fi
  log "Local health check failed."
  return 1
}

# Consecutive-failure count, in /run so a reboot starts clean. Echoes the
# new count.
bump_failures() {
  _bump_failures_count="$(cat "$COUNT_FILE" 2>/dev/null || echo 0)"
  _bump_failures_count=$((_bump_failures_count + 1))
  echo "$_bump_failures_count" >"$COUNT_FILE"
  echo "$_bump_failures_count"
}

drain() {
  log "Stopping thelounge before termination..."
  systemctl stop thelounge || log "systemctl stop failed; syncing anyway"
  sync
}

terminate_self() {
  _terminate_self_token="$(curl -sf -m 2 -X PUT "$IMDS/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60")"
  _terminate_self_instance_id="$(curl -sf -m 2 -H "X-aws-ec2-metadata-token: $_terminate_self_token" \
    "$IMDS/meta-data/instance-id")"
  drain
  log "Terminating $_terminate_self_instance_id..."
  aws ec2 terminate-instances \
    --instance-ids "$_terminate_self_instance_id" \
    --region "$REGION"
}

main() {

  # Converge has not installed a release yet: quiet exit while the instance
  # is young. Past NO_RELEASE_GRACE_SECONDS a release that never landed
  # (converge failing on every tick) is a dead app like any other, so fall
  # through and count it. Checked before load_env since it needs neither
  # instance.env nor a running app.
  if [ ! -e "$CURRENT_RELEASE" ] && ! past_release_grace; then
    exit 0
  fi

  load_env

  if app_healthy; then
    rm -f "$COUNT_FILE"
    return 0
  fi

  _main_count="$(bump_failures)"
  log "$_main_count/$THRESHOLD consecutive failures."
  if [ "$_main_count" -ge "$THRESHOLD" ]; then
    terminate_self
    rm -f "$COUNT_FILE"
  fi
}

main "$@"
