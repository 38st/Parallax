#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGER="$ROOT_DIR/script/build_and_run.sh"
PACKAGER_LIB_DIR="$ROOT_DIR/script/lib/build_and_run"
INTEGRATION="${PARALLAX_PACKAGING_INTEGRATION:-0}"
ARCHIVE_ARCHITECTURE="${PARALLAX_PACKAGING_ARCHITECTURE:-native}"
TEST_COUNT=0
TEMPORARY_DIRS=""

cleanup() {
  local directory
  for directory in $TEMPORARY_DIRS; do
    case "$(basename "$directory")" in
      parallax-package-test.*|parallax-package-integration.*|parallax-runtime-smoke.*)
        /bin/rm -rf "$directory"
        ;;
    esac
  done
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  TEST_COUNT=$((TEST_COUNT + 1))
  echo "ok $TEST_COUNT - $*"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] \
    || fail "expected output to contain: $needle"
}

sha256() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

verifier_dmg_mount_count() {
  /usr/bin/awk '
    $1 ~ /^\/dev\/disk[0-9]+(s[0-9]+)*$/ \
        && $NF ~ /\/parallax-verify-dmg\.[^\/]+\/mount$/ { found += 1 }
    END { print found + 0 }
  '
}

assert_no_verifier_dmg_mounts() {
  local verifier_mount_count
  verifier_mount_count="$(/usr/bin/hdiutil info | verifier_dmg_mount_count)" \
    || fail "cannot inspect attached disk images"
  if [[ "$verifier_mount_count" -ne 0 ]]; then
    fail "packaging verification left a DMG mount attached"
  fi
}

assert_no_verifier_temp_dirs() {
  local parent="$1"
  local leftover
  leftover="$(
    /usr/bin/find "$parent" -mindepth 1 -maxdepth 1 -type d \
      \( -name 'parallax-verify-zip.*' -o -name 'parallax-verify-dmg.*' \) \
      -print -quit
  )"
  [[ -z "$leftover" ]] || fail "packaging verification left a temporary directory"
}

test_shell_syntax_and_mode_contract() {
  /bin/bash -n "$PACKAGER" "$PACKAGER_LIB_DIR"/*.sh
  local help
  help="$("$PACKAGER" --help 2>&1)"
  assert_contains "$help" "archive"
  assert_contains "$help" "install"
  assert_contains "$help" "release"
  assert_contains "$help" "verify --artifact"
  assert_contains "$help" "--expect"
  assert_contains "$help" "--architecture"
  assert_contains "$help" "--install-dir"
  pass "mode and verification contract is documented"
}

test_release_preflight_preserves_existing_artifacts() {
  local temporary
  temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-package-test.XXXXXX")"
  TEMPORARY_DIRS="$TEMPORARY_DIRS $temporary"

  local artifact="$temporary/Parallax-9.9.9-999.zip"
  /usr/bin/printf 'known-good-artifact' >"$artifact"
  local before
  before="$(sha256 "$artifact")"

  if SIGN_IDENTITY="" "$PACKAGER" release \
      --dist "$temporary" \
      --version 9.9.9 \
      --build 999 \
      >/dev/null 2>&1; then
    fail "release without a signing identity unexpectedly succeeded"
  fi

  [[ -f "$artifact" ]] || fail "credential preflight removed an artifact"
  [[ "$(sha256 "$artifact")" == "$before" ]] \
    || fail "credential preflight changed an artifact"
  [[ ! -e "$temporary/Parallax.app" ]] \
    || fail "credential preflight published an app"
  pass "missing release credentials fail before artifact mutation"
}

test_dirty_release_is_rejected_before_staging() {
  local temporary fixture output
  temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-package-test.XXXXXX")"
  TEMPORARY_DIRS="$TEMPORARY_DIRS $temporary"
  fixture="$temporary/repository"

  /bin/mkdir -p "$fixture/script/lib"
  /usr/bin/ditto "$PACKAGER" "$fixture/script/build_and_run.sh"
  /usr/bin/ditto \
    "$PACKAGER_LIB_DIR" \
    "$fixture/script/lib/build_and_run"
  /usr/bin/git -C "$fixture" init --quiet
  /usr/bin/git -C "$fixture" add script
  /usr/bin/git -C "$fixture" \
    -c user.name="Parallax Packaging Tests" \
    -c user.email="packaging-tests@localhost" \
    commit --quiet --message="Create clean packaging fixture"
  /usr/bin/printf 'deliberately dirty\n' >"$fixture/untracked-change"

  if output="$(
    SIGN_IDENTITY="Developer ID Application: Fixture" \
      "$fixture/script/build_and_run.sh" release \
        --dist "$temporary/artifacts" \
        --version 9.9.8 \
        --build 998 \
        2>&1
  )"; then
    fail "release from a dirty working tree unexpectedly succeeded"
  fi
  assert_contains "$output" "clean Git working tree"
  [[ ! -e "$temporary/artifacts/Parallax.app" ]] \
    || fail "dirty-tree preflight published an app"
  pass "dirty release is rejected before staging"
}

test_verify_requires_an_existing_artifact() {
  local output
  if output="$("$PACKAGER" verify --expect unsigned 2>&1)"; then
    fail "verify without --artifact unexpectedly succeeded"
  fi
  assert_contains "$output" "--artifact"
  pass "verification requires an explicit existing artifact"
}

test_failed_compilation_never_uses_cached_binary() {
  local temporary fake_bin fake_swift_log stale_bin output
  temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-package-test.XXXXXX")"
  TEMPORARY_DIRS="$TEMPORARY_DIRS $temporary"
  fake_bin="$temporary/fake-bin"
  fake_swift_log="$temporary/swift-invocations"
  stale_bin="$temporary/stale-bin"
  /bin/mkdir -p "$fake_bin" "$stale_bin"
  /usr/bin/printf '#!/usr/bin/env bash\n/usr/bin/printf "%%s\\n" "$*" >>"$FAKE_SWIFT_LOG"\ncase " $* " in\n  *" --show-bin-path "*) /usr/bin/printf "%%s\\n" "$FAKE_SWIFT_BIN"; exit 0 ;;\n  *) exit 86 ;;\nesac\n' \
    >"$fake_bin/swift"
  /bin/chmod 0755 "$fake_bin/swift"
  /usr/bin/printf '#!/usr/bin/env bash\nexit 0\n' >"$stale_bin/Parallax"
  /bin/chmod 0755 "$stale_bin/Parallax"

  if output="$(
    PATH="$fake_bin:$PATH" \
      FAKE_SWIFT_LOG="$fake_swift_log" \
      FAKE_SWIFT_BIN="$stale_bin" \
      "$PACKAGER" build \
        --dist "$temporary/dist" \
        --architecture native \
        2>&1
  )"; then
    fail "failed SwiftPM compilation unexpectedly published a cached binary"
  fi
  assert_contains "$output" "SwiftPM compilation failed"
  [[ -f "$fake_swift_log" ]] || fail "fake Swift compiler was not invoked"
  [[ "$(/usr/bin/wc -l <"$fake_swift_log" | /usr/bin/tr -d ' ')" -eq 1 ]] \
    || fail "packager continued into cached output discovery after compilation failed"
  [[ "$(<"$fake_swift_log")" != *"--show-bin-path"* ]] \
    || fail "packager queried a cached output path after compilation failed"
  [[ ! -e "$temporary/dist/Parallax.app" ]] \
    || fail "failed compilation published an application"
  pass "failed compilation cannot fall through to a stale SwiftPM binary"
}

test_verifier_rejects_unexpected_top_level_payloads() {
  local temporary source output verifier_temporary
  temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-package-test.XXXXXX")"
  TEMPORARY_DIRS="$TEMPORARY_DIRS $temporary"
  verifier_temporary="$temporary/verifier-temporary"
  /bin/mkdir "$verifier_temporary"
  source="$temporary/source"
  /bin/mkdir -p "$source/Parallax.app"
  /usr/bin/printf 'unexpected payload\n' >"$source/unexpected.txt"

  local zip="$temporary/unexpected-payload.zip"
  (
    cd "$source"
    /usr/bin/zip -q -r "$zip" Parallax.app unexpected.txt
  )
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$zip" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "ZIP with an unexpected top-level payload was accepted"
  fi
  assert_contains "$output" "ZIP contains unexpected top-level payload"

  local bomb_source="$temporary/bomb-source"
  /bin/mkdir -p "$bomb_source/Parallax.app/Contents"
  /usr/bin/truncate -s 67108865 \
    "$bomb_source/Parallax.app/Contents/compressed-bomb"
  local bomb_zip="$temporary/compressed-bomb.zip"
  (
    cd "$bomb_source"
    /usr/bin/zip -9 -q -r "$bomb_zip" Parallax.app
  )
  [[ "$(/usr/bin/stat -f %z "$bomb_zip")" -lt 1048576 ]] \
    || fail "compressed-bomb fixture did not compress as expected"
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$bomb_zip" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "ZIP with an oversized declared uncompressed entry was accepted"
  fi
  assert_contains "$output" "declared uncompressed size exceeds verification limits"

  local symlink_source="$temporary/symlink-source"
  /bin/mkdir "$symlink_source"
  /bin/ln -s /Applications "$symlink_source/Parallax.app"
  local symlink_zip="$temporary/symlink-root.zip"
  (
    cd "$symlink_source"
    /usr/bin/zip -q -y "$symlink_zip" Parallax.app
  )
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$symlink_zip" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "ZIP with a symbolic-link application root was accepted"
  fi
  assert_contains "$output" "ZIP application payload cannot be a symbolic link"

  local collision_source="$temporary/collision-source"
  /bin/mkdir "$collision_source"
  /bin/mkdir "$collision_source/PARALLAX.APP"
  local collision_zip="$temporary/case-equivalent-root.zip"
  (
    cd "$collision_source"
    /usr/bin/zip -q -r "$collision_zip" PARALLAX.APP
  )
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$collision_zip" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "ZIP with a case-equivalent application root was accepted"
  fi
  assert_contains "$output" "case/Unicode-equivalent top-level collision"

  local ditto_source="$temporary/ditto-source"
  /bin/mkdir -p "$ditto_source/Parallax.app/Contents"
  /usr/bin/printf 'fixture\n' >"$ditto_source/Parallax.app/Contents/fixture"
  /usr/bin/xattr -w com.parallax.inventory fixture \
    "$ditto_source/Parallax.app/Contents/fixture"
  local ditto_zip="$temporary/ditto-layout.zip"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
    "$ditto_source/Parallax.app" \
    "$ditto_zip"
  /usr/bin/zipinfo -1 "$ditto_zip" \
    | /usr/bin/grep -F '__MACOSX/Parallax.app/' >/dev/null \
    || fail "ditto ZIP fixture did not contain Apple metadata"
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$ditto_zip" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "incomplete ditto-layout fixture unexpectedly verified"
  fi
  assert_contains "$output" "application bundle is incomplete"
  [[ "$output" != *"unexpected top-level payload"* ]] \
    || fail "valid ditto metadata layout was rejected"

  /bin/ln -s /Applications "$source/Applications"
  local dmg="$temporary/unexpected-payload.dmg"
  /usr/bin/hdiutil create \
    -volname "Parallax inventory fixture" \
    -srcfolder "$source" \
    -format UDZO \
    "$dmg" >/dev/null
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$dmg" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "DMG with an unexpected top-level payload was accepted"
  fi
  assert_contains "$output" "DMG contains unexpected top-level payload"
  assert_no_verifier_dmg_mounts
  assert_no_verifier_temp_dirs "$verifier_temporary"

  local controlled_verifier="$temporary/controlled/parallax-verify-dmg.controlled"
  local controlled_mount="$controlled_verifier/mount"
  /bin/mkdir -p "$controlled_mount"
  /usr/bin/hdiutil attach \
    -readonly \
    -nobrowse \
    -mountpoint "$controlled_mount" \
    "$dmg" >/dev/null
  local detected_mounts
  detected_mounts="$(/usr/bin/hdiutil info | verifier_dmg_mount_count)"
  /usr/bin/hdiutil detach "$controlled_mount" >/dev/null \
    || /usr/bin/hdiutil detach "$controlled_mount" -force >/dev/null \
    || fail "could not detach controlled verifier mount"
  [[ "$detected_mounts" -eq 1 ]] \
    || fail "verifier mount detector did not recognize a real hdiutil mount record"
  assert_no_verifier_dmg_mounts

  pass "verification rejects unexpected ZIP and DMG top-level payloads"
}

test_local_and_unsigned_artifacts() {
  [[ "$INTEGRATION" == "1" ]] || return 0

  local temporary
  temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-package-integration.XXXXXX")"
  TEMPORARY_DIRS="$TEMPORARY_DIRS $temporary"

  "$PACKAGER" build \
    --dist "$temporary" \
    --architecture native
  local app="$temporary/Parallax.app"
  [[ -x "$app/Contents/MacOS/Parallax" ]] || fail "missing packaged executable"
  [[ -d "$app/Contents/Resources/Parallax_Parallax.bundle" ]] \
    || fail "missing SwiftPM resource bundle"
  /usr/bin/plutil -lint "$app/Contents/Info.plist" >/dev/null
  "$PACKAGER" verify \
    --artifact "$app" \
    --expect-local \
    --architecture native

  local ditto_zip="$temporary/Parallax-ditto-layout.zip"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$ditto_zip"
  "$PACKAGER" verify \
    --artifact "$ditto_zip" \
    --expect-local \
    --architecture native

  /bin/rm -rf "$temporary/Parallax.app"
  SOURCE_DATE_EPOCH=1700000000 "$PACKAGER" archive \
    --dist "$temporary" \
    --version 9.8.7 \
    --build 654 \
    --architecture "$ARCHIVE_ARCHITECTURE" \
    --zip \
    --dmg

  local zip="$temporary/Parallax-9.8.7-654.zip"
  local dmg="$temporary/Parallax-9.8.7-654.dmg"
  local provenance="$temporary/Parallax-9.8.7-654.provenance.plist"
  [[ -f "$zip" ]] || fail "missing unsigned ZIP"
  [[ -f "$dmg" ]] || fail "missing unsigned DMG"
  [[ -f "$provenance" ]] || fail "missing provenance manifest"
  /usr/bin/plutil -lint "$provenance" >/dev/null
  local key
  for key in \
      Architectures \
      BuildNumber \
      BuiltAtUTC \
      BundleIdentifier \
      GitDirty \
      GitRevision \
      MinimumSystemVersion \
      SDKVersion \
      SigningIdentity \
      SourceDateEpoch \
      SwiftToolchain \
      Version \
      PreSigningBinarySHA256 \
      PackagedBinarySHA256 \
      ZIPSHA256 \
      DMGSHA256; do
    /usr/bin/plutil -extract "$key" raw -o - "$provenance" >/dev/null \
      || fail "provenance is missing $key"
  done
  [[ "$(/usr/bin/plutil -extract ZIPSHA256 raw -o - "$provenance")" \
      == "$(sha256 "$zip")" ]] \
    || fail "provenance ZIP hash does not match"
  [[ "$(/usr/bin/plutil -extract DMGSHA256 raw -o - "$provenance")" \
      == "$(sha256 "$dmg")" ]] \
    || fail "provenance DMG hash does not match"

  "$PACKAGER" verify \
    --artifact "$zip" \
    --expect-unsigned \
    --architecture "$ARCHIVE_ARCHITECTURE"
  if [[ "$ARCHIVE_ARCHITECTURE" == "universal" ]]; then
    "$PACKAGER" verify \
      --artifact "$zip" \
      --expect-unsigned
  fi
  "$PACKAGER" verify \
    --artifact "$dmg" \
    --expect-unsigned \
    --architecture "$ARCHIVE_ARCHITECTURE"
  assert_no_verifier_dmg_mounts

  local runtime_temporary
  runtime_temporary="$(/usr/bin/mktemp -d \
    "${TMPDIR:-/tmp}/parallax-runtime-smoke.XXXXXX")"
  TEMPORARY_DIRS="$TEMPORARY_DIRS $runtime_temporary"
  /usr/bin/ditto -x -k "$zip" "$runtime_temporary"
  local runtime_output
  local runtime_home="$runtime_temporary/home"
  /bin/mkdir "$runtime_home"
  runtime_output="$(
    HOME="$runtime_home" \
      CFFIXED_USER_HOME="$runtime_home" \
      "$runtime_temporary/Parallax.app/Contents/MacOS/Parallax" \
        --resource-smoke-test
  )"
  assert_contains "$runtime_output" "Parallax packaged resources: OK"
  local packaged_binary_hash
  packaged_binary_hash="$(
    /usr/bin/plutil -extract PackagedBinarySHA256 raw -o - "$provenance"
  )"
  [[ "$(sha256 "$runtime_temporary/Parallax.app/Contents/MacOS/Parallax")" \
      == "$packaged_binary_hash" ]] \
    || fail "provenance executable hash does not match the ZIP app"

  local previous_app="$runtime_temporary/previous/Parallax.app"
  /bin/mkdir -p "$runtime_temporary/previous"
  /usr/bin/ditto "$runtime_temporary/Parallax.app" "$previous_app"
  /usr/bin/plutil -replace CFBundleShortVersionString \
    -string 9.8.6 "$previous_app/Contents/Info.plist"
  /usr/bin/plutil -replace CFBundleVersion \
    -string 653 "$previous_app/Contents/Info.plist"
  /usr/bin/codesign --force --deep --options runtime --sign - "$previous_app"
  "$ROOT_DIR/script/rehearse_install_upgrade_rollback.sh" \
    --previous "$previous_app" \
    --candidate "$zip" \
    --work-parent "$runtime_temporary" \
    >/dev/null

  local dmg_mount="$runtime_temporary/dmg-mount"
  /bin/mkdir "$dmg_mount"
  /usr/bin/hdiutil attach \
    -readonly \
    -nobrowse \
    -mountpoint "$dmg_mount" \
    "$dmg" >/dev/null
  local dmg_binary_hash
  dmg_binary_hash="$(sha256 "$dmg_mount/Parallax.app/Contents/MacOS/Parallax")"
  /usr/bin/hdiutil detach "$dmg_mount" >/dev/null
  [[ "$dmg_binary_hash" == "$packaged_binary_hash" ]] \
    || fail "provenance executable hash does not match the DMG app"

  local zip_hash
  zip_hash="$(sha256 "$zip")"
  local reproducible_dist="$temporary/reproducible"
  /bin/mkdir "$reproducible_dist"
  SOURCE_DATE_EPOCH=1700000000 "$PACKAGER" archive \
    --dist "$reproducible_dist" \
    --version 9.8.7 \
    --build 654 \
    --architecture "$ARCHIVE_ARCHITECTURE" \
    --zip \
    >/dev/null
  [[ "$(sha256 "$reproducible_dist/Parallax-9.8.7-654.zip")" \
      == "$zip_hash" ]] \
    || fail "same source epoch did not produce a byte-identical ZIP"

  if "$PACKAGER" archive \
      --dist "$temporary" \
      --version 9.8.7 \
      --build 654 \
      --architecture "$ARCHIVE_ARCHITECTURE" \
      --zip \
      --dmg \
      >/dev/null 2>&1; then
    fail "version/build collision unexpectedly succeeded"
  fi
  [[ "$(sha256 "$zip")" == "$zip_hash" ]] \
    || fail "collision changed the existing ZIP"
  pass "local, reproducible ZIP, DMG, install/upgrade/rollback, provenance, and collision verification"
}

test_shell_syntax_and_mode_contract
test_release_preflight_preserves_existing_artifacts
test_dirty_release_is_rejected_before_staging
test_verify_requires_an_existing_artifact
test_failed_compilation_never_uses_cached_binary
test_verifier_rejects_unexpected_top_level_payloads
test_local_and_unsigned_artifacts

echo "1..$TEST_COUNT"
