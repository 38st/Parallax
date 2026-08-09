#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GITLEAKS_BIN="${GITLEAKS_BIN:-gitleaks}"
EXPECTED_GITLEAKS_VERSION="${EXPECTED_GITLEAKS_VERSION:-8.30.1}"
OUTPUT_DIR="${SECRET_SCAN_OUTPUT_DIR:-$ROOT_DIR/.build/secret-scan}"
REPORT_PATH="$OUTPUT_DIR/gitleaks-report.json"
METADATA_PATH="$OUTPUT_DIR/gitleaks-metadata.txt"
STDOUT_PATH="$OUTPUT_DIR/gitleaks.stdout"
STDERR_PATH="$OUTPUT_DIR/gitleaks.stderr"

/bin/mkdir -p "$OUTPUT_DIR"
/bin/rm -f "$REPORT_PATH" "$METADATA_PATH" "$STDOUT_PATH" "$STDERR_PATH"
/usr/bin/printf '[]\n' >"$REPORT_PATH"
/usr/bin/printf 'scan_result=pending\n' >"$METADATA_PATH"
: >"$STDOUT_PATH"
: >"$STDERR_PATH"

actual_version="$($GITLEAKS_BIN version | /usr/bin/tr -d '[:space:]')"
[[ "$actual_version" == "$EXPECTED_GITLEAKS_VERSION" \
    || "$actual_version" == "v$EXPECTED_GITLEAKS_VERSION" ]] \
  || { echo "Error: expected gitleaks $EXPECTED_GITLEAKS_VERSION, found $actual_version" >&2; exit 2; }

temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-gitleaks-canary.XXXXXX")"
cleanup() {
  case "$(/usr/bin/basename "$temporary")" in
    parallax-gitleaks-canary.*) /bin/rm -rf "$temporary" ;;
  esac
}
trap cleanup EXIT

# Construct the detector canary at runtime so the repository itself never
# contains a contiguous token-shaped value.
/usr/bin/printf 'token=%s%s\n' \
  'ghp_' '7Kx9mQ2vR8cT4yU6iO1pA3sD5fG7hJ9kL0zX' \
  >"$temporary/canary.env"

set +e
"$GITLEAKS_BIN" dir "$temporary" \
  --config "$ROOT_DIR/script/gitleaks.toml" \
  --no-banner \
  --redact=100 \
  --report-format json \
  --report-path "$temporary/canary-report.json" \
  >"$temporary/canary.stdout" \
  2>"$temporary/canary.stderr"
canary_status=$?
set -e
[[ "$canary_status" -eq 1 && -s "$temporary/canary-report.json" ]] \
  || { echo "Error: pinned gitleaks failed its secret-detection canary" >&2; exit 2; }

{
  echo "gitleaks_version=$actual_version"
  echo "mode=working-tree-directory"
  echo "redaction=100"
  echo "canary=pass"
} >"$METADATA_PATH"

set +e
"$GITLEAKS_BIN" dir "$ROOT_DIR" \
  --config "$ROOT_DIR/script/gitleaks.toml" \
  --no-banner \
  --redact=100 \
  --report-format json \
  --report-path "$REPORT_PATH" \
  >"$STDOUT_PATH" \
  2>"$STDERR_PATH"
scan_status=$?
set -e
echo "scan_exit_status=$scan_status" >>"$METADATA_PATH"

case "$scan_status" in
  0)
    echo "scan_result=pass" >>"$METADATA_PATH"
    echo "Secret scan passed with gitleaks $actual_version."
    ;;
  1)
    echo "scan_result=findings" >>"$METADATA_PATH"
    echo "Error: gitleaks found one or more potential secrets; the retained JSON report is fully redacted." >&2
    exit 1
    ;;
  *)
    echo "scan_result=error" >>"$METADATA_PATH"
    echo "Error: gitleaks could not complete the source scan (exit $scan_status); inspect the retained diagnostics artifact." >&2
    exit "$scan_status"
    ;;
esac
