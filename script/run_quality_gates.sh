#!/usr/bin/env bash
# Runs every local quality gate in order and stops at the first failure.
#
# Parallax has no hosted CI. This script is the bar a change must clear on the
# developer's Mac before it is pushed. The default set finishes in a few
# minutes. --full appends the coverage ratchet, both sanitizer lanes, and the
# packaging integration rehearsal, which together take much longer.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="${GATE_JOBS:-4}"
OUTPUT_DIR="${GATE_OUTPUT_DIR:-$ROOT_DIR/.build/quality-gates}"
FULL=0

usage() {
  cat >&2 <<'USAGE'
usage: script/run_quality_gates.sh [--full] [--jobs N] [--output-dir PATH]

Default gates, in order:
  1. release build with warnings as errors
  2. full test suite with warnings as errors
  3. localization checker contracts
  4. localization completeness census
  5. warning-gate contract
  6. evidence hygiene contracts
  7. coverage-gate contracts
  8. packaging command contracts
  9. pinned secret scan (needs gitleaks; see script/run_secret_scan.sh)
 10. git diff --check

--full appends:
 11. product-only coverage ratchet
 12. Address Sanitizer test lane
 13. Thread Sanitizer test lane
 14. native packaging integration: local app, ZIP, DMG, and the
     install/upgrade/rollback rehearsal in isolated directories

Each gate's output is written under the output directory. The script exits
with the first failing gate's status and prints the tail of that gate's log.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full) FULL=1 ;;
    --jobs) JOBS="$2"; shift ;;
    --output-dir) OUTPUT_DIR="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

cd "$ROOT_DIR"
/bin/mkdir -p "$OUTPUT_DIR"

sha="$(git rev-parse --short HEAD)"
tree="clean"
[[ -z "$(git status --porcelain)" ]] || tree="dirty"
echo "Parallax quality gates at $sha ($tree tree); logs in $OUTPUT_DIR"

index=0
last_log=""
measured=()

run_gate() {
  local name="$1"
  shift
  index=$((index + 1))
  local slug
  slug="$(printf '%s' "$name" | /usr/bin/tr -c 'A-Za-z0-9' '-' | /usr/bin/tr -s '-')"
  last_log="$OUTPUT_DIR/$(printf '%02d' "$index")-${slug%-}.log"
  local started
  started="$(date +%s)"
  printf '%2d. %-44s ' "$index" "$name"
  if "$@" >"$last_log" 2>&1; then
    printf 'PASS (%ds)\n' "$(( $(date +%s) - started ))"
  else
    local status=$?
    printf 'FAIL (exit %d)\n' "$status"
    echo "--- last 40 lines of $last_log ---"
    /usr/bin/tail -n 40 "$last_log"
    exit "$status"
  fi
}

record() {
  local line="$1"
  [[ -n "$line" ]] && measured+=("$line")
  return 0
}

run_gate "release build, warnings as errors" \
  swift build -c release --jobs "$JOBS" -Xswiftc -warnings-as-errors
run_gate "full test suite, warnings as errors" \
  swift test --jobs "$JOBS" -Xswiftc -warnings-as-errors
record "$(/usr/bin/grep -E 'Executed [0-9]+ tests' "$last_log" \
  | /usr/bin/tail -n 1 | /usr/bin/sed 's/^[[:space:]]*//' || true)"
run_gate "localization checker contracts" \
  python3 script/test_localization_completeness.py
run_gate "localization completeness census" \
  python3 script/check_localization_completeness.py
record "$(/usr/bin/grep -E '^localization census:' "$last_log" \
  | /usr/bin/tail -n 1 || true)"
run_gate "warning-gate contract" ./script/test_warning_gate.sh
run_gate "evidence hygiene contracts" ./script/test_ci_evidence_hygiene.sh
run_gate "coverage-gate contracts" ./script/test_coverage_gate.sh
run_gate "packaging command contracts" ./script/test_build_and_run.sh
run_gate "pinned secret scan" \
  env SECRET_SCAN_OUTPUT_DIR="$OUTPUT_DIR/secret-scan" ./script/run_secret_scan.sh
run_gate "git diff --check" git diff --check

if [[ "$FULL" -eq 1 ]]; then
  run_gate "product-only coverage ratchet" \
    env COVERAGE_JOBS="$JOBS" COVERAGE_OUTPUT_DIR="$OUTPUT_DIR/coverage" \
    ./script/check_coverage.sh
  record "$(/usr/bin/tr '\n' ' ' <"$OUTPUT_DIR/coverage/coverage-summary.txt" \
    2>/dev/null || true)"
  run_gate "Address Sanitizer lane" \
    env SANITIZER_JOBS="$JOBS" ./script/run_sanitizer_tests.sh address "$OUTPUT_DIR/asan"
  run_gate "Thread Sanitizer lane" \
    env SANITIZER_JOBS="$JOBS" ./script/run_sanitizer_tests.sh thread "$OUTPUT_DIR/tsan"
  run_gate "native packaging integration" \
    env PARALLAX_PACKAGING_INTEGRATION=1 PARALLAX_PACKAGING_ARCHITECTURE=native \
    ./script/test_build_and_run.sh
fi

echo
echo "All gates passed at $sha ($tree tree)."
if [[ "${#measured[@]}" -gt 0 ]]; then
  echo "Measured:"
  for line in ${measured[@]+"${measured[@]}"}; do
    echo "  $line"
  done
fi
