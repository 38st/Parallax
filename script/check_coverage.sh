#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE_PATH="$ROOT_DIR/script/coverage-baseline.env"
OUTPUT_DIR="${COVERAGE_OUTPUT_DIR:-$ROOT_DIR/.build/coverage-report}"
REPORT_INPUT=""
SKIP_TESTS=0
COVERAGE_JOBS="${COVERAGE_JOBS:-4}"
scratch_path="${COVERAGE_SCRATCH_PATH:-}"
owns_scratch=0
measurement_mode="report-input"
generation_command="external report input"

usage() {
  echo "usage: $0 [--skip-tests] [--check-report PATH] [--baseline PATH] [--output-dir PATH]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-tests)
      SKIP_TESTS=1
      shift
      ;;
    --check-report)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      REPORT_INPUT="$2"
      shift 2
      ;;
    --baseline)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      BASELINE_PATH="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      echo "Error: unknown option: $1" >&2
      exit 2
      ;;
  esac
done

read_baseline_value() {
  local key="$1"
  /usr/bin/awk -F= -v key="$key" '$1 == key { print $2; exit }' "$BASELINE_PATH"
}

/bin/mkdir -p "$OUTPUT_DIR"
REPORT_PATH="$OUTPUT_DIR/coverage-report.txt"
LCOV_PATH="$OUTPUT_DIR/coverage.lcov"
SUMMARY_PATH="$OUTPUT_DIR/coverage-summary.txt"
METADATA_PATH="$OUTPUT_DIR/coverage-metadata.txt"
PROVENANCE_PATH="$OUTPUT_DIR/coverage-provenance.txt"
INPUTS_PATH="$OUTPUT_DIR/coverage-inputs.sha256"
TEST_LOG_PATH="$OUTPUT_DIR/test.log"
TEST_STATUS_PATH="$OUTPUT_DIR/test-status.txt"

# Invalidate every prior success artifact before any fallible validation or
# measurement. Reusing an evidence directory can never preserve a stale pass.
/bin/rm -f \
  "$REPORT_PATH" "$LCOV_PATH" "$SUMMARY_PATH" "$METADATA_PATH" \
  "$PROVENANCE_PATH" "$INPUTS_PATH" "$TEST_LOG_PATH" "$TEST_STATUS_PATH"
/usr/bin/printf 'status=pending\n' >"$SUMMARY_PATH"

cleanup() {
  if [[ "$owns_scratch" -eq 1 ]]; then
    case "$(/usr/bin/basename "$scratch_path")" in
      parallax-coverage-scratch.*) /bin/rm -rf "$scratch_path" ;;
    esac
  fi
}
trap cleanup EXIT

[[ -f "$BASELINE_PATH" ]] || { echo "Error: coverage baseline is missing" >&2; exit 2; }
baseline_covered="$(read_baseline_value COVERED_LINES)"
baseline_total="$(read_baseline_value TOTAL_LINES)"
[[ "$baseline_covered" =~ ^[0-9]+$ && "$baseline_total" =~ ^[1-9][0-9]*$ ]] \
  || { echo "Error: coverage baseline is invalid" >&2; exit 2; }
[[ "$baseline_covered" -le "$baseline_total" ]] \
  || { echo "Error: coverage baseline exceeds its total" >&2; exit 2; }

if [[ -n "$REPORT_INPUT" ]]; then
  generation_command="external report input: $REPORT_INPUT"
  [[ -f "$REPORT_INPUT" ]] || { echo "Error: coverage report is missing" >&2; exit 2; }
  /bin/cp "$REPORT_INPUT" "$REPORT_PATH"
else
  if [[ "$SKIP_TESTS" -eq 1 ]]; then
    measurement_mode="reuse-existing-profile"
    generation_command="tests not run this invocation; existing isolated coverage profile required"
  else
    measurement_mode="llvm-cov"
    generation_command="swift test --enable-code-coverage --jobs $COVERAGE_JOBS --scratch-path <isolated>"
  fi
  if [[ -z "$scratch_path" ]]; then
    if [[ "$SKIP_TESTS" -eq 1 ]]; then
      echo "Error: --skip-tests requires COVERAGE_SCRATCH_PATH for an existing isolated build" >&2
      exit 2
    fi
    scratch_path="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-coverage-scratch.XXXXXX")"
    owns_scratch=1
  fi

  if [[ "$SKIP_TESTS" -eq 0 ]]; then
    set +e
    swift test --enable-code-coverage --jobs "$COVERAGE_JOBS" \
      --scratch-path "$scratch_path" \
      2>&1 | /usr/bin/tee "$TEST_LOG_PATH"
    pipeline_status=("${PIPESTATUS[@]}")
    set -e
    test_status="${pipeline_status[0]}"
    tee_status="${pipeline_status[1]}"
    {
      echo "swift_test_exit_status=$test_status"
      echo "tee_exit_status=$tee_status"
    } >"$TEST_STATUS_PATH"
    if [[ "$test_status" -ne 0 || "$tee_status" -ne 0 ]]; then
      echo "Error: coverage test execution or evidence capture failed (swift=$test_status, tee=$tee_status)" >&2
      exit 2
    fi
  fi

  bin_path="$(swift build --show-bin-path --scratch-path "$scratch_path")"
  test_binary="$bin_path/ParallaxPackageTests.xctest/Contents/MacOS/ParallaxPackageTests"
  profile="$bin_path/codecov/default.profdata"
  [[ -x "$test_binary" ]] \
    || { echo "Error: coverage test binary is missing: $test_binary" >&2; exit 2; }
  [[ -f "$profile" ]] \
    || { echo "Error: merged coverage profile is missing: $profile" >&2; exit 2; }

  exclusion_regex='(^|/)(Tests|\.build)(/|$)|/DerivedSources/|/resource_bundle_accessor\.swift$'
  xcrun llvm-cov report \
    "$test_binary" \
    -instr-profile="$profile" \
    -ignore-filename-regex="$exclusion_regex" \
    "$ROOT_DIR/Sources/Parallax" \
    >"$REPORT_PATH"
  xcrun llvm-cov export \
    -format=lcov \
    "$test_binary" \
    -instr-profile="$profile" \
    -ignore-filename-regex="$exclusion_regex" \
    "$ROOT_DIR/Sources/Parallax" \
    >"$LCOV_PATH"

  if /usr/bin/awk -F: \
      -v prefix="$ROOT_DIR/Sources/Parallax/" '
        /^SF:/ && index(substr($0, 4), prefix) != 1 { unexpected = 1 }
        END { exit(unexpected ? 0 : 1) }
      ' "$LCOV_PATH"; then
    echo "Error: coverage export contains a non-product source path" >&2
    exit 2
  fi

  {
    swift --version
    xcrun llvm-cov --version
    echo "product_root=$ROOT_DIR/Sources/Parallax"
    echo "exclusion_regex=$exclusion_regex"
    echo "generation_command=$generation_command"
    echo "scratch_path=$scratch_path"
    echo "scratch_owned_by_helper=$owns_scratch"
  } >"$METADATA_PATH"
fi

read -r current_total current_missed <<<"$(
  /usr/bin/awk '$1 == "TOTAL" { total = $8; missed = $9 } END { print total, missed }' \
    "$REPORT_PATH"
)"
[[ "$current_total" =~ ^[1-9][0-9]*$ && "$current_missed" =~ ^[0-9]+$ ]] \
  || { echo "Error: coverage TOTAL line is missing or invalid" >&2; exit 2; }
[[ "$current_missed" -le "$current_total" ]] \
  || { echo "Error: missed coverage exceeds total lines" >&2; exit 2; }
current_covered=$((current_total - current_missed))

baseline_percent="$(/usr/bin/awk -v c="$baseline_covered" -v t="$baseline_total" 'BEGIN { printf "%.4f", 100 * c / t }')"
current_percent="$(/usr/bin/awk -v c="$current_covered" -v t="$current_total" 'BEGIN { printf "%.4f", 100 * c / t }')"

: >"$INPUTS_PATH"
while IFS= read -r input_path; do
  input_hash="$(/usr/bin/shasum -a 256 "$input_path" | /usr/bin/awk '{print $1}')"
  /usr/bin/printf '%s  %s\n' "$input_hash" "${input_path#$ROOT_DIR/}" >>"$INPUTS_PATH"
done < <(
  /usr/bin/find \
    "$ROOT_DIR/Package.swift" \
    "$ROOT_DIR/Sources/Parallax" \
    "$ROOT_DIR/Tests/ParallaxTests" \
    -type f -print | LC_ALL=C /usr/bin/sort
)
inputs_fingerprint="$(/usr/bin/shasum -a 256 "$INPUTS_PATH" | /usr/bin/awk '{print $1}')"
report_fingerprint="$(/usr/bin/shasum -a 256 "$REPORT_PATH" | /usr/bin/awk '{print $1}')"
lcov_fingerprint="unavailable"
if [[ -f "$LCOV_PATH" ]]; then
  lcov_fingerprint="$(/usr/bin/shasum -a 256 "$LCOV_PATH" | /usr/bin/awk '{print $1}')"
fi
test_count="unavailable"
if [[ -f "$TEST_LOG_PATH" ]]; then
  parsed_test_count="$(/usr/bin/sed -nE 's/^[[:space:]]*Executed ([0-9]+) tests,.*$/\1/p' "$TEST_LOG_PATH" | /usr/bin/tail -n 1)"
  [[ -z "$parsed_test_count" ]] || test_count="$parsed_test_count"
fi
git_commit="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo unavailable)"

{
  echo "source_inputs_sha256=$inputs_fingerprint"
  echo "git_commit=$git_commit"
  echo "measurement_mode=$measurement_mode"
  echo "generation_command=$generation_command"
  echo "scratch_path=${scratch_path:-not-applicable}"
  echo "scratch_owned_by_helper=$owns_scratch"
  echo "test_count=$test_count"
  echo "baseline_fraction=$baseline_covered/$baseline_total"
  echo "current_fraction=$current_covered/$current_total"
  echo "current_line_percent=$current_percent"
  echo "coverage_report_sha256=$report_fingerprint"
  echo "coverage_lcov_sha256=$lcov_fingerprint"
} >"$PROVENANCE_PATH"

{
  echo "status=pending"
  echo "baseline_covered_lines=$baseline_covered"
  echo "baseline_total_lines=$baseline_total"
  echo "baseline_line_percent=$baseline_percent"
  echo "current_covered_lines=$current_covered"
  echo "current_total_lines=$current_total"
  echo "current_line_percent=$current_percent"
} >"$SUMMARY_PATH"

if (( current_covered * baseline_total < baseline_covered * current_total )); then
  /usr/bin/sed -i '' 's/^status=pending$/status=fail/' "$SUMMARY_PATH"
  echo "Error: product line coverage regressed: ${current_covered}/${current_total} (${current_percent}%) is below ${baseline_covered}/${baseline_total} (${baseline_percent}%)" >&2
  exit 1
fi

/usr/bin/sed -i '' 's/^status=pending$/status=pass/' "$SUMMARY_PATH"
echo "Product line coverage: ${current_covered}/${current_total} (${current_percent}%); baseline ${baseline_covered}/${baseline_total} (${baseline_percent}%)"
