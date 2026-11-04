#!/bin/sh
# Shared helpers for operator scripts. Sourcing scripts set LOG_PREFIX before
# sourcing. Callers own `set -eu`. Functions keep state in _func_var globals
# because POSIX sh has no `local`.
# shellcheck shell=sh

log() { echo "[${LOG_PREFIX:-script}] $*" >&2; }

die() {
  echo "[${LOG_PREFIX:-script}] ERROR: $*" >&2
  exit 1
}

# $1 = prompt. FORCE=1 skips the question.
confirm() {
  [ "${FORCE:-0}" = "1" ] && return 0
  printf '[%s] %s\n[%s] type "yes" to continue: ' \
    "${LOG_PREFIX:-script}" "$1" "${LOG_PREFIX:-script}" >&2
  read -r _confirm_reply
  [ "$_confirm_reply" = "yes" ] || die "aborted by user"
}

require() {
  for _require_tool in "$@"; do
    command -v "$_require_tool" >/dev/null 2>&1 || die "missing required tool: $_require_tool"
  done
}

# Prints the caller's header comment (line 2 to the first non-comment line).
# $0 is the sourcing script, not this file.
usage() {
  awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0" >&2
  exit 2
}

# $AWS_REGION wins; otherwise primary_region from the tfvars file $1;
# otherwise us-east-1.
resolve_region() {
  if [ -n "${AWS_REGION:-}" ]; then
    echo "$AWS_REGION"
    return 0
  fi
  _resolve_region_value="$(sed -n \
    's/^[[:space:]]*primary_region[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$1" 2>/dev/null | head -n 1)"
  echo "${_resolve_region_value:-us-east-1}"
}

# aws_as PROFILE ARGS...: runs `aws ARGS...` with AWS_PROFILE set to PROFILE
# when it is non-empty; the caller's own profile is left alone otherwise.
aws_as() {
  _aws_as_profile="$1"
  shift
  if [ -n "$_aws_as_profile" ]; then
    AWS_PROFILE="$_aws_as_profile" aws "$@"
  else
    aws "$@"
  fi
}
# Vendored from terraform-aws-keel v0.1.2, scripts/common.sh. Do not edit here: change
# keel and re-vendor. scripts/check-keel-drift.sh fails when this copy differs.
