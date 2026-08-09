#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sanitizer="${1:-}"
output_dir="${2:-${SANITIZER_OUTPUT_DIR:-$ROOT_DIR/.build/sanitizer-$sanitizer}}"
jobs="${SANITIZER_JOBS:-4}"
scratch_path="${SANITIZER_SCRATCH_PATH:-}"
owns_scratch=0

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

if [[ -z "$scratch_path" ]]; then
  scratch_path="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-${sanitizer}-scratch.XXXXXX")"
  owns_scratch=1
fi

cleanup() {
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

{
  echo "status=$([[ "$test_status" -eq 0 && "$tee_status" -eq 0 ]] && echo pass || echo fail)"
  echo "swift_test_exit_status=$test_status"
  echo "tee_exit_status=$tee_status"
} >"$output_dir/status.txt"
if [[ "$test_status" -ne 0 || "$tee_status" -ne 0 ]]; then
  echo "Error: $sanitizer sanitizer test lane or evidence capture failed (swift=$test_status, tee=$tee_status); reports and logs are retained in $output_dir" >&2
  [[ "$test_status" -ne 0 ]] && exit "$test_status"
  exit "$tee_status"
fi

echo "sanitizer=$sanitizer" >"$output_dir/sanitizer-clean.txt"
echo "$sanitizer sanitizer tests passed."
