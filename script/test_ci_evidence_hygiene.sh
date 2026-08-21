#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-ci-evidence.XXXXXX")"
cleanup() {
  case "$(/usr/bin/basename "$temporary")" in
    parallax-ci-evidence.*) /bin/rm -rf "$temporary" ;;
  esac
}
trap cleanup EXIT

assert_pending_only() {
  local path="$1"
  [[ "$(<"$path")" == "status=pending" ]]
}

coverage_output="$temporary/coverage"
/bin/mkdir -p "$coverage_output"
/usr/bin/printf 'status=pass\n' >"$coverage_output/coverage-summary.txt"
/usr/bin/printf 'stale\n' >"$coverage_output/coverage-report.txt"
/usr/bin/printf 'stale\n' >"$coverage_output/coverage.lcov"
set +e
"$ROOT_DIR/script/check_coverage.sh" \
  --baseline "$temporary/missing-baseline.env" \
  --check-report "$temporary/missing-report.txt" \
  --output-dir "$coverage_output" \
  >/dev/null 2>&1
coverage_status=$?
set -e
[[ "$coverage_status" -eq 2 ]]
assert_pending_only "$coverage_output/coverage-summary.txt"
[[ ! -e "$coverage_output/coverage-report.txt" && ! -e "$coverage_output/coverage.lcov" ]]
echo "ok 1 - failed coverage startup invalidates stale pass evidence"

fake_gitleaks="$temporary/gitleaks"
/usr/bin/printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ "${1:-}" == version ]]; then echo 0.0.0; exit 0; fi' \
  'exit 99' >"$fake_gitleaks"
/bin/chmod +x "$fake_gitleaks"
secret_output="$temporary/secret"
/bin/mkdir -p "$secret_output"
/usr/bin/printf 'scan_result=pass\n' >"$secret_output/gitleaks-metadata.txt"
/usr/bin/printf 'stale\n' >"$secret_output/gitleaks-report.json"
/usr/bin/printf 'stale\n' >"$secret_output/gitleaks.stdout"
/usr/bin/printf 'stale\n' >"$secret_output/gitleaks.stderr"
set +e
GITLEAKS_BIN="$fake_gitleaks" \
  SECRET_SCAN_OUTPUT_DIR="$secret_output" \
  "$ROOT_DIR/script/run_secret_scan.sh" >/dev/null 2>&1
secret_status=$?
set -e
[[ "$secret_status" -eq 2 ]]
[[ "$(<"$secret_output/gitleaks-metadata.txt")" == "scan_result=pending" ]]
[[ "$(<"$secret_output/gitleaks-report.json")" == "[]" ]]
[[ ! -s "$secret_output/gitleaks.stdout" && ! -s "$secret_output/gitleaks.stderr" ]]
echo "ok 2 - failed secret-scan startup invalidates stale pass evidence"

fake_bin="$temporary/fake-bin"
/bin/mkdir -p "$fake_bin" "$temporary/tmp"
/usr/bin/printf '%s\n' '#!/usr/bin/env bash' 'exit 42' >"$fake_bin/swift"
/bin/chmod +x "$fake_bin/swift"
sanitizer_output="$temporary/sanitizer"
/bin/mkdir -p "$sanitizer_output"
/usr/bin/printf 'sanitizer=address\n' >"$sanitizer_output/sanitizer-clean.txt"
/usr/bin/printf 'status=pass\n' >"$sanitizer_output/status.txt"
/usr/bin/printf 'stale\n' >"$sanitizer_output/test.log"
set +e
PATH="$fake_bin:/usr/bin:/bin" TMPDIR="$temporary/tmp" \
  "$ROOT_DIR/script/run_sanitizer_tests.sh" address "$sanitizer_output" \
  >/dev/null 2>&1
sanitizer_status=$?
set -e
[[ "$sanitizer_status" -eq 42 ]]
assert_pending_only "$sanitizer_output/status.txt"
[[ ! -e "$sanitizer_output/sanitizer-clean.txt" && ! -e "$sanitizer_output/test.log" ]]
if /usr/bin/find "$temporary/tmp" -maxdepth 1 -name 'parallax-address-scratch.*' -print -quit | /usr/bin/grep -q .; then
  echo "not ok 3 - helper-owned sanitizer scratch leaked" >&2
  exit 1
fi
echo "ok 3 - failed sanitizer startup invalidates stale pass and cleans isolated scratch"

fake_coverage_bin="$temporary/fake-coverage-bin"
/bin/mkdir -p "$fake_coverage_bin" "$temporary/coverage-tmp"
/usr/bin/printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" >"$FAKE_SWIFT_ARGS"' \
  'exit 42' >"$fake_coverage_bin/swift"
/bin/chmod +x "$fake_coverage_bin/swift"
coverage_isolation_output="$temporary/coverage-isolation"
set +e
PATH="$fake_coverage_bin:/usr/bin:/bin" \
  TMPDIR="$temporary/coverage-tmp" \
  FAKE_SWIFT_ARGS="$temporary/coverage-swift-args" \
  "$ROOT_DIR/script/check_coverage.sh" \
  --output-dir "$coverage_isolation_output" >/dev/null 2>&1
coverage_isolation_status=$?
set -e
[[ "$coverage_isolation_status" -eq 2 ]]
assert_pending_only "$coverage_isolation_output/coverage-summary.txt"
/usr/bin/grep -Eq -- '--scratch-path .*/parallax-coverage-scratch\.' \
  "$temporary/coverage-swift-args"
if /usr/bin/grep -q -- '--scratch-path .*/\.build' "$temporary/coverage-swift-args"; then
  echo "not ok 4 - coverage used shared .build scratch" >&2
  exit 1
fi
if /usr/bin/find "$temporary/coverage-tmp" -maxdepth 1 \
  -name 'parallax-coverage-scratch.*' -print -quit | /usr/bin/grep -q .; then
  echo "not ok 4 - helper-owned coverage scratch leaked" >&2
  exit 1
fi
echo "ok 4 - coverage uses and cleans isolated scratch rather than shared .build"

fake_race_bin="$temporary/fake-race-bin"
/bin/mkdir -p "$fake_race_bin" "$temporary/race-scratch"
/usr/bin/printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ "${1:-}" == "--version" ]]; then echo "Swift fixture"; exit 0; fi' \
  'echo "warning: data race detected: @MainActor function at Fixture.swift:1 was not called on the main thread"' \
  'exit 0' >"$fake_race_bin/swift"
/usr/bin/printf '%s\n' '#!/usr/bin/env bash' 'echo "Xcode fixture"' >"$fake_race_bin/xcodebuild"
/usr/bin/printf '%s\n' '#!/usr/bin/env bash' 'echo "15.0"' >"$fake_race_bin/xcrun"
/bin/chmod +x "$fake_race_bin/swift" "$fake_race_bin/xcodebuild" "$fake_race_bin/xcrun"
race_output="$temporary/race-sanitizer"
/bin/mkdir -p "$race_output"
/usr/bin/printf 'sanitizer=thread\n' >"$race_output/sanitizer-clean.txt"
set +e
PATH="$fake_race_bin:/usr/bin:/bin" \
  SANITIZER_SCRATCH_PATH="$temporary/race-scratch" \
  "$ROOT_DIR/script/run_sanitizer_tests.sh" thread "$race_output" \
  >/dev/null 2>&1
race_status=$?
set -e
[[ "$race_status" -eq 1 ]]
/usr/bin/grep -qx 'status=fail' "$race_output/status.txt"
/usr/bin/grep -qx 'swift_test_exit_status=0' "$race_output/status.txt"
/usr/bin/grep -qx 'tee_exit_status=0' "$race_output/status.txt"
/usr/bin/grep -qx 'sanitizer_diagnostic_detected=1' "$race_output/status.txt"
/usr/bin/grep -qx 'sanitizer_diagnostic_source=test.log' "$race_output/status.txt"
/usr/bin/grep -q 'warning: data race detected' "$race_output/test.log"
[[ ! -e "$race_output/sanitizer-clean.txt" ]]
echo "ok 5 - zero-exit Swift runtime race warning fails the sanitizer lane"

/usr/bin/printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ "${1:-}" == "--version" ]]; then echo "Swift fixture"; exit 0; fi' \
  'log_path="${TSAN_OPTIONS##*log_path=}"' \
  'log_path="${log_path%%:*}"' \
  'echo "WARNING: ThreadSanitizer: data race" >"${log_path}.fixture"' \
  'exit 0' >"$fake_race_bin/swift"
native_race_output="$temporary/native-race-sanitizer"
/bin/mkdir -p "$native_race_output"
set +e
PATH="$fake_race_bin:/usr/bin:/bin" \
  SANITIZER_SCRATCH_PATH="$temporary/race-scratch" \
  "$ROOT_DIR/script/run_sanitizer_tests.sh" thread "$native_race_output" \
  >/dev/null 2>&1
native_race_status=$?
set -e
[[ "$native_race_status" -eq 1 ]]
/usr/bin/grep -qx 'status=fail' "$native_race_output/status.txt"
/usr/bin/grep -qx 'swift_test_exit_status=0' "$native_race_output/status.txt"
/usr/bin/grep -qx 'tee_exit_status=0' "$native_race_output/status.txt"
/usr/bin/grep -qx 'sanitizer_diagnostic_detected=1' "$native_race_output/status.txt"
/usr/bin/grep -qx 'sanitizer_diagnostic_source=tsan.fixture' "$native_race_output/status.txt"
/usr/bin/grep -q 'WARNING: ThreadSanitizer: data race' "$native_race_output/tsan.fixture"
[[ ! -e "$native_race_output/sanitizer-clean.txt" ]]
echo "ok 6 - zero-exit native ThreadSanitizer report fails the sanitizer lane"

/usr/bin/printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ "${1:-}" == "--version" ]]; then echo "Swift fixture"; fi' \
  'exit 0' >"$fake_race_bin/swift"
clean_output="$temporary/clean-sanitizer"
set +e
PATH="$fake_race_bin:/usr/bin:/bin" \
  SANITIZER_SCRATCH_PATH="$temporary/race-scratch" \
  "$ROOT_DIR/script/run_sanitizer_tests.sh" thread "$clean_output" \
  >/dev/null 2>&1
clean_status=$?
set -e
[[ "$clean_status" -eq 0 ]]
/usr/bin/grep -qx 'status=pass' "$clean_output/status.txt"
/usr/bin/grep -qx 'sanitizer_diagnostic_detected=0' "$clean_output/status.txt"
/usr/bin/grep -qx 'diagnostic_scan_exit_status=0' "$clean_output/status.txt"
/usr/bin/grep -qx 'test_log_grep_exit_status=1' "$clean_output/status.txt"
/usr/bin/grep -qx 'report_find_exit_status=0' "$clean_output/status.txt"
/usr/bin/grep -qx 'report_grep_scan_exit_status=0' "$clean_output/status.txt"
/usr/bin/grep -qx 'sanitizer=thread' "$clean_output/sanitizer-clean.txt"
echo "ok 7 - zero-exit clean log passes a successful diagnostic scan"

fake_scan_error="$temporary/fake-scan-error"
/usr/bin/printf '%s\n' '#!/usr/bin/env bash' 'exit 2' >"$fake_scan_error"
/bin/chmod +x "$fake_scan_error"
grep_error_output="$temporary/grep-error-sanitizer"
set +e
PATH="$fake_race_bin:/usr/bin:/bin" \
  SANITIZER_GREP_BIN="$fake_scan_error" \
  SANITIZER_SCRATCH_PATH="$temporary/race-scratch" \
  "$ROOT_DIR/script/run_sanitizer_tests.sh" thread "$grep_error_output" \
  >/dev/null 2>&1
grep_error_status=$?
set -e
[[ "$grep_error_status" -eq 1 ]]
/usr/bin/grep -qx 'status=fail' "$grep_error_output/status.txt"
/usr/bin/grep -qx 'sanitizer_diagnostic_detected=0' "$grep_error_output/status.txt"
/usr/bin/grep -qx 'diagnostic_scan_exit_status=2' "$grep_error_output/status.txt"
/usr/bin/grep -qx 'diagnostic_scan_error_source=test.log:grep' "$grep_error_output/status.txt"
[[ ! -e "$grep_error_output/sanitizer-clean.txt" ]]
echo "ok 8 - diagnostic grep error fails closed without a clean marker"

/usr/bin/printf '%s\n' '#!/usr/bin/env bash' 'exit 73' >"$fake_scan_error"
find_error_output="$temporary/find-error-sanitizer"
set +e
PATH="$fake_race_bin:/usr/bin:/bin" \
  SANITIZER_FIND_BIN="$fake_scan_error" \
  SANITIZER_SCRATCH_PATH="$temporary/race-scratch" \
  "$ROOT_DIR/script/run_sanitizer_tests.sh" thread "$find_error_output" \
  >/dev/null 2>&1
find_error_status=$?
set -e
[[ "$find_error_status" -eq 1 ]]
/usr/bin/grep -qx 'status=fail' "$find_error_output/status.txt"
/usr/bin/grep -qx 'sanitizer_diagnostic_detected=0' "$find_error_output/status.txt"
/usr/bin/grep -qx 'diagnostic_scan_exit_status=73' "$find_error_output/status.txt"
/usr/bin/grep -qx 'diagnostic_scan_error_source=tsan-reports:find' "$find_error_output/status.txt"
/usr/bin/grep -qx 'report_find_exit_status=73' "$find_error_output/status.txt"
[[ ! -e "$find_error_output/sanitizer-clean.txt" ]]
echo "ok 9 - diagnostic report discovery error fails closed without a clean marker"

python3 - "$ROOT_DIR/.github/workflows/ci.yml" <<'PY'
import pathlib
import re
import sys


workflow_path = pathlib.Path(sys.argv[1])
lines = workflow_path.read_text(encoding="utf-8").splitlines()
job_header = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")


def job_block(name: str) -> list[str]:
    start = None
    for index, line in enumerate(lines):
        match = job_header.match(line)
        if match and match.group(1) == name:
            start = index
            break
    if start is None:
        raise AssertionError(f"missing CI job: {name}")
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if job_header.match(lines[index]):
            end = index
            break
    return lines[start:end]


def dependencies(name: str) -> set[str]:
    block = job_block(name)
    for index, line in enumerate(block):
        match = re.match(r"^    needs:\s*(.*?)\s*$", line)
        if not match:
            continue
        inline = match.group(1)
        if inline:
            return {inline}
        result = set()
        for dependency_line in block[index + 1 :]:
            item = re.match(r"^      - ([A-Za-z0-9_-]+)\s*$", dependency_line)
            if item:
                result.add(item.group(1))
                continue
            if dependency_line.strip() and not dependency_line.startswith("      "):
                break
        return result
    return set()


required = {
    "build-and-test",
    "secret-scan",
    "coverage",
    "address-sanitizer",
    "thread-sanitizer",
    "production-keychain",
}
quality_block = "\n".join(job_block("quality-gate"))
assert dependencies("quality-gate") == required
assert "if: ${{ always() }}" in quality_block
assert "QUALITY_GATE_RESULTS: ${{ toJSON(needs) }}" in quality_block
assert 'get("result") != "success"' in quality_block
assert dependencies("unsigned-release") == {"quality-gate"}
assert dependencies("clean-artifact-inspection") == {"unsigned-release"}
assert dependencies("signed-notarized-release") == {
    "quality-gate",
    "clean-artifact-inspection",
}
signed_block = "\n".join(job_block("signed-notarized-release"))
assert "if: github.event_name == 'workflow_dispatch'" in signed_block
assert "SIGNING_CERTIFICATE_P12_BASE64" in signed_block
PY
echo "ok 10 - artifact and credentialed release jobs require every quality gate"
echo "1..10"
