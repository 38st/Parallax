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
echo "1..4"
