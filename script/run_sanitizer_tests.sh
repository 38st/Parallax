#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sanitizer="${1:-}"
output_dir="${2:-${SANITIZER_OUTPUT_DIR:-$ROOT_DIR/.build/sanitizer-$sanitizer}}"
jobs="${SANITIZER_JOBS:-4}"
scratch_path="${SANITIZER_SCRATCH_PATH:-}"
owns_scratch=0
diagnostic_grep_bin="${SANITIZER_GREP_BIN:-/usr/bin/grep}"
diagnostic_find_bin="${SANITIZER_FIND_BIN:-/usr/bin/find}"

case "$sanitizer" in
  address|thread) ;;
  *)
    echo "usage: $0 address|thread [OUTPUT_DIR]" >&2
    exit 2
    ;;
esac

/bin/mkdir -p "$output_dir"
/bin/rm -f \
  "$output_dir/sanitizer-clean.txt" "$output_dir/status.txt" \
  "$output_dir/test.log" "$output_dir/toolchain.txt"
/usr/bin/find "$output_dir" -maxdepth 1 -type f \( -name 'asan.*' -o -name 'tsan.*' \) -delete
/usr/bin/printf 'status=pending\n' >"$output_dir/status.txt"
report_inventory="$output_dir/.tsan-report-inventory"
/bin/rm -f "$report_inventory"

if [[ -z "$scratch_path" ]]; then
  scratch_path="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-${sanitizer}-scratch.XXXXXX")"
  owns_scratch=1
fi

cleanup() {
  /bin/rm -f "$report_inventory"
  if [[ "$owns_scratch" -eq 1 ]]; then
    case "$(/usr/bin/basename "$scratch_path")" in
      parallax-address-scratch.*|parallax-thread-scratch.*) /bin/rm -rf "$scratch_path" ;;
    esac
  fi
}
trap cleanup EXIT

{
  swift --version
  xcodebuild -version
  xcrun --sdk macosx --show-sdk-version
  echo "sanitizer=$sanitizer"
  echo "jobs=$jobs"
  echo "scratch_path=$scratch_path"
  echo "scratch_owned_by_helper=$owns_scratch"
} >"$output_dir/toolchain.txt"

export SWIFT_DETERMINISTIC_HASHING=1
if [[ "$sanitizer" == "address" ]]; then
  export ASAN_OPTIONS="halt_on_error=1:abort_on_error=1:detect_leaks=0:log_path=$output_dir/asan"
else
  export TSAN_OPTIONS="halt_on_error=1:log_path=$output_dir/tsan"
fi

set +e
swift_test_arguments=(test --sanitize="$sanitizer" --jobs "$jobs" --scratch-path "$scratch_path")
swift "${swift_test_arguments[@]}" \
  2>&1 | /usr/bin/tee "$output_dir/test.log"
pipeline_status=("${PIPESTATUS[@]}")
test_status="${pipeline_status[0]}"
tee_status="${pipeline_status[1]}"
set -e

sanitizer_diagnostic_detected=0
sanitizer_diagnostic_source="none"
diagnostic_scan_exit_status=0
diagnostic_scan_error_source="none"
test_log_grep_exit_status="not_run"
report_find_exit_status="not_run"
report_grep_scan_exit_status=0
if [[ "$sanitizer" == "thread" ]]; then
  diagnostic_pattern='warning:[[:space:]]+data race detected|warning:[[:space:]]+ThreadSanitizer:|summary:[[:space:]]+ThreadSanitizer:|ThreadSanitizer:[[:space:]]+reported'
  if "$diagnostic_grep_bin" -Eiq "$diagnostic_pattern" "$output_dir/test.log"; then
    test_log_grep_exit_status=0
    sanitizer_diagnostic_detected=1
    sanitizer_diagnostic_source="test.log"
  else
    test_log_grep_exit_status=$?
    if [[ "$test_log_grep_exit_status" -ne 1 ]]; then
      diagnostic_scan_exit_status="$test_log_grep_exit_status"
      diagnostic_scan_error_source="test.log:grep"
    fi
  fi

  if "$diagnostic_find_bin" "$output_dir" -maxdepth 1 -type f -name 'tsan.*' -print0 >"$report_inventory"; then
    report_find_exit_status=0
  else
    report_find_exit_status=$?
    if [[ "$diagnostic_scan_exit_status" -eq 0 ]]; then
      diagnostic_scan_exit_status="$report_find_exit_status"
      diagnostic_scan_error_source="tsan-reports:find"
    fi
  fi

  if [[ "$report_find_exit_status" -eq 0 ]]; then
    while IFS= read -r -d '' report; do
      if "$diagnostic_grep_bin" -Eiq "$diagnostic_pattern" "$report"; then
        sanitizer_diagnostic_detected=1
        if [[ "$sanitizer_diagnostic_source" == "none" ]]; then
          sanitizer_diagnostic_source="$(/usr/bin/basename "$report")"
        else
          sanitizer_diagnostic_source="$sanitizer_diagnostic_source,$(/usr/bin/basename "$report")"
        fi
      else
        report_grep_exit_status=$?
        if [[ "$report_grep_exit_status" -ne 1 ]]; then
          report_grep_scan_exit_status="$report_grep_exit_status"
          if [[ "$diagnostic_scan_exit_status" -eq 0 ]]; then
            diagnostic_scan_exit_status="$report_grep_exit_status"
            diagnostic_scan_error_source="$(/usr/bin/basename "$report"):grep"
          fi
        fi
      fi
    done <"$report_inventory"
  fi
fi

lane_passed=0
if [[ "$test_status" -eq 0 && "$tee_status" -eq 0 && "$sanitizer_diagnostic_detected" -eq 0 && "$diagnostic_scan_exit_status" -eq 0 ]]; then
  lane_passed=1
fi

{
  echo "status=$([[ "$lane_passed" -eq 1 ]] && echo pass || echo fail)"
  echo "swift_test_exit_status=$test_status"
  echo "tee_exit_status=$tee_status"
  echo "sanitizer_diagnostic_detected=$sanitizer_diagnostic_detected"
  echo "sanitizer_diagnostic_source=$sanitizer_diagnostic_source"
  echo "diagnostic_scan_exit_status=$diagnostic_scan_exit_status"
  echo "diagnostic_scan_error_source=$diagnostic_scan_error_source"
  echo "test_log_grep_exit_status=$test_log_grep_exit_status"
  echo "report_find_exit_status=$report_find_exit_status"
  echo "report_grep_scan_exit_status=$report_grep_scan_exit_status"
} >"$output_dir/status.txt"
if [[ "$lane_passed" -ne 1 ]]; then
  echo "Error: $sanitizer sanitizer test lane, evidence capture, or diagnostic scan failed (swift=$test_status, tee=$tee_status, diagnostic=$sanitizer_diagnostic_detected, scan=$diagnostic_scan_exit_status); reports and logs are retained in $output_dir" >&2
  [[ "$test_status" -ne 0 ]] && exit "$test_status"
  [[ "$tee_status" -ne 0 ]] && exit "$tee_status"
  exit 1
fi

echo "sanitizer=$sanitizer" >"$output_dir/sanitizer-clean.txt"
echo "$sanitizer sanitizer tests passed."
