#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 OUTPUT_DIR -- COMMAND [ARG ...]" >&2
}

[[ $# -ge 3 && "$2" == "--" ]] || { usage; exit 2; }
output_dir="$1"
shift 2
[[ -n "$output_dir" && "$output_dir" != "/" ]] || {
  echo "Error: unsafe evidence output directory" >&2
  exit 2
}

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
capture_helper="$root_dir/script/relay_capture_stream.py"
require_clean_source="${RELAY_EVIDENCE_REQUIRE_CLEAN_SOURCE:-1}"
maximum_stdout_bytes="${RELAY_EVIDENCE_MAX_STDOUT_BYTES:-262144}"
maximum_stderr_bytes="${RELAY_EVIDENCE_MAX_STDERR_BYTES:-262144}"
minimum_xctest_count="${RELAY_EVIDENCE_MIN_XCTEST_COUNT:-0}"
diagnostic_pattern="${RELAY_EVIDENCE_FAILURE_PATTERN:-warning:\\s+data race detected|WARNING:\\s+ThreadSanitizer:|ERROR:\\s+AddressSanitizer:|not ok\\s+[0-9]+}"
diagnostic_grep_bin="${RELAY_EVIDENCE_GREP_BIN:-/usr/bin/grep}"

[[ "$require_clean_source" == "0" || "$require_clean_source" == "1" ]] || {
  echo "Error: RELAY_EVIDENCE_REQUIRE_CLEAN_SOURCE must be 0 or 1" >&2
  exit 2
}
for value in "$maximum_stdout_bytes" "$maximum_stderr_bytes"; do
  [[ "$value" =~ ^[0-9]+$ && "$value" -le 16777216 ]] || {
    echo "Error: Relay evidence stream limits must be integers from 0 through 16777216" >&2
    exit 2
  }
done
[[ "$minimum_xctest_count" =~ ^[0-9]+$ && "$minimum_xctest_count" -le 1000000 ]] || {
  echo "Error: RELAY_EVIDENCE_MIN_XCTEST_COUNT must be an integer from 0 through 1000000" >&2
  exit 2
}
[[ -f "$capture_helper" ]] || {
  echo "Error: Relay stream capture helper is missing" >&2
  exit 2
}

/bin/mkdir -p "$output_dir"
status_path="$output_dir/status.txt"
stdout_path="$output_dir/stdout.log"
stderr_path="$output_dir/stderr.log"
metadata_path="$output_dir/metadata.txt"

# Prior success is invalidated before any fallible inspection or execution.
/bin/rm -f "$status_path" "$stdout_path" "$stderr_path" "$metadata_path"
/usr/bin/printf 'status=pending\n' >"$status_path"
: >"$stdout_path"
: >"$stderr_path"
: >"$metadata_path"
/bin/chmod 600 "$status_path" "$stdout_path" "$stderr_path" "$metadata_path"

capture_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-relay-capture.XXXXXX")"
stdout_fifo="$capture_root/stdout.fifo"
stderr_fifo="$capture_root/stderr.fifo"
stdout_capture_metadata="$capture_root/stdout.metadata"
stderr_capture_metadata="$capture_root/stderr.metadata"
source_status_path="$capture_root/source.status"
source_refs_path="$capture_root/source.refs"
capture_stdout_pid=""
capture_stderr_pid=""
cleanup() {
  [[ -z "$capture_stdout_pid" ]] || /bin/kill "$capture_stdout_pid" 2>/dev/null || true
  [[ -z "$capture_stderr_pid" ]] || /bin/kill "$capture_stderr_pid" 2>/dev/null || true
  case "$(/usr/bin/basename "$capture_root")" in
    parallax-relay-capture.*) /bin/rm -rf "$capture_root" ;;
  esac
}
trap cleanup EXIT

read_metadata() {
  local key="$1"
  local path="$2"
  /usr/bin/awk -F= -v key="$key" '$1 == key { print $2; exit }' "$path" 2>/dev/null \
    || true
}

capture_source_state() {
  local phase="$1"
  local head_path="$capture_root/head-$phase"
  local symbolic_path="$capture_root/head-symbolic-$phase"

  set +e
  /usr/bin/git rev-parse --verify HEAD >"$head_path" 2>/dev/null
  eval "source_head_${phase}_status=$?"
  /usr/bin/git symbolic-ref -q HEAD >"$symbolic_path" 2>/dev/null
  local symbolic_status=$?
  /usr/bin/git for-each-ref \
    --format='%(refname)%00%(objectname)' >"$source_refs_path"
  eval "source_refs_${phase}_status=$?"
  /usr/bin/git status --porcelain=v1 -z --untracked-files=all >"$source_status_path"
  eval "source_inspection_${phase}_status=$?"
  set -e

  [[ "$symbolic_status" -eq 0 || "$symbolic_status" -eq 1 ]] || {
    eval "source_head_${phase}_status=$symbolic_status"
  }
  if [[ "$symbolic_status" -eq 1 ]]; then
    /usr/bin/printf 'DETACHED\n' >"$symbolic_path"
  fi

  local head refs_digest status_digest symbolic_digest clean=0
  head="$(/usr/bin/tr -d '\r\n' <"$head_path")"
  refs_digest="$(/usr/bin/shasum -a 256 "$source_refs_path" | /usr/bin/awk '{print $1}')"
  status_digest="$(/usr/bin/shasum -a 256 "$source_status_path" | /usr/bin/awk '{print $1}')"
  symbolic_digest="$(/usr/bin/shasum -a 256 "$symbolic_path" | /usr/bin/awk '{print $1}')"
  eval "source_head_${phase}=\$head"
  eval "source_refs_${phase}_sha256=\$refs_digest"
  eval "source_status_${phase}_sha256=\$status_digest"
  eval "source_symbolic_head_${phase}_sha256=\$symbolic_digest"
  if [[ "$(eval "echo \$source_inspection_${phase}_status")" -eq 0 \
        && ! -s "$source_status_path" ]]; then
    clean=1
  fi
  eval "source_tree_clean_${phase}=\$clean"
}

command_digest="$({ /usr/bin/printf '%s\0' "$@"; } | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
capture_source_state before

/usr/bin/mkfifo "$stdout_fifo" "$stderr_fifo"
/usr/bin/python3 "$capture_helper" capture \
  --output "$stdout_path" \
  --metadata "$stdout_capture_metadata" \
  --limit "$maximum_stdout_bytes" \
  --diagnostic-regex "$diagnostic_pattern" <"$stdout_fifo" &
capture_stdout_pid=$!
/usr/bin/python3 "$capture_helper" capture \
  --output "$stderr_path" \
  --metadata "$stderr_capture_metadata" \
  --limit "$maximum_stderr_bytes" \
  --diagnostic-regex "$diagnostic_pattern" <"$stderr_fifo" &
capture_stderr_pid=$!

set +e
"$@" >"$stdout_fifo" 2>"$stderr_fifo"
command_status=$?
wait "$capture_stdout_pid"
stdout_capture_status=$?
capture_stdout_pid=""
wait "$capture_stderr_pid"
stderr_capture_status=$?
capture_stderr_pid=""
set -e

/bin/cat "$stdout_path"
/bin/cat "$stderr_path" >&2

# A second scanner is intentionally injectable so scanner failures themselves
# are covered by a fail-closed contract.
post_capture_diagnostic=0
diagnostic_scan_status=0
set +e
"$diagnostic_grep_bin" -Eiq \
  'warning:[[:space:]]+data race detected|WARNING:[[:space:]]+ThreadSanitizer:|ERROR:[[:space:]]+AddressSanitizer:|not ok[[:space:]]+[0-9]+' \
  "$stdout_path" "$stderr_path"
grep_status=$?
set -e
case "$grep_status" in
  0) post_capture_diagnostic=1 ;;
  1) ;;
  *) diagnostic_scan_status="$grep_status" ;;
esac

stdout_diagnostic="$(read_metadata diagnostic_detected "$stdout_capture_metadata")"
stderr_diagnostic="$(read_metadata diagnostic_detected "$stderr_capture_metadata")"
diagnostic_detected=0
[[ "$stdout_diagnostic" == "1" || "$stderr_diagnostic" == "1" \
    || "$post_capture_diagnostic" -eq 1 ]] && diagnostic_detected=1

set +e
/usr/bin/python3 "$capture_helper" scan-artifacts \
  "$stdout_path" "$stderr_path" \
  "$stdout_capture_metadata" "$stderr_capture_metadata"
artifact_secret_scan_status=$?
set -e

capture_source_state after

stdout_sha256="$(read_metadata full_stream_sha256 "$stdout_capture_metadata")"
stderr_sha256="$(read_metadata full_stream_sha256 "$stderr_capture_metadata")"
stdout_total_bytes="$(read_metadata total_byte_count "$stdout_capture_metadata")"
stderr_total_bytes="$(read_metadata total_byte_count "$stderr_capture_metadata")"
stdout_retained_bytes="$(read_metadata retained_redacted_byte_count "$stdout_capture_metadata")"
stderr_retained_bytes="$(read_metadata retained_redacted_byte_count "$stderr_capture_metadata")"
stdout_truncated="$(read_metadata was_truncated "$stdout_capture_metadata")"
stderr_truncated="$(read_metadata was_truncated "$stderr_capture_metadata")"
stdout_redactions="$(read_metadata redaction_count "$stdout_capture_metadata")"
stderr_redactions="$(read_metadata redaction_count "$stderr_capture_metadata")"
stdout_xctest_started="$(read_metadata xctest_case_started_count "$stdout_capture_metadata")"
stderr_xctest_started="$(read_metadata xctest_case_started_count "$stderr_capture_metadata")"
stdout_xctest_summary="$(read_metadata xctest_executed_summary_max "$stdout_capture_metadata")"
stderr_xctest_summary="$(read_metadata xctest_executed_summary_max "$stderr_capture_metadata")"
xctest_case_started_count=$(( ${stdout_xctest_started:-0} + ${stderr_xctest_started:-0} ))
if [[ "${stdout_xctest_summary:-0}" -gt "${stderr_xctest_summary:-0}" ]]; then
  xctest_executed_summary_max="${stdout_xctest_summary:-0}"
else
  xctest_executed_summary_max="${stderr_xctest_summary:-0}"
fi
xctest_count_contract_satisfied=0
if [[ "$minimum_xctest_count" -eq 0 \
      || ( "$xctest_case_started_count" -ge "$minimum_xctest_count" \
        && "$xctest_executed_summary_max" -eq "$xctest_case_started_count" ) ]]; then
  xctest_count_contract_satisfied=1
fi

{
  echo "status=pending"
  echo "command_exit_status=$command_status"
  echo "stdout_capture_exit_status=$stdout_capture_status"
  echo "stderr_capture_exit_status=$stderr_capture_status"
  echo "diagnostic_detected=$diagnostic_detected"
  echo "diagnostic_scan_exit_status=$diagnostic_scan_status"
  echo "artifact_secret_scan_exit_status=$artifact_secret_scan_status"
  echo "source_head_before_status=$source_head_before_status"
  echo "source_head_after_status=$source_head_after_status"
  echo "source_head_before=$source_head_before"
  echo "source_head_after=$source_head_after"
  echo "source_symbolic_head_before_sha256=$source_symbolic_head_before_sha256"
  echo "source_symbolic_head_after_sha256=$source_symbolic_head_after_sha256"
  echo "source_refs_before_status=$source_refs_before_status"
  echo "source_refs_after_status=$source_refs_after_status"
  echo "source_refs_before_sha256=$source_refs_before_sha256"
  echo "source_refs_after_sha256=$source_refs_after_sha256"
  echo "source_inspection_before_status=$source_inspection_before_status"
  echo "source_inspection_after_status=$source_inspection_after_status"
  echo "source_tree_clean_before=$source_tree_clean_before"
  echo "source_tree_clean_after=$source_tree_clean_after"
  echo "source_status_before_sha256=$source_status_before_sha256"
  echo "source_status_after_sha256=$source_status_after_sha256"
  echo "command_sha256=$command_digest"
  echo "stdout_full_stream_sha256=$stdout_sha256"
  echo "stderr_full_stream_sha256=$stderr_sha256"
  echo "stdout_total_byte_count=${stdout_total_bytes:-unavailable}"
  echo "stderr_total_byte_count=${stderr_total_bytes:-unavailable}"
  echo "stdout_retained_byte_count=${stdout_retained_bytes:-unavailable}"
  echo "stderr_retained_byte_count=${stderr_retained_bytes:-unavailable}"
  echo "stdout_was_truncated=${stdout_truncated:-unavailable}"
  echo "stderr_was_truncated=${stderr_truncated:-unavailable}"
  echo "stdout_redaction_count=${stdout_redactions:-unavailable}"
  echo "stderr_redaction_count=${stderr_redactions:-unavailable}"
  echo "minimum_xctest_count=$minimum_xctest_count"
  echo "xctest_case_started_count=$xctest_case_started_count"
  echo "xctest_executed_summary_max=$xctest_executed_summary_max"
  echo "xctest_count_contract_satisfied=$xctest_count_contract_satisfied"
} >"$metadata_path"

lane_passed=0
if [[ "$command_status" -eq 0 \
      && "$stdout_capture_status" -eq 0 \
      && "$stderr_capture_status" -eq 0 \
      && "$diagnostic_detected" -eq 0 \
      && "$diagnostic_scan_status" -eq 0 \
      && "$artifact_secret_scan_status" -eq 0 \
      && "$xctest_count_contract_satisfied" -eq 1 \
      && "$source_head_before_status" -eq 0 \
      && "$source_head_after_status" -eq 0 \
      && "$source_head_before" == "$source_head_after" \
      && "$source_symbolic_head_before_sha256" == "$source_symbolic_head_after_sha256" \
      && "$source_refs_before_status" -eq 0 \
      && "$source_refs_after_status" -eq 0 \
      && "$source_refs_before_sha256" == "$source_refs_after_sha256" \
      && "$source_inspection_before_status" -eq 0 \
      && "$source_inspection_after_status" -eq 0 \
      && "$source_status_before_sha256" == "$source_status_after_sha256" \
      && ( "$require_clean_source" -eq 0 \
        || ( "$source_tree_clean_before" -eq 1 \
          && "$source_tree_clean_after" -eq 1 ) ) ]]; then
  lane_passed=1
fi

{
  echo "status=$([[ "$lane_passed" -eq 1 ]] && echo pass || echo fail)"
  echo "command_exit_status=$command_status"
  echo "stdout_capture_exit_status=$stdout_capture_status"
  echo "stderr_capture_exit_status=$stderr_capture_status"
  echo "diagnostic_detected=$diagnostic_detected"
  echo "diagnostic_scan_exit_status=$diagnostic_scan_status"
  echo "artifact_secret_scan_exit_status=$artifact_secret_scan_status"
  echo "minimum_xctest_count=$minimum_xctest_count"
  echo "xctest_case_started_count=$xctest_case_started_count"
  echo "xctest_executed_summary_max=$xctest_executed_summary_max"
  echo "xctest_count_contract_satisfied=$xctest_count_contract_satisfied"
  echo "source_head_match=$([[ "$source_head_before" == "$source_head_after" ]] && echo 1 || echo 0)"
  echo "source_symbolic_head_match=$([[ "$source_symbolic_head_before_sha256" == "$source_symbolic_head_after_sha256" ]] && echo 1 || echo 0)"
  echo "source_refs_match=$([[ "$source_refs_before_sha256" == "$source_refs_after_sha256" ]] && echo 1 || echo 0)"
  echo "source_tree_clean_before=$source_tree_clean_before"
  echo "source_tree_clean_after=$source_tree_clean_after"
} >"$status_path"
/usr/bin/sed -i '' \
  "s/^status=pending$/status=$([[ "$lane_passed" -eq 1 ]] && echo pass || echo fail)/" \
  "$metadata_path"

[[ "$lane_passed" -eq 1 ]] && exit 0
[[ "$command_status" -eq 0 ]] || exit "$command_status"
exit 1
