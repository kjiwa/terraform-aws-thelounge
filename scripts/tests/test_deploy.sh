#!/bin/sh
# Tests for scripts/deploy.sh: the state machine from apply-written
# desired.zip to a 200 from the site. Stub aws, terraform, curl and sleep serve
# canned state from $STUB, so the 15 and 2 minute timeouts run in no time.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly SCRIPTS="$TESTS_DIR/.."
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/thelounge-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/root"
STUB="$WORK/stub"
export STUB

cat >"$WORK/bin/terraform" <<'STUB'
#!/bin/sh
cat "$STUB/outputs.json"
STUB
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/sleep"
# seq FILE: the Nth line of FILE on the Nth call; the last line repeats.
cat >"$WORK/bin/stub-seq" <<'STUB'
#!/bin/sh
n=$(cat "$1.n" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" >"$1.n"
line=$(sed -n "${n}p" "$1")
[ -n "$line" ] || line=$(tail -n 1 "$1")
echo "$line"
STUB
cat >"$WORK/bin/curl" <<'STUB'
#!/bin/sh
stub-seq "$STUB/http"
STUB
cat >"$WORK/bin/aws" <<'STUB'
#!/bin/sh
case "$*" in
"s3api head-object"*) cat "$STUB/head-desired.json" || exit 254 ;;
"s3api get-object"*)
  key=""
  prev=""
  for a in "$@"; do
    [ "$prev" != "--key" ] || key="$a"
    prev="$a"
    out="$a"
  done
  f="$STUB/objects/$(echo "$key" | tr / _)"
  if [ -f "$f.absent" ]; then
    n=$(cat "$f.absent")
    if [ "$n" -gt 0 ]; then
      echo $((n - 1)) >"$f.absent"
      echo "An error occurred (NoSuchKey)" >&2
      exit 254
    fi
  fi
  [ -f "$f" ] || { echo "An error occurred (NoSuchKey)" >&2; exit 254; }
  cp "$f" "$out"
  cat "$f.meta"
  ;;
"codepipeline list-pipeline-executions"*)
  if [ -f "$STUB/started" ]; then cat "$STUB/executions-after-start.json"; else cat "$STUB/executions.json"; fi
  ;;
"codepipeline start-pipeline-execution"*) touch "$STUB/started"; echo exec-new ;;
"codepipeline get-pipeline-execution"*)
  if [ -f "$STUB/notfound-first" ] && [ ! -f "$STUB/notfound-done" ]; then
    touch "$STUB/notfound-done"
    echo "An error occurred (PipelineExecutionNotFoundException)" >&2
    exit 254
  fi
  stub-seq "$STUB/status"
  ;;
"codepipeline get-pipeline-state"*) printf 'Source\tSucceeded\nBuild\tInProgress\n' ;;
"codepipeline list-action-executions"*) cat "$STUB/failed-actions" ;;
*) echo "unstubbed aws $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$WORK/bin/"*

NOW="$(date -u +%s)"
readonly NOW

# iso EPOCH [OFFSET]: EPOCH as a timestamp, optionally written in OFFSET
# (+HH:MM) local time.
iso() {
  if [ -z "${2:-}" ]; then
    jq -rn --argjson t "$1" '$t | todate'
  else
    jq -rn --argjson t "$1" --arg o "$2" \
      '($t + (($o[1:3] | tonumber) * 3600 * (if $o[0:1] == "-" then -1 else 1 end)) | todate | rtrimstr("Z")) + $o'
  fi
}

# put_object KEY SHA LAST_MODIFIED_EPOCH: an S3 object holding a pointer.
put_object() {
  _put_key="$(echo "$1" | tr / _)"
  printf '{"artifact_key":"x","sha256":"%s"}\n' "$2" >"$STUB/objects/$_put_key"
  printf '{"LastModified":"%s"}\n' "$(iso "$3")" >"$STUB/objects/$_put_key.meta"
}

# execution ID START STATUS: one entry of executions.json.
execution() {
  jq -n --arg id "$1" --arg st "$2" --arg status "$3" \
    '{pipelineExecutionId: $id, status: $status, startTime: $st}'
}

# write_executions FILE ENTRY...: executions.json-style listing of ENTRYs.
write_executions() {
  _write_file="$1"
  shift
  printf '%s\n' "$@" | jq -s '{pipelineExecutionSummaries: .}' >"$_write_file"
}

# reset: a deployment whose arm64 build was acknowledged by an instance just
# now; every test starts here and changes one thing.
reset() {
  rm -rf "$STUB"
  mkdir -p "$STUB/objects"
  jq -n '{region: "eu-west-1", url: "https://irc.example.org",
    pipeline_name: "thelounge-delivery-prod", delivery_bucket: "thelounge-delivery-123456789012"}' \
    >"$STUB/outputs.json"
  printf '{"LastModified":"%s"}\n' "$(iso $((NOW - 30)))" >"$STUB/head-desired.json"
  write_executions "$STUB/executions.json" "$(execution exec-1 "$(iso $((NOW - 25)))" InProgress)"
  printf 'InProgress\nSucceeded\n' >"$STUB/status"
  printf 'Build\tthelounge-build-arm64\n' >"$STUB/failed-actions"
  put_object artifacts/current-arm64.json aaaa $((NOW - 20))
  put_object artifacts/current-x86_64.json bbbb $((NOW - 20))
  put_object deployed/current-arm64.json aaaa $((NOW - 5))
  put_object deployed/current-x86_64.json oldb $((NOW - 86400))
  echo 200 >"$STUB/http"
}

# deploy ARGS...: runs deploy.sh against the stubs; prints combined output and
# a final "exit=N" line.
deploy() {
  _deploy_status=0
  _deploy_out="$(env THELOUNGE_ROOT= DEPLOY_TIMEOUT_SECONDS=30 PATH="$WORK/bin:$PATH" \
    sh "$SCRIPTS/deploy.sh" --root "$WORK/root" "$@" 2>&1)" || _deploy_status=$?
  printf '%s\nexit=%s\n' "$_deploy_out" "$_deploy_status"
}

assert_contains() {
  if ! printf '%s\n' "$2" | grep -qF -e "$3"; then
    echo "FAIL: $1: output lacks '$3'" >&2
    printf '%s\n' "$2" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

test_success_joins_the_apply_run() {
  reset
  _out="$(deploy)"
  assert_contains "success exits 0" "$_out" "exit=0"
  assert_contains "success reports the ack" "$_out" "acknowledged"
  assert_contains "success reports the site" "$_out" "HTTP 200"
  assert_eq "joined the existing execution" "no" "$([ -f "$STUB/started" ] && echo yes || echo no)"
}

test_offset_timestamps() {
  reset
  write_executions "$STUB/executions.json" "$(execution exec-1 "$(iso $((NOW - 25)) +02:00)" InProgress)"
  printf '{"LastModified":"%s"}\n' "$(iso $((NOW - 30)) -05:00)" >"$STUB/head-desired.json"
  _out="$(deploy)"
  assert_contains "offset timestamps compare as instants" "$_out" "exit=0"
  assert_eq "offset timestamps join the execution" "no" "$([ -f "$STUB/started" ] && echo yes || echo no)"
}

test_starts_when_no_execution_followed_the_object() {
  reset
  printf '{"LastModified":"%s"}\n' "$(iso $((NOW - 3600)))" >"$STUB/head-desired.json"
  write_executions "$STUB/executions.json" "$(execution old "$(iso $((NOW - 7200)))" Succeeded)"
  write_executions "$STUB/executions-after-start.json" "$(execution exec-new "$(iso $((NOW - 1)))" InProgress)" "$(execution old "$(iso $((NOW - 7200)))" Succeeded)"
  put_object deployed/current-arm64.json aaaa $((NOW + 5))
  _out="$(deploy)"
  assert_contains "started run succeeds" "$_out" "exit=0"
  assert_eq "started an execution" "yes" "$([ -f "$STUB/started" ] && echo yes || echo no)"
}

test_restarts_after_a_failed_execution() {
  reset
  write_executions "$STUB/executions.json" "$(execution exec-1 "$(iso $((NOW - 25)))" Failed)"
  write_executions "$STUB/executions-after-start.json" "$(execution exec-new "$(iso $((NOW - 1)))" InProgress)" "$(execution exec-1 "$(iso $((NOW - 25)))" Failed)"
  put_object deployed/current-arm64.json aaaa $((NOW + 5))
  _out="$(deploy)"
  assert_contains "rerun succeeds" "$_out" "exit=0"
  assert_eq "a failed execution is not joined" "yes" "$([ -f "$STUB/started" ] && echo yes || echo no)"
}

test_release_unchanged() {
  reset
  put_object deployed/current-arm64.json aaaa $((NOW - 86400))
  _out="$(deploy)"
  assert_contains "unchanged exits 0" "$_out" "exit=0"
  assert_contains "unchanged says so" "$_out" "unchanged"
}

test_ack_arrives_late() {
  reset
  echo 3 >"$STUB/objects/deployed_current-arm64.json.absent"
  _out="$(deploy)"
  assert_contains "late ack exits 0" "$_out" "exit=0"
  assert_contains "late ack is acknowledged" "$_out" "acknowledged"
}

test_pipeline_failed() {
  reset
  printf 'InProgress\nFailed\n' >"$STUB/status"
  _out="$(deploy)"
  assert_contains "failure exits nonzero" "$_out" "exit=1"
  assert_contains "failure names the stage" "$_out" "stage pipeline"
  assert_contains "failure names the action" "$_out" "Build/thelounge-build-arm64"
}

test_pipeline_not_found_is_retried() {
  reset
  touch "$STUB/notfound-first"
  _out="$(deploy)"
  assert_contains "eventual consistency retried" "$_out" "exit=0"
}

test_pipeline_timeout() {
  reset
  echo InProgress >"$STUB/status"
  _out="$(deploy)"
  assert_contains "stuck pipeline exits nonzero" "$_out" "exit=1"
  assert_contains "stuck pipeline names the stage" "$_out" "stage pipeline"
}

test_ack_timeout() {
  reset
  put_object deployed/current-arm64.json oldaa $((NOW - 86400))
  _out="$(deploy)"
  assert_contains "missing ack exits nonzero" "$_out" "exit=1"
  assert_contains "missing ack names the stage" "$_out" "stage acknowledgement"
  assert_contains "missing ack names the sha" "$_out" "aaaa"
}

test_site_not_200() {
  reset
  echo 503 >"$STUB/http"
  _out="$(deploy)"
  assert_contains "bad site exits nonzero" "$_out" "exit=1"
  assert_contains "bad site names the stage" "$_out" "stage site"
  assert_contains "bad site shows the status" "$_out" "503"
}

test_site_recovers() {
  reset
  printf '502\n502\n200\n' >"$STUB/http"
  _out="$(deploy)"
  assert_contains "site retried until 200" "$_out" "exit=0"
}

test_site_redirect_is_not_ok() {
  reset
  echo 301 >"$STUB/http"
  _out="$(deploy)"
  assert_contains "a redirect is not a 200" "$_out" "exit=1"
}

test_extra_argument_prints_usage() {
  reset
  _out="$(deploy extra)"
  assert_contains "extra argument refused" "$_out" "exit=2"
  assert_contains "usage names the form" "$_out" "Usage: deploy.sh [--root DIR]"
}

main() {
  test_success_joins_the_apply_run
  test_offset_timestamps
  test_starts_when_no_execution_followed_the_object
  test_restarts_after_a_failed_execution
  test_release_unchanged
  test_ack_arrives_late
  test_pipeline_failed
  test_pipeline_not_found_is_retried
  test_pipeline_timeout
  test_ack_timeout
  test_site_not_200
  test_site_recovers
  test_site_redirect_is_not_ok
  test_extra_argument_prints_usage
  finish
}

main "$@"
