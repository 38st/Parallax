#!/usr/bin/env bash
set -euo pipefail

temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-warning-gate.XXXXXX")"
cleanup() {
  case "$(/usr/bin/basename "$temporary")" in
    parallax-warning-gate.*) /bin/rm -rf "$temporary" ;;
  esac
}
trap cleanup EXIT

/usr/bin/printf '%s\n' \
  'func deliberateWarningFixture() {' \
  '    let unusedValue = 1' \
  '}' >"$temporary/DeliberateWarning.swift"

set +e
xcrun swiftc -typecheck -warnings-as-errors \
  -module-cache-path "$temporary/module-cache" \
  "$temporary/DeliberateWarning.swift" \
  >"$temporary/stdout" 2>"$temporary/stderr"
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  echo "not ok 1 - deliberate Swift warning was accepted" >&2
  exit 1
fi
if ! /usr/bin/grep -Eq 'error:.*unusedValue.*was never used' "$temporary/stderr"; then
  echo "not ok 1 - compiler failed without proving warning escalation" >&2
  exit 1
fi

echo "ok 1 - deliberate Swift warning is rejected"
echo "1..1"
