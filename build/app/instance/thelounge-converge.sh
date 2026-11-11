#!/bin/sh
# The deploy mechanism: there is no CodeDeploy (a pull timer needs no agent
# or inbound path, and a Spot replacement converges itself). Every tick,
# under an exclusive lock:
# (1) sync this script/unit suite and instance config from S3, installing
# only what changed; (2) fetch the latest app release pointer and, if new,
# download/verify/extract it and flip the "current" symlink; (3) converge
# THELOUNGE_HOME (plugin packages, config.js, new users) from the current
# release; (4) restart thelounge.service if (2) or (3) changed anything, or
# start it if not already running (thelounge.service is never `systemctl
# enable`d, so a reboot leaves it stopped with nothing "changed" -- see
# thelounge.service and user_data.sh.tftpl), unless the Spot drain marker
# exists.
#
# Fires on thelounge-converge.timer. Sources /etc/thelounge/instance.env,
# written by user_data as the last step of boot glue.
set -eu

readonly INSTANCE_ENV="/etc/thelounge/instance.env"
readonly LOCK_FILE="/run/thelounge-converge.lock"
# LIB_DIR, RELEASES_DIR, CURRENT_LINK and APPLIED_FILE are overridable so the
# tests can run against a scratch tree.
readonly LIB_DIR="${LIB_DIR:-/usr/local/lib/thelounge}"
readonly BIN_DIR="/usr/local/bin"
readonly UNIT_DIR="/etc/systemd/system"
readonly RELEASES_DIR="${RELEASES_DIR:-/opt/thelounge/releases}"
readonly CURRENT_LINK="${CURRENT_LINK:-/opt/thelounge/current}"
readonly APPLIED_FILE="${APPLIED_FILE:-/opt/thelounge/applied.sha}"
# Written by thelounge-spot-drain before it stops the unit; /run is tmpfs, so
# a reboot clears it. DRAIN_MARKER is overridable for the tests.
readonly DRAIN_MARKER="${DRAIN_MARKER:-/run/thelounge-drained}"
readonly KEEP_RELEASES=2
readonly THELOUNGE_USER="thelounge"
readonly DEPLOYED_PREFIX="deployed"
readonly INSTANCE_ID_FILE="/var/lib/cloud/data/instance-id"
readonly ACTIVE_TRIES=15
readonly ACTIVE_SECONDS=2

# Set when the app release or THELOUNGE_HOME actually changed; drives the
# restart decision in main. A script/unit update alone does not set this.
RESTART_NEEDED=0

# Set by sync_release when it installs a new release. Gates sync_packages --
# see that function for why the packages mirror must not run on a plain tick.
RELEASE_CHANGED=0

# Set by sync_release: the pointer JSON for this architecture, and the
# architecture. What ack_release acknowledges.
RELEASE_POINTER=""
RELEASE_ARCH=""

log() {
  echo "[converge] $*"
}

load_env() {
  if [ ! -f "$INSTANCE_ENV" ]; then
    log "$INSTANCE_ENV not found; boot glue incomplete, waiting for next tick."
    exit 0
  fi
  # shellcheck disable=SC1090
  . "$INSTANCE_ENV"
}

ensure_thelounge_user() {
  id "$THELOUNGE_USER" >/dev/null 2>&1 && return 0
  log "Creating system user $THELOUNGE_USER..."
  useradd --system --no-create-home --home-dir "$DATA_ROOT" \
    --shell /sbin/nologin "$THELOUNGE_USER"
}

# Not part of the AL2023 base image; only thelounge-converge needs it, so it
# installs lazily here rather than in user_data.
ensure_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  log "Installing jq..."
  dnf install -y jq
}

# ---- step 1: instance scripts/units + desired config ----

sync_instance_files() {
  log "Syncing config/instance/ from s3://$CONFIG_BUCKET/$CONFIG_PREFIX/instance/..."
  mkdir -p "$LIB_DIR"
  if ! aws s3 sync "s3://$CONFIG_BUCKET/$CONFIG_PREFIX/instance/" "$LIB_DIR" \
    --region "$REGION"; then
    log "sync failed; waiting for next tick."
    exit 0
  fi
}

# Installs only what changed vs. what's on disk, so a no-op tick never bumps
# mtimes or forces a reload. Includes this script itself: `install` replaces
# it via a new inode + rename rather than truncating in place, so the
# currently-running copy keeps executing the old, unlinked-but-open inode
# unaffected by the swap.
install_changed() {
  _install_changed_name=""
  _install_changed_dest=""
  _install_changed_changed=0
  _install_changed_status_changed=0

  # *.py alongside *.sh: same drop-the-extension-on-install convention
  # (thelounge-status.py is currently the only one).
  for _install_changed_f in "$LIB_DIR"/*.sh "$LIB_DIR"/*.py; do
    [ -e "$_install_changed_f" ] || continue
    _install_changed_name="$(basename "$_install_changed_f")"
    _install_changed_name="${_install_changed_name%.sh}"
    _install_changed_name="${_install_changed_name%.py}"
    _install_changed_dest="$BIN_DIR/$_install_changed_name"
    if ! cmp -s "$_install_changed_f" "$_install_changed_dest" 2>/dev/null; then
      log "Installing $_install_changed_dest"
      install -m 0755 "$_install_changed_f" "$_install_changed_dest"
      _install_changed_changed=1
      [ "$_install_changed_name" = "thelounge-status" ] && _install_changed_status_changed=1
    fi
  done

  for _install_changed_f in "$LIB_DIR"/*.service "$LIB_DIR"/*.timer; do
    [ -e "$_install_changed_f" ] || continue
    _install_changed_name="$(basename "$_install_changed_f")"
    _install_changed_dest="$UNIT_DIR/$_install_changed_name"
    if ! cmp -s "$_install_changed_f" "$_install_changed_dest" 2>/dev/null; then
      log "Installing $_install_changed_dest"
      install -m 0644 "$_install_changed_f" "$_install_changed_dest"
      _install_changed_changed=1
      [ "$_install_changed_name" = "thelounge-status.service" ] && _install_changed_status_changed=1
    fi
  done

  if [ "$_install_changed_changed" -eq 1 ]; then
    log "Unit files changed; reloading systemd."
    systemctl daemon-reload
  fi

  # Retrofit path: an instance that was already running before this sidecar
  # existed had user_data's install_instance_files run (and enable its unit
  # list) before thelounge-status.service was in that list, so this unit was
  # never `systemctl enable`d there -- it only landed on disk just now, via
  # the loop above. enable --now is what brings it up on such an instance
  # without waiting for a reboot/replacement; it's a no-op (does not
  # restart) on a unit that's already enabled and running, so this is safe
  # to run unconditionally, every tick, not just when something changed.
  if [ -f "$UNIT_DIR/thelounge-status.service" ]; then
    systemctl enable --now thelounge-status.service
  fi

  # Same retrofit for the disk metric timer on instances that predate it.
  if [ -f "$UNIT_DIR/thelounge-disk-metric.timer" ]; then
    systemctl enable --now thelounge-disk-metric.timer
  fi

  # Independent of thelounge.service's own RESTART_NEEDED gate in main(): the
  # status sidecar has no release or THELOUNGE_HOME config to converge, so
  # its own script or unit changing here is its only restart trigger.
  # try-restart, not restart: a no-op if the unit isn't running (the
  # enable --now above already covers that case; this is for a unit that was
  # already running and whose code just changed underneath it).
  if [ "$_install_changed_status_changed" -eq 1 ]; then
    log "thelounge-status changed; restarting it."
    systemctl try-restart thelounge-status.service
  fi
}

# config.js and users.json live directly under config/, not config/instance/
# (scripts/units only), so they're fetched separately to the same staging
# dir. Installed into THELOUNGE_HOME later, in converge_data, once the
# current release is known to exist.
fetch_desired_config() {
  if ! aws s3 cp "s3://$CONFIG_BUCKET/$CONFIG_PREFIX/config.js" \
    "$LIB_DIR/config.js" --region "$REGION" 2>/dev/null; then
    log "config/config.js not present yet; waiting for next tick."
    exit 0
  fi
  if ! aws s3 cp "s3://$CONFIG_BUCKET/$CONFIG_PREFIX/users.json" \
    "$LIB_DIR/users.json" --region "$REGION" 2>/dev/null; then
    log "config/users.json not present yet; waiting for next tick."
    exit 0
  fi
}

# ---- step 2: app release ----

resolve_arch() {
  case "$(uname -m)" in
  aarch64) echo "arm64" ;;
  x86_64) echo "x86_64" ;;
  *)
    log "ERROR: unsupported architecture $(uname -m)"
    exit 1
    ;;
  esac
}

# Keeps the current release plus the newest others, KEEP_RELEASES in all, and
# drops staging directories a crashed tick left behind. The current release is
# excluded by what the link points at, not by age: after a rollback to a
# retained release it is the oldest.
prune_releases() {
  _prune_releases_current="$(readlink -f "$CURRENT_LINK")"
  rm -rf "$RELEASES_DIR"/.incoming-*
  find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d ! -name "$(basename "$_prune_releases_current")" \
    -printf '%T@ %p\n' |
    sort -rn |
    tail -n "+$KEEP_RELEASES" |
    cut -d' ' -f2- |
    while IFS= read -r old; do
      [ -n "$old" ] || continue
      log "Pruning old release $old"
      rm -rf "$old"
    done
}

# Extracts the tarball into a staging directory and renames it into place, so
# a failed extraction never leaves a partial release under its final name.
# Each step returns explicitly: the caller tests the result, which suspends
# `set -e` inside the function.
install_release() {
  _install_release_dir="$RELEASES_DIR/$2"
  _install_release_staging="$RELEASES_DIR/.incoming-$2"
  rm -rf "$_install_release_staging"
  mkdir -p "$_install_release_staging" || return 1
  tar -xzf "$1" -C "$_install_release_staging" || return 1
  echo "$2" >"$_install_release_staging/.sha" || return 1
  rm -rf "$_install_release_dir"
  mv "$_install_release_staging" "$_install_release_dir"
}

# Repoints CURRENT_LINK with a rename, which replaces the link atomically; an
# in-place `ln -sfn` unlinks first and leaves a window with no current release.
activate_release() {
  rm -f "$CURRENT_LINK.new"
  ln -s "$1" "$CURRENT_LINK.new"
  mv -T "$CURRENT_LINK.new" "$CURRENT_LINK"
}

# Records the sha the running service was last started on. A release that is
# activated but not recorded here (the tick failed before the restart) is
# restarted on the next tick instead of being mistaken for already running.
mark_applied() {
  [ -f "$CURRENT_LINK/.sha" ] || return 0
  cp "$CURRENT_LINK/.sha" "$APPLIED_FILE"
}

# current-$ARCH.json (written by the delivery pipeline's CodeBuild project)
# may not exist yet -- a quiet no-op, not an error.
sync_release() {
  _sync_release_arch="$(resolve_arch)"
  _sync_release_pointer_key="$ARTIFACT_PREFIX/current-$_sync_release_arch.json"

  _sync_release_pointer_json="$(aws s3 cp "s3://$CONFIG_BUCKET/$_sync_release_pointer_key" - \
    --region "$REGION" 2>/dev/null)" || {
    log "no $_sync_release_pointer_key yet (first build not finished); waiting for next tick."
    exit 0
  }

  _sync_release_artifact_key="$(echo "$_sync_release_pointer_json" | jq -r '.artifact_key')"
  _sync_release_sha="$(echo "$_sync_release_pointer_json" | jq -r '.sha256')"
  if [ -z "$_sync_release_artifact_key" ] || [ "$_sync_release_artifact_key" = "null" ] ||
    [ -z "$_sync_release_sha" ] || [ "$_sync_release_sha" = "null" ]; then
    log "ERROR: malformed $_sync_release_pointer_key; waiting for next tick."
    exit 0
  fi
  RELEASE_POINTER="$_sync_release_pointer_json"
  RELEASE_ARCH="$_sync_release_arch"

  # An instance that predates the marker records the release it is running
  # before this tick can activate another.
  [ -f "$APPLIED_FILE" ] || mark_applied
  _sync_release_current_sha=""
  if [ -f "$CURRENT_LINK/.sha" ]; then
    _sync_release_current_sha="$(cat "$CURRENT_LINK/.sha")"
  fi
  if [ "$_sync_release_sha" = "$_sync_release_current_sha" ]; then
    log "Release $_sync_release_sha already current."
    if [ -f "$APPLIED_FILE" ] && [ "$(cat "$APPLIED_FILE")" != "$_sync_release_sha" ]; then
      log "Release $_sync_release_sha was activated but never started; restarting."
      RESTART_NEEDED=1
      RELEASE_CHANGED=1
    fi
    return 0
  fi

  log "New release $_sync_release_sha (was ${_sync_release_current_sha:-none}); downloading $_sync_release_artifact_key..."
  _sync_release_tmp_tar="$(mktemp /tmp/thelounge-release.XXXXXX.tar.gz)"
  if ! aws s3 cp "s3://$CONFIG_BUCKET/$_sync_release_artifact_key" "$_sync_release_tmp_tar" \
    --region "$REGION"; then
    log "ERROR: $_sync_release_pointer_key references $_sync_release_artifact_key, which could not be downloaded."
    rm -f "$_sync_release_tmp_tar"
    exit 1
  fi

  if ! echo "$_sync_release_sha  $_sync_release_tmp_tar" | sha256sum -c - >/dev/null; then
    log "ERROR: checksum mismatch for $_sync_release_artifact_key; discarding."
    rm -f "$_sync_release_tmp_tar"
    exit 1
  fi

  mkdir -p "$RELEASES_DIR"
  if ! install_release "$_sync_release_tmp_tar" "$_sync_release_sha"; then
    log "ERROR: could not extract $_sync_release_artifact_key."
    rm -rf "$RELEASES_DIR"/.incoming-*
    rm -f "$_sync_release_tmp_tar"
    exit 1
  fi
  rm -f "$_sync_release_tmp_tar"

  activate_release "$RELEASES_DIR/$_sync_release_sha"
  log "Release $_sync_release_sha is now current."
  prune_releases
  RESTART_NEEDED=1
  RELEASE_CHANGED=1
}

# ---- step 3: converge THELOUNGE_HOME from the current release ----

# Mirrors the release's packages/ into THELOUNGE_HOME/packages/ (--delete),
# so a plugin removed from thelounge_plugins disappears here too. Nothing else under
# THELOUNGE_HOME is touched.
#
# Gated on RELEASE_CHANGED: The Lounge creates its own node_modules/ under
# packages/ at startup, with no counterpart in the release. Mirroring every
# tick deleted that directory each time, itemized as a change, forcing a
# restart every 5 minutes (which just recreated it for the next tick to
# delete again). A plugin add/remove always ships as a new release, so
# gating on release change loses no functionality.
sync_packages() {
  [ -d "$CURRENT_LINK/packages" ] || return 0
  if [ "$RELEASE_CHANGED" -ne 1 ] &&
    [ -f "$THELOUNGE_HOME/packages/package.json" ]; then
    return 0
  fi
  mkdir -p "$THELOUNGE_HOME/packages"
  # --no-owner --no-group: the release extracts as root, but converge_data
  # chowns THELOUNGE_HOME to $THELOUNGE_USER afterward, so a plain `rsync -a`
  # would see that ownership diff again every tick and force a needless
  # restart even with unchanged content.
  _sync_packages_out="$(rsync -a --no-owner --no-group --delete --itemize-changes \
    "$CURRENT_LINK/packages/" "$THELOUNGE_HOME/packages/")"
  if [ -n "$_sync_packages_out" ]; then
    log "Synced plugin packages:"
    echo "$_sync_packages_out" | while IFS= read -r line; do log "  $line"; done
    RESTART_NEEDED=1
  fi
}

install_config_js() {
  [ -f "$LIB_DIR/config.js" ] || return 0
  if [ -f "$THELOUNGE_HOME/config.js" ] &&
    cmp -s "$LIB_DIR/config.js" "$THELOUNGE_HOME/config.js"; then
    return 0
  fi
  log "Installing config.js"
  install -m 0644 "$LIB_DIR/config.js" "$THELOUNGE_HOME/config.js"
  RESTART_NEEDED=1
}

# One file per user, created only if absent: an existing file has
# accumulated that user's IRC networks and preferences and is never
# overwritten from users.json after the first login. A name becomes a file
# name, so only a plain one is accepted.
install_new_users() {
  _install_new_users_target=""
  [ -f "$LIB_DIR/users.json" ] || return 0
  _install_new_users_users_dir="$THELOUNGE_HOME/users"
  mkdir -p "$_install_new_users_users_dir"

  # Staged to a file rather than piped into `while read`: a pipe would run
  # the loop in a subshell (POSIX semantics) and lose RESTART_NEEDED=1 set
  # inside it.
  _install_new_users_tmp_list="$(mktemp "${TMPDIR:-/tmp}/thelounge-users.XXXXXX")"
  jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$LIB_DIR/users.json" >"$_install_new_users_tmp_list"

  while IFS="$(printf '\t')" read -r _install_new_users_name _install_new_users_hash; do
    [ -n "$_install_new_users_name" ] || continue
    if ! printf '%s' "$_install_new_users_name" | LC_ALL=C grep -Eq '^[A-Za-z0-9_][A-Za-z0-9_.@+-]*$'; then
      log "Skipping user with an unsafe name."
      continue
    fi
    _install_new_users_target="$_install_new_users_users_dir/$_install_new_users_name.json"
    [ -e "$_install_new_users_target" ] && continue
    log "Creating user $_install_new_users_name"
    jq -n --arg password "$_install_new_users_hash" '{password: $password, log: true}' \
      >"$_install_new_users_target"
    chmod 0600 "$_install_new_users_target"
    RESTART_NEEDED=1
  done <"$_install_new_users_tmp_list"

  rm -f "$_install_new_users_tmp_list"
}

converge_data() {
  mkdir -p "$THELOUNGE_HOME"
  sync_packages
  install_config_js
  install_new_users

  if [ "$RESTART_NEEDED" -eq 1 ]; then
    chown -R "$THELOUNGE_USER:$THELOUNGE_USER" "$THELOUNGE_HOME"
  fi
}

# ---- step 5: acknowledge the applied release ----

# build_ack POINTER INSTANCE_ID TIMESTAMP -> the acknowledgement JSON: the
# pointer applied, plus who applied it and when.
build_ack() {
  printf '%s' "$1" | jq -c --arg instance_id "$2" --arg acked_at "$3" \
    '. + {instance_id: $instance_id, acked_at: $acked_at}'
}

# Waits for thelounge.service to be active; a restart returns before the
# unit has necessarily settled.
wait_service_active() {
  _wait_service_active_tries=0
  while [ "$_wait_service_active_tries" -lt "$ACTIVE_TRIES" ]; do
    systemctl is-active --quiet thelounge && return 0
    _wait_service_active_tries=$((_wait_service_active_tries + 1))
    sleep "$ACTIVE_SECONDS"
  done
  return 1
}

# Succeeds when the acknowledgement for the current release is absent or
# names a different sha256.
ack_stale() {
  _ack_stale_sha="$(aws s3 cp "s3://$CONFIG_BUCKET/$1" - --region "$REGION" 2>/dev/null |
    jq -r '.sha256 // empty' 2>/dev/null)" || _ack_stale_sha=""
  [ "$_ack_stale_sha" != "$2" ]
}

instance_id() {
  cat "$INSTANCE_ID_FILE"
}

# Writes deployed/current-<arch>.json. Returns nonzero on failure; the caller
# decides that a failure must not fail the tick.
write_ack() {
  _write_ack_json="$(build_ack "$RELEASE_POINTER" "$(instance_id)" "$(date -u +%FT%TZ)")" || return 1
  printf '%s\n' "$_write_ack_json" |
    aws s3 cp - "s3://$CONFIG_BUCKET/$1" --region "$REGION" \
      --content-type application/json >/dev/null
}

# Acknowledges the release the pointer names once thelounge.service is
# active: after a tick that installed it, and whenever the acknowledgement is
# missing or stale (an earlier write failed, or the service was not yet up).
# Never fails the tick.
ack_release() {
  [ -n "$RELEASE_POINTER" ] || return 0
  _ack_release_key="$DEPLOYED_PREFIX/current-$RELEASE_ARCH.json"
  _ack_release_sha="$(printf '%s' "$RELEASE_POINTER" | jq -r '.sha256')"
  if [ "$RELEASE_CHANGED" -ne 1 ] && ! ack_stale "$_ack_release_key" "$_ack_release_sha"; then
    return 0
  fi
  if ! wait_service_active; then
    log "thelounge.service not active; not acknowledging release $_ack_release_sha yet."
    return 0
  fi
  if write_ack "$_ack_release_key"; then
    log "Acknowledged release $_ack_release_sha at s3://$CONFIG_BUCKET/$_ack_release_key"
  else
    log "WARNING: could not write s3://$CONFIG_BUCKET/$_ack_release_key; will retry next tick."
  fi
  return 0
}

drained() {
  [ -e "$DRAIN_MARKER" ]
}

# A drained unit stays stopped: the instance is about to be reclaimed, and a
# restart would drop the clients the drain just disconnected cleanly. The
# marker is checked here, after sync_release and converge_data, so a drain that
# fires while this tick runs also stands it down.
apply_service_state() {
  if drained; then
    log "Spot drain in progress; leaving thelounge.service alone."
  elif [ "$RESTART_NEEDED" -eq 1 ]; then
    log "Changes applied; restarting thelounge.service."
    systemctl restart thelounge
  elif ! systemctl is-active --quiet thelounge; then
    # thelounge.service is never enabled (see that unit), so a plain reboot
    # leaves it stopped even though nothing "changed" here.
    log "thelounge.service not running; starting it."
    systemctl start thelounge
  else
    log "No changes; thelounge.service already running."
  fi
}

main() {
  load_env
  ensure_thelounge_user
  ensure_jq

  sync_instance_files
  install_changed
  fetch_desired_config

  sync_release

  converge_data

  # A drained instance is about to be reclaimed: it must not record or
  # acknowledge a release it did not restart onto. Kept out of an `||` list so
  # a failed restart still aborts the tick under set -e.
  if drained; then
    apply_service_state
    return 0
  fi
  apply_service_state

  mark_applied
  ack_release
}

# Exclusive, non-blocking lock: an overlapping invocation skips rather than
# queues behind an in-flight run. THELOUNGE_CONVERGE_SOURCE_ONLY lets the
# tests load the functions without running a tick.
if [ "${THELOUNGE_CONVERGE_SOURCE_ONLY:-0}" != 1 ]; then
  (
    flock -n 9 || {
      log "another run is already in progress; exiting"
      exit 0
    }
    main "$@"
  ) 9>"$LOCK_FILE"
fi
