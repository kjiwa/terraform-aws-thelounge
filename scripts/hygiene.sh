#!/bin/sh
# Fails when a file contains an AWS account ID (12 digits), an AWS profile
# name, a personal email address, a home directory path, an operator's
# deployment name or identity, a bcrypt hash, or a region or time zone that
# belongs to one operator. UUIDs and the documented placeholder account IDs
# are not account IDs; the EC2 default user's home is the instance's own, not
# a person's. The operator patterns use bracketed characters so this file does
# not match itself.
#
# Binary files and empty files are skipped.
#
#   ./hygiene.sh FILE...
set -eu

# The account ID AWS uses in its own documentation, and all zeros; no real
# account has either.
readonly PLACEHOLDER_ACCOUNT_IDS='123456789012 000000000000'
readonly PATTERN_UUID='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
readonly PATTERN_ACCOUNT_ID='(^|[^0-9A-Za-z])[0-9]{12}([^0-9A-Za-z]|$)'
readonly PATTERN_PROFILE='(AWS_PROFILE=|--profile[= ])["'"'"']?[A-Za-z0-9]|profile[[:space:]]*=[[:space:]]*"[A-Za-z0-9]'
readonly PATTERN_EMAIL='[A-Za-z0-9._%+-]+@(gmail|googlemail|outlook|hotmail|yahoo|icloud|proton|protonmail)\.(com|me)'
readonly PATTERN_HOME='/(Users|home)/[A-Za-z0-9._-]+/'
readonly PATTERN_OPERATOR='arithraz[i]ne|kam[i]l|ji[w]a@'
# shellcheck disable=SC2016 # the dollar signs are regex literals
readonly PATTERN_BCRYPT='\$2[aby]\$[0-9]{2}\$'
readonly PATTERN_TIME_ZONE='America/Los_Ang[e]les'
readonly PATTERN_REGION='us-west-[1]([^0-9]|$)'
readonly EC2_HOME='/home''/ec2-user/'

# Two passes: adjacent matches share their separator, which one pass consumes.
_without_placeholders() {
  _without_text="$(sed -E "s/$PATTERN_UUID/_/g; s|$EC2_HOME|_|g")"
  for _without_id in $PLACEHOLDER_ACCOUNT_IDS; do
    _without_pattern="(^|[^0-9A-Za-z])$_without_id([^0-9A-Za-z]|$)"
    _without_text="$(printf '%s\n' "$_without_text" | sed -E "s/$_without_pattern/\\1_\\2/g" | sed -E "s/$_without_pattern/\\1_\\2/g")"
  done
  printf '%s\n' "$_without_text"
}

_check() {
  _check_hits="$(_without_placeholders <"$3" | grep -niE -e "$2" || true)"
  [ -z "$_check_hits" ] && return 0
  printf '%s\n' "$_check_hits" | sed "s|^|$3:$1: |" >&2
  return 1
}

_is_example() {
  case "$1" in
  examples/* | */examples/*) return 0 ;;
  *) return 1 ;;
  esac
}

main() {
  _main_status=0
  for _main_file in "$@"; do
    [ -f "$_main_file" ] || continue
    grep -qI '' "$_main_file" || continue
    _check "account-id" "$PATTERN_ACCOUNT_ID" "$_main_file" || _main_status=1
    _check "profile" "$PATTERN_PROFILE" "$_main_file" || _main_status=1
    _check "email" "$PATTERN_EMAIL" "$_main_file" || _main_status=1
    _check "home-path" "$PATTERN_HOME" "$_main_file" || _main_status=1
    _check "operator" "$PATTERN_OPERATOR" "$_main_file" || _main_status=1
    _check "bcrypt-hash" "$PATTERN_BCRYPT" "$_main_file" || _main_status=1
    _check "time-zone" "$PATTERN_TIME_ZONE" "$_main_file" || _main_status=1
    _is_example "$_main_file" || _check "region" "$PATTERN_REGION" "$_main_file" || _main_status=1
  done
  [ "$_main_status" -eq 0 ] || echo "hygiene: remove the identifiers above" >&2
  return "$_main_status"
}

main "$@"
