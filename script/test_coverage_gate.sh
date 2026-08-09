#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT_DIR/script/check_coverage.sh"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-coverage-contract.XXXXXX")"
cleanup() {
  case "$(/usr/bin/basename "$temporary")" in
    parallax-coverage-contract.*) /bin/rm -rf "$temporary" ;;
  esac
}
trap cleanup EXIT

baseline="$temporary/baseline.env"
/usr/bin/printf 'COVERED_LINES=80\nTOTAL_LINES=100\n' >"$baseline"

passing="$temporary/passing.txt"
/usr/bin/printf 'TOTAL 0 0 0 0 0 0 100 20 80.00%% 0 0 -\n' >"$passing"
"$CHECKER" \
  --check-report "$passing" \
  --baseline "$baseline" \
  --output-dir "$temporary/passing-output" \
  >/dev/null
/usr/bin/grep -Fx 'status=pass' "$temporary/passing-output/coverage-summary.txt" >/dev/null

regression="$temporary/regression.txt"
/usr/bin/printf 'TOTAL 0 0 0 0 0 0 100 21 79.00%% 0 0 -\n' >"$regression"
if "$CHECKER" \
    --check-report "$regression" \
    --baseline "$baseline" \
    --output-dir "$temporary/regression-output" \
    >"$temporary/regression.stdout" \
    2>"$temporary/regression.stderr"; then
  echo "FAIL: deliberate coverage regression passed" >&2
  exit 1
fi
/usr/bin/grep -F 'product line coverage regressed' "$temporary/regression.stderr" >/dev/null
/usr/bin/grep -Fx 'status=fail' "$temporary/regression-output/coverage-summary.txt" >/dev/null

fake_bin="$temporary/fake-bin"
fake_scratch="$temporary/existing-isolated-scratch"
fake_product_bin="$fake_scratch/bin"
/bin/mkdir -p \
  "$fake_bin" \
  "$fake_product_bin/ParallaxPackageTests.xctest/Contents/MacOS" \
  "$fake_product_bin/codecov"
: >"$fake_product_bin/ParallaxPackageTests.xctest/Contents/MacOS/ParallaxPackageTests"
/bin/chmod +x "$fake_product_bin/ParallaxPackageTests.xctest/Contents/MacOS/ParallaxPackageTests"
: >"$fake_product_bin/codecov/default.profdata"
/usr/bin/printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ "${1:-}" == build ]]; then printf "%s\n" "$FAKE_COVERAGE_BIN_PATH"; exit 0; fi' \
  'if [[ "${1:-}" == --version ]]; then echo "Fake Swift"; exit 0; fi' \
  'exit 99' >"$fake_bin/swift"
/usr/bin/printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ "${1:-}" == llvm-cov && "${2:-}" == report ]]; then' \
  '  printf "TOTAL 0 0 0 0 0 0 100 20 80.00%% 0 0 -\\n"; exit 0' \
  'fi' \
  'if [[ "${1:-}" == llvm-cov && "${2:-}" == export ]]; then' \
  '  printf "SF:%s/Sources/Parallax/Fake.swift\\nDA:1,1\\nLF:1\\nLH:1\\nend_of_record\\n" "$FAKE_COVERAGE_ROOT"; exit 0' \
  'fi' \
  'if [[ "${1:-}" == llvm-cov && "${2:-}" == --version ]]; then echo "Fake llvm-cov"; exit 0; fi' \
  'exit 99' >"$fake_bin/xcrun"
/bin/chmod +x "$fake_bin/swift" "$fake_bin/xcrun"
reuse_output="$temporary/reuse-output"
PATH="$fake_bin:/usr/bin:/bin" \
  FAKE_COVERAGE_BIN_PATH="$fake_product_bin" \
  FAKE_COVERAGE_ROOT="$ROOT_DIR" \
  COVERAGE_SCRATCH_PATH="$fake_scratch" \
  "$CHECKER" \
  --skip-tests \
  --baseline "$baseline" \
  --output-dir "$reuse_output" >/dev/null
/usr/bin/grep -Fx 'measurement_mode=reuse-existing-profile' \
  "$reuse_output/coverage-provenance.txt" >/dev/null
/usr/bin/grep -Fx \
  'generation_command=tests not run this invocation; existing isolated coverage profile required' \
  "$reuse_output/coverage-provenance.txt" >/dev/null

echo "ok 1 - exact product coverage baseline passes"
echo "ok 2 - deliberate one-line coverage regression fails"
echo "ok 3 - reused-profile mode truthfully records that tests did not run"
echo "1..3"
