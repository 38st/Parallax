#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="$root_dir/script/relay_run_evidence.sh"
capture_helper="$root_dir/script/relay_capture_stream.py"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-relay-evidence.XXXXXX")"
cleanup() {
  case "$(/usr/bin/basename "$temporary")" in
    parallax-relay-evidence.*) /bin/rm -rf "$temporary" ;;
  esac
}
trap cleanup EXIT
export RELAY_EVIDENCE_REQUIRE_CLEAN_SOURCE=0
# The workflow's real Relay test invocation requires the discovered suite
# baseline. These synthetic runner-contract fixtures are intentionally not
# XCTest processes; individual count-contract cases override this value below.
export RELAY_EVIDENCE_MIN_XCTEST_COUNT=0

assert_failed() {
  local output="$1"
  /usr/bin/grep -qx 'status=fail' "$output/status.txt"
  /usr/bin/grep -qx 'status=fail' "$output/metadata.txt"
}

make_git_fixture() {
  local repository="$1"
  /bin/mkdir -p "$repository"
  /usr/bin/git -C "$repository" init -q
  /usr/bin/git -C "$repository" config user.name 'Relay Evidence Fixture'
  /usr/bin/git -C "$repository" config user.email relay-evidence@example.invalid
  /usr/bin/touch "$repository/tracked"
  /usr/bin/git -C "$repository" add tracked
  /usr/bin/git -C "$repository" commit -qm fixture
}

failed_output="$temporary/failed"
/bin/mkdir -p "$failed_output"
/usr/bin/printf 'status=pass\n' >"$failed_output/status.txt"
/usr/bin/printf 'stale stdout\n' >"$failed_output/stdout.log"
/usr/bin/printf 'stale stderr\n' >"$failed_output/stderr.log"
/usr/bin/printf 'status=pass\n' >"$failed_output/metadata.txt"
set +e
"$runner" "$failed_output" -- /usr/bin/false >/dev/null 2>&1
failed_status=$?
set -e
[[ "$failed_status" -eq 1 ]]
assert_failed "$failed_output"
! /usr/bin/grep -q 'stale' "$failed_output/stdout.log" "$failed_output/stderr.log"
echo "ok 1 - failed attempt invalidates stale success before execution"

diagnostic_command="$temporary/zero-exit-diagnostic"
/usr/bin/printf '%s\n' \
  '#!/usr/bin/env bash' \
  'echo "warning: data race detected: fixture" >&2' \
  'exit 0' >"$diagnostic_command"
/bin/chmod +x "$diagnostic_command"
diagnostic_output="$temporary/diagnostic"
set +e
"$runner" "$diagnostic_output" -- "$diagnostic_command" >/dev/null 2>&1
diagnostic_status=$?
set -e
[[ "$diagnostic_status" -eq 1 ]]
assert_failed "$diagnostic_output"
/usr/bin/grep -qx 'command_exit_status=0' "$diagnostic_output/status.txt"
/usr/bin/grep -qx 'diagnostic_detected=1' "$diagnostic_output/status.txt"
echo "ok 2 - zero-exit failure diagnostic cannot become Ready evidence"

clean_command="$temporary/clean"
/usr/bin/printf '%s\n' \
  '#!/usr/bin/env bash' \
  'echo "verified fixture"' \
  'exit 0' >"$clean_command"
/bin/chmod +x "$clean_command"
clean_output="$temporary/clean-output"
"$runner" "$clean_output" -- "$clean_command" >/dev/null 2>&1
/usr/bin/grep -qx 'status=pass' "$clean_output/status.txt"
/usr/bin/grep -qx 'status=pass' "$clean_output/metadata.txt"
/usr/bin/grep -Eq '^command_sha256=[0-9a-f]{64}$' "$clean_output/metadata.txt"
/usr/bin/grep -Eq '^stdout_full_stream_sha256=[0-9a-f]{64}$' "$clean_output/metadata.txt"
/usr/bin/grep -Eq '^stderr_full_stream_sha256=[0-9a-f]{64}$' "$clean_output/metadata.txt"
/usr/bin/grep -qx 'source_head_match=1' "$clean_output/status.txt"
/usr/bin/grep -qx 'source_refs_match=1' "$clean_output/status.txt"
echo "ok 3 - clean command publishes HEAD/ref-bound full-stream evidence"

custom_command="$temporary/custom-diagnostic"
/usr/bin/printf '%s\n' \
  '#!/usr/bin/env bash' \
  'echo "fixture claims READY despite hidden failure"' \
  'exit 0' >"$custom_command"
/bin/chmod +x "$custom_command"
custom_output="$temporary/custom-output"
set +e
RELAY_EVIDENCE_FAILURE_PATTERN='hidden failure' \
  "$runner" "$custom_output" -- "$custom_command" >/dev/null 2>&1
custom_status=$?
set -e
[[ "$custom_status" -eq 1 ]]
/usr/bin/grep -qx 'diagnostic_detected=1' "$custom_output/status.txt"
echo "ok 4 - evaluator-specific failure signatures fail closed"

scan_error="$temporary/scan-error"
/usr/bin/printf '%s\n' '#!/usr/bin/env bash' 'exit 73' >"$scan_error"
/bin/chmod +x "$scan_error"
scan_error_output="$temporary/scan-error-output"
set +e
RELAY_EVIDENCE_GREP_BIN="$scan_error" \
  "$runner" "$scan_error_output" -- "$clean_command" >/dev/null 2>&1
scan_error_status=$?
set -e
[[ "$scan_error_status" -eq 1 ]]
assert_failed "$scan_error_output"
/usr/bin/grep -qx 'diagnostic_scan_exit_status=73' "$scan_error_output/status.txt"
echo "ok 5 - evidence diagnostic scanner failure fails closed"

commit_repository="$temporary/commit-mutation-repository"
make_git_fixture "$commit_repository"
commit_mutator="$temporary/commit-mutator"
/usr/bin/printf '%s\n' \
  '#!/usr/bin/env bash' \
  'git commit --allow-empty -qm relay-mutated-head' >"$commit_mutator"
/bin/chmod +x "$commit_mutator"
commit_output="$temporary/commit-mutation-output"
set +e
(cd "$commit_repository" && "$runner" "$commit_output" -- "$commit_mutator") \
  >/dev/null 2>&1
commit_status=$?
set -e
[[ "$commit_status" -eq 1 ]]
assert_failed "$commit_output"
/usr/bin/grep -qx 'command_exit_status=0' "$commit_output/status.txt"
/usr/bin/grep -qx 'source_head_match=0' "$commit_output/status.txt"
echo "ok 6 - successful command cannot publish evidence after mutating HEAD"

ref_repository="$temporary/ref-mutation-repository"
make_git_fixture "$ref_repository"
ref_mutator="$temporary/ref-mutator"
/usr/bin/printf '%s\n' \
  '#!/usr/bin/env bash' \
  'git update-ref refs/heads/relay-mutated HEAD' >"$ref_mutator"
/bin/chmod +x "$ref_mutator"
ref_output="$temporary/ref-mutation-output"
set +e
(cd "$ref_repository" && "$runner" "$ref_output" -- "$ref_mutator") \
  >/dev/null 2>&1
ref_status=$?
set -e
[[ "$ref_status" -eq 1 ]]
assert_failed "$ref_output"
/usr/bin/grep -qx 'command_exit_status=0' "$ref_output/status.txt"
/usr/bin/grep -qx 'source_head_match=1' "$ref_output/status.txt"
/usr/bin/grep -qx 'source_refs_match=0' "$ref_output/status.txt"
echo "ok 7 - non-HEAD ref mutation fails exact source binding"

raw_stdout="$temporary/raw-stdout"
raw_stderr="$temporary/raw-stderr"
/usr/bin/printf 'ghp_abcdefghijklmnopqrstuvwxyz1234567890\nrelay-ultra-secret\n' \
  >"$raw_stdout"
/usr/bin/printf '%0300d\n' 0 >>"$raw_stdout"
/usr/bin/printf 'Bearer abcdefghijklmnopqrstuvwxyz0123456789\n' >"$raw_stderr"
/usr/bin/printf '%0200d\n' 0 >>"$raw_stderr"
stream_command="$temporary/stream-command"
/usr/bin/printf '%s\n' \
  '#!/usr/bin/env bash' \
  '/bin/cat "$1"' \
  '/bin/cat "$2" >&2' >"$stream_command"
/bin/chmod +x "$stream_command"
stream_output="$temporary/stream-output"
RELAY_EVIDENCE_MAX_STDOUT_BYTES=96 \
RELAY_EVIDENCE_MAX_STDERR_BYTES=64 \
RELAY_TEST_SECRET='relay-ultra-secret' \
  "$runner" "$stream_output" -- "$stream_command" "$raw_stdout" "$raw_stderr" \
  >/dev/null 2>&1
[[ "$(/usr/bin/stat -f %z "$stream_output/stdout.log")" -le 96 ]]
[[ "$(/usr/bin/stat -f %z "$stream_output/stderr.log")" -le 64 ]]
! /usr/bin/grep -qE 'ghp_|relay-ultra-secret|Bearer[[:space:]]' \
  "$stream_output/stdout.log" "$stream_output/stderr.log"
stdout_digest="$(/usr/bin/shasum -a 256 "$raw_stdout" | /usr/bin/awk '{print $1}')"
stderr_digest="$(/usr/bin/shasum -a 256 "$raw_stderr" | /usr/bin/awk '{print $1}')"
stdout_bytes="$(/usr/bin/stat -f %z "$raw_stdout")"
stderr_bytes="$(/usr/bin/stat -f %z "$raw_stderr")"
/usr/bin/grep -qx "stdout_full_stream_sha256=$stdout_digest" "$stream_output/metadata.txt"
/usr/bin/grep -qx "stderr_full_stream_sha256=$stderr_digest" "$stream_output/metadata.txt"
/usr/bin/grep -qx "stdout_total_byte_count=$stdout_bytes" "$stream_output/metadata.txt"
/usr/bin/grep -qx "stderr_total_byte_count=$stderr_bytes" "$stream_output/metadata.txt"
/usr/bin/grep -qx 'stdout_was_truncated=1' "$stream_output/metadata.txt"
/usr/bin/grep -qx 'stderr_was_truncated=1' "$stream_output/metadata.txt"
/usr/bin/python3 "$capture_helper" scan-artifacts \
  "$stream_output/status.txt" "$stream_output/stdout.log" \
  "$stream_output/stderr.log" "$stream_output/metadata.txt"
echo "ok 8 - retained logs are bounded and redacted while full-stream digests survive"

empty_test_output="$temporary/empty-test-output"
set +e
RELAY_EVIDENCE_MIN_XCTEST_COUNT=1 \
  "$runner" "$empty_test_output" -- "$clean_command" >/dev/null 2>&1
empty_test_status=$?
set -e
[[ "$empty_test_status" -eq 1 ]]
assert_failed "$empty_test_output"
/usr/bin/grep -qx 'xctest_case_started_count=0' "$empty_test_output/status.txt"
/usr/bin/grep -qx 'xctest_count_contract_satisfied=0' "$empty_test_output/status.txt"
echo "ok 9 - zero-test success cannot publish Relay test evidence"

counted_test_command="$temporary/counted-test-command"
/usr/bin/printf '%s\n' \
  '#!/usr/bin/env bash' \
  "echo \"Test Case '-[Fixture testOne]' started.\"" \
  "echo \"Test Case '-[Fixture testTwo]' started.\"" \
  "printf '\\t Executed 2 tests, with 0 failures (0 unexpected)\\n'" \
  'exit 0' >"$counted_test_command"
/bin/chmod +x "$counted_test_command"
counted_test_output="$temporary/counted-test-output"
RELAY_EVIDENCE_MIN_XCTEST_COUNT=2 \
  "$runner" "$counted_test_output" -- "$counted_test_command" >/dev/null 2>&1
/usr/bin/grep -qx 'status=pass' "$counted_test_output/status.txt"
/usr/bin/grep -qx 'xctest_case_started_count=2' "$counted_test_output/status.txt"
/usr/bin/grep -qx 'xctest_executed_summary_max=2' "$counted_test_output/status.txt"
/usr/bin/grep -qx 'xctest_count_contract_satisfied=1' "$counted_test_output/status.txt"
echo "ok 10 - nonzero XCTest count and executed summary must agree"

echo "1..10"
