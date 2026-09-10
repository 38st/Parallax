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
  [[ "$output" != *"unexpected top-level payload"* \
      && "$output" != *"forbidden AppleDouble metadata"* ]] \
    || fail "valid ditto metadata layout was rejected"
  # This project publishes unsigned archives with a deterministic zip run that
  # never sequesters resource forks, so the same layout is smuggled metadata
  # when it claims to be one.
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$ditto_zip" \
      --expect-unsigned \
      --architecture native \
      2>&1
  )"; then
    fail "an unsigned ZIP carrying sequestered Apple metadata was accepted"
  fi
  assert_contains "$output" "ZIP contains forbidden AppleDouble metadata"

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

test_verifier_rejects_untrustworthy_zip_inputs() {
  local temporary verifier_temporary source zip output
  temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-package-test.XXXXXX")"
  TEMPORARY_DIRS="$TEMPORARY_DIRS $temporary"
  verifier_temporary="$temporary/verifier-temporary"
  /bin/mkdir "$verifier_temporary"
  source="$temporary/source"
  /bin/mkdir -p "$source/Parallax.app/Contents"
  /usr/bin/printf 'payload\n' >"$source/Parallax.app/Contents/Info.plist"
  zip="$temporary/input-contract.zip"
  (
    cd "$source"
    /usr/bin/zip -q -r "$zip" Parallax.app
  )

  /bin/ln -s "$zip" "$temporary/symbolic-input.zip"
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$temporary/symbolic-input.zip" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "a symbolic-link ZIP input was accepted"
  fi
  assert_contains "$output" "ZIP must be a regular non-symbolic-link file"

  /bin/ln "$zip" "$temporary/second-name.zip"
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$temporary/second-name.zip" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "a multiply linked ZIP input was accepted"
  fi
  assert_contains "$output" "ZIP must have exactly one hard link"

  : >"$temporary/empty.zip"
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$temporary/empty.zip" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "an empty ZIP input was accepted"
  fi
  assert_contains "$output" "ZIP is empty"

  /usr/bin/truncate -s 536870913 "$temporary/oversized.zip"
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$temporary/oversized.zip" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "an oversized ZIP input was accepted"
  fi
  assert_contains "$output" "ZIP exceeds the 512 MiB verification limit"
  assert_no_verifier_temp_dirs "$verifier_temporary"
  pass "verification requires a bounded, singly named regular ZIP input"
}

test_verifier_rejects_corrupt_or_smuggled_zip_payloads() {
  local temporary verifier_temporary output
  temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-package-test.XXXXXX")"
  TEMPORARY_DIRS="$TEMPORARY_DIRS $temporary"
  verifier_temporary="$temporary/verifier-temporary"
  /bin/mkdir "$verifier_temporary"

  # A local header that disagrees with the central directory makes ditto
  # materialize a payload the inventory listing never declared. The container
  # preflight refuses it on the bytes, before any listing or extraction.
  local mismatch_source="$temporary/mismatch-source"
  /bin/mkdir -p "$mismatch_source/Parallax.app/Contents"
  /usr/bin/printf 'payload\n' \
    >"$mismatch_source/Parallax.app/Contents/Info.plist"
  local mismatch_zip="$temporary/header-mismatch.zip"
  (
    cd "$mismatch_source"
    /usr/bin/zip -q -r "$mismatch_zip" Parallax.app
  )
  [[ "$(/usr/bin/zipinfo -1 "$mismatch_zip" | /usr/bin/head -1)" \
      == "Parallax.app/" ]] \
    || fail "header-mismatch fixture does not start with the application root"
  /usr/bin/printf 'X' \
    | /bin/dd of="$mismatch_zip" bs=1 seek=30 count=1 conv=notrunc \
      >/dev/null 2>&1
  [[ "$(/usr/bin/zipinfo -1 "$mismatch_zip" | /usr/bin/head -1)" \
      == "Parallax.app/" ]] \
    || fail "header-mismatch fixture changed the central directory listing"
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$mismatch_zip" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "a ZIP whose local header disagrees with its inventory was accepted"
  fi
  assert_contains "$output" \
    "ZIP local header name contradicts the central directory"

  # A payload byte that no longer matches its stored checksum.
  local checksum_source="$temporary/checksum-source"
  /bin/mkdir -p "$checksum_source/Parallax.app/Contents"
  /usr/bin/printf 'payload\n' \
    >"$checksum_source/Parallax.app/Contents/Info.plist"
  LC_ALL=C /usr/bin/awk 'BEGIN { for (i = 0; i < 4096; i++) printf "a" }' \
    >"$checksum_source/Parallax.app/Contents/data.bin"
  local checksum_zip="$temporary/bad-checksum.zip"
  (
    cd "$checksum_source"
    /usr/bin/zip -0 -q -r "$checksum_zip" Parallax.app
  )
  /usr/bin/printf 'Z' \
    | /bin/dd of="$checksum_zip" bs=1 seek=1000 count=1 conv=notrunc \
      >/dev/null 2>&1
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$checksum_zip" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "a ZIP with a corrupt stored payload was accepted"
  fi
  assert_contains "$output" "ZIP payload integrity check failed"

  # No link or special entry may hide inside the application payload.
  local link_source="$temporary/link-source"
  /bin/mkdir -p "$link_source/Parallax.app/Contents/Resources"
  /usr/bin/printf 'payload\n' >"$link_source/Parallax.app/Contents/Info.plist"
  /bin/ln -s /Applications "$link_source/Parallax.app/Contents/Resources/escape"
  local link_zip="$temporary/inner-link.zip"
  (
    cd "$link_source"
    /usr/bin/zip -q -y -r "$link_zip" Parallax.app
  )
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$link_zip" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "a ZIP with a symbolic link inside the payload was accepted"
  fi
  assert_contains "$output" "ZIP contains a link or special entry"

  # Apple metadata may only describe payload the same archive carries.
  local metadata_source="$temporary/metadata-source"
  /bin/mkdir -p \
    "$metadata_source/Parallax.app/Contents" \
    "$metadata_source/__MACOSX/Parallax.app/Contents"
  /usr/bin/printf 'payload\n' \
    >"$metadata_source/Parallax.app/Contents/Info.plist"
  /usr/bin/printf 'orphan metadata\n' \
    >"$metadata_source/__MACOSX/Parallax.app/Contents/._ghost"
  local orphan_zip="$temporary/orphan-metadata.zip"
  (
    cd "$metadata_source"
    /usr/bin/zip -q -r "$orphan_zip" Parallax.app __MACOSX
  )
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$orphan_zip" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "a ZIP with an unpaired Apple metadata record was accepted"
  fi
  assert_contains "$output" "ZIP metadata record has no payload target"

  local smuggled_source="$temporary/smuggled-source"
  /bin/mkdir -p \
    "$smuggled_source/Parallax.app/Contents" \
    "$smuggled_source/__MACOSX/Parallax.app/Contents"
  /usr/bin/printf 'payload\n' \
    >"$smuggled_source/Parallax.app/Contents/Info.plist"
  /usr/bin/printf 'smuggled payload\n' \
    >"$smuggled_source/__MACOSX/Parallax.app/Contents/smuggled.sh"
  local smuggled_zip="$temporary/smuggled-metadata.zip"
  (
    cd "$smuggled_source"
    /usr/bin/zip -q -r "$smuggled_zip" Parallax.app __MACOSX
  )
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$smuggled_zip" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "a ZIP with non-metadata payload under __MACOSX was accepted"
  fi
  assert_contains "$output" "non-metadata payload under __MACOSX"

  # A genuine sequestered-resource layout must still clear every structural
  # gate and fail only on application content.
  local healthy_source="$temporary/healthy-source"
  /bin/mkdir -p "$healthy_source/Parallax.app/Contents/Resources"
  /usr/bin/printf 'payload\n' \
    >"$healthy_source/Parallax.app/Contents/Resources/resource.txt"
  /usr/bin/xattr -w com.parallax.inventory resource \
    "$healthy_source/Parallax.app/Contents/Resources/resource.txt"
  local healthy_zip="$temporary/healthy-metadata.zip"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
    "$healthy_source/Parallax.app" \
    "$healthy_zip"
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$healthy_zip" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "an incomplete healthy-layout fixture unexpectedly verified"
  fi
  assert_contains "$output" "application bundle is incomplete"
  [[ "$output" != *"payload integrity"* \
      && "$output" != *"link or special entry"* \
      && "$output" != *"metadata record"* \
      && "$output" != *"forbidden AppleDouble metadata"* ]] \
    || fail "a genuine sequestered-resource ZIP layout was rejected"
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$healthy_zip" \
      --expect-unsigned \
      --architecture native \
      2>&1
  )"; then
    fail "an unsigned sequestered-resource ZIP layout was accepted"
  fi
  assert_contains "$output" "ZIP contains forbidden AppleDouble metadata"

  # An AppleDouble sidecar inside the payload itself is refused before
  # extraction, without needing a sequestered metadata root.
  local sidecar_source="$temporary/sidecar-source"
  /bin/mkdir -p "$sidecar_source/Parallax.app/Contents"
  /usr/bin/printf 'payload\n' \
    >"$sidecar_source/Parallax.app/Contents/Info.plist"
  /usr/bin/printf 'sidecar\n' \
    >"$sidecar_source/Parallax.app/Contents/._Info.plist"
  local sidecar_zip="$temporary/appledouble-sidecar.zip"
  (
    cd "$sidecar_source"
    /usr/bin/zip -q -r "$sidecar_zip" Parallax.app
  )
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$sidecar_zip" \
      --expect-unsigned \
      --architecture native \
      2>&1
  )"; then
    fail "a ZIP carrying an AppleDouble sidecar was accepted"
  fi
  assert_contains "$output" "ZIP contains forbidden AppleDouble metadata"
  assert_no_verifier_temp_dirs "$verifier_temporary"
  pass "verification rejects corrupt, confused, and smuggled ZIP payloads"
}

# Builds a minimal bundle skeleton whose only defect is the one under test, so
# the inventory contract is exercised before any Mach-O or signature check.
create_inventory_fixture() {
  local root="$1"
  local app="$root/Parallax.app"
  /bin/mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  /usr/bin/printf 'deliberately not a plist\n' >"$app/Contents/Info.plist"
  /usr/bin/printf '#!/bin/sh\nexit 0\n' >"$app/Contents/MacOS/Parallax"
  normalize_inventory_fixture "$app"
}

normalize_inventory_fixture() {
  local app="$1"
  /usr/bin/find -x "$app" -type d -exec /bin/chmod 0755 {} +
  /usr/bin/find -x "$app" -type f -exec /bin/chmod 0644 {} +
  /bin/chmod 0755 "$app/Contents/MacOS/Parallax"
}

# Adds the complete published resource and signature layout, including both
# shipped localizations and every processed icon representation, so exact
# closure can be shown to accept the layout the packager really produces.
create_resource_inventory_fixture() {
  local root="$1"
  local app="$root/Parallax.app"
  create_inventory_fixture "$root"
  local bundle="$app/Contents/Resources/Parallax_Parallax.bundle"
  /bin/mkdir -p \
    "$app/Contents/_CodeSignature" \
    "$bundle/en.lproj" \
    "$bundle/es.lproj"
  /usr/bin/printf 'signature\n' >"$app/Contents/_CodeSignature/CodeResources"
  /usr/bin/printf 'icon\n' >"$app/Contents/Resources/AppIcon.icns"
  /usr/bin/printf 'provenance\n' \
    >"$app/Contents/Resources/PackagingProvenance.plist"
  /usr/bin/printf 'bundle plist\n' >"$bundle/Info.plist"
  /usr/bin/printf 'icon\n' >"$bundle/AppIcon.icns"
  /usr/bin/printf 'icon\n' >"$bundle/AppIcon.png"
  local size scale
  for size in 16x16 32x32 128x128 256x256 512x512; do
    for scale in "" "@2x"; do
      /usr/bin/printf 'icon\n' >"$bundle/icon_$size$scale.png"
    done
  done
  local language
  for language in en es; do
    /usr/bin/printf 'strings\n' \
      >"$bundle/$language.lproj/Localizable.strings"
    /usr/bin/printf 'stringsdict\n' \
      >"$bundle/$language.lproj/Localizable.stringsdict"
  done
  normalize_inventory_fixture "$app"
}

test_verifier_requires_a_closed_canonical_application_inventory() {
  local temporary output
  temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-package-test.XXXXXX")"
  TEMPORARY_DIRS="$TEMPORARY_DIRS $temporary"

  # A canonical skeleton must clear the inventory contract and fail only on
  # application content, so the gate cannot pass by rejecting everything.
  create_inventory_fixture "$temporary/canonical"
  if output="$(
    "$PACKAGER" verify \
      --artifact "$temporary/canonical/Parallax.app" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "an incomplete canonical fixture unexpectedly verified"
  fi
  assert_contains "$output" "Info.plist validation failed"

  create_inventory_fixture "$temporary/extra"
  /usr/bin/printf 'unexpected payload\n' \
    >"$temporary/extra/Parallax.app/Contents/unexpected.txt"
  /bin/chmod 0644 "$temporary/extra/Parallax.app/Contents/unexpected.txt"
  if output="$(
    "$PACKAGER" verify \
      --artifact "$temporary/extra/Parallax.app" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "an application bundle with unexpected payload was accepted"
  fi
  assert_contains "$output" "unexpected payload: Contents/unexpected.txt"

  # Exact closure: a published directory admits only its own declared
  # children, at the bundle root, inside the resource bundle, and inside a
  # localization, and a declared path admits only its own kind.
  create_resource_inventory_fixture "$temporary/complete"
  if output="$(
    "$PACKAGER" verify \
      --artifact "$temporary/complete/Parallax.app" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "an incomplete complete-layout fixture unexpectedly verified"
  fi
  assert_contains "$output" "Info.plist validation failed"

  local closure_case closure_path
  for closure_case in \
      "resource:Contents/Resources/payload.dylib" \
      "signature:Contents/_CodeSignature/extra" \
      "bundle:Contents/Resources/Parallax_Parallax.bundle/payload.dylib" \
      "language:Contents/Resources/Parallax_Parallax.bundle/en.lproj/extra.plist"; do
    closure_path="${closure_case#*:}"
    create_resource_inventory_fixture "$temporary/${closure_case%%:*}"
    /usr/bin/printf 'unexpected payload\n' \
      >"$temporary/${closure_case%%:*}/Parallax.app/$closure_path"
    normalize_inventory_fixture \
      "$temporary/${closure_case%%:*}/Parallax.app"
    if output="$(
      "$PACKAGER" verify \
        --artifact "$temporary/${closure_case%%:*}/Parallax.app" \
        --expect-local \
        --architecture native \
        2>&1
    )"; then
      fail "an application bundle with $closure_path was accepted"
    fi
    assert_contains "$output" "unexpected payload: $closure_path"
  done

  create_resource_inventory_fixture "$temporary/nested"
  /bin/mkdir \
    "$temporary/nested/Parallax.app/Contents/Resources/Parallax_Parallax.bundle/en.lproj/nested"
  /usr/bin/printf 'strings\n' \
    >"$temporary/nested/Parallax.app/Contents/Resources/Parallax_Parallax.bundle/en.lproj/nested/Localizable.strings"
  normalize_inventory_fixture "$temporary/nested/Parallax.app"
  if output="$(
    "$PACKAGER" verify \
      --artifact "$temporary/nested/Parallax.app" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "an application bundle with a nested localization was accepted"
  fi
  assert_contains "$output" \
    "unexpected payload: Contents/Resources/Parallax_Parallax.bundle/en.lproj/nested"

  create_resource_inventory_fixture "$temporary/kind"
  /bin/rm \
    "$temporary/kind/Parallax.app/Contents/Resources/PackagingProvenance.plist"
  /bin/mkdir \
    "$temporary/kind/Parallax.app/Contents/Resources/PackagingProvenance.plist"
  normalize_inventory_fixture "$temporary/kind/Parallax.app"
  if output="$(
    "$PACKAGER" verify \
      --artifact "$temporary/kind/Parallax.app" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "a directory standing in for the packaging provenance was accepted"
  fi
  assert_contains "$output" \
    "payload is not a regular file: Contents/Resources/PackagingProvenance.plist"

  create_resource_inventory_fixture "$temporary/bundle-kind"
  /bin/rm -r \
    "$temporary/bundle-kind/Parallax.app/Contents/Resources/Parallax_Parallax.bundle/en.lproj"
  /usr/bin/printf 'not a directory\n' \
    >"$temporary/bundle-kind/Parallax.app/Contents/Resources/Parallax_Parallax.bundle/en.lproj"
  normalize_inventory_fixture "$temporary/bundle-kind/Parallax.app"
  if output="$(
    "$PACKAGER" verify \
      --artifact "$temporary/bundle-kind/Parallax.app" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "a regular file standing in for a localization directory was accepted"
  fi
  assert_contains "$output" \
    "payload is not a directory: Contents/Resources/Parallax_Parallax.bundle/en.lproj"

  create_inventory_fixture "$temporary/executable"
  /usr/bin/printf 'second executable\n' \
    >"$temporary/executable/Parallax.app/Contents/MacOS/helper"
  /bin/chmod 0644 "$temporary/executable/Parallax.app/Contents/MacOS/helper"
  if output="$(
    "$PACKAGER" verify \
      --artifact "$temporary/executable/Parallax.app" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "an application bundle with a second executable was accepted"
  fi
  assert_contains "$output" "unexpected executable payload"

  create_inventory_fixture "$temporary/link"
  /bin/ln -s /Applications \
    "$temporary/link/Parallax.app/Contents/Resources/escape"
  if output="$(
    "$PACKAGER" verify \
      --artifact "$temporary/link/Parallax.app" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "an application bundle containing a symbolic link was accepted"
  fi
  assert_contains "$output" "contains a symbolic link"

  create_inventory_fixture "$temporary/residue"
  /usr/bin/printf 'finder residue\n' \
    >"$temporary/residue/Parallax.app/Contents/Resources/.DS_Store"
  /bin/chmod 0644 \
    "$temporary/residue/Parallax.app/Contents/Resources/.DS_Store"
  if output="$(
    "$PACKAGER" verify \
      --artifact "$temporary/residue/Parallax.app" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "an application bundle carrying hidden residue was accepted"
  fi
  assert_contains "$output" "hidden residue"

  create_inventory_fixture "$temporary/file-mode"
  /bin/chmod 0777 "$temporary/file-mode/Parallax.app/Contents/Info.plist"
  if output="$(
    "$PACKAGER" verify \
      --artifact "$temporary/file-mode/Parallax.app" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "an application file with non-canonical permissions was accepted"
  fi
  assert_contains "$output" "file permissions are not canonical"

  create_inventory_fixture "$temporary/directory-mode"
  /bin/chmod 0700 "$temporary/directory-mode/Parallax.app/Contents/Resources"
  if output="$(
    "$PACKAGER" verify \
      --artifact "$temporary/directory-mode/Parallax.app" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "an application directory with non-canonical permissions was accepted"
  fi
  assert_contains "$output" "directory permissions are not canonical"

  create_inventory_fixture "$temporary/bundle-mode"
  /bin/chmod 0700 "$temporary/bundle-mode/Parallax.app"
  if output="$(
    "$PACKAGER" verify \
      --artifact "$temporary/bundle-mode/Parallax.app" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "an application bundle with non-canonical permissions was accepted"
  fi
  assert_contains "$output" "application bundle permissions are not canonical"
  pass "verification requires a closed, canonically permissioned application"
}

# Flips one byte in place without needing a byte-editing tool, so a corrupt
# image fixture is always genuinely different from its source.
corrupt_one_byte() {
  local target="$1"
  local offset="$2"
  local original replacement
  original="$(
    /bin/dd if="$target" bs=1 skip="$offset" count=1 2>/dev/null \
      | /usr/bin/od -An -tu1 \
      | /usr/bin/tr -d ' \n'
  )"
  [[ "$original" =~ ^[0-9]+$ ]] || fail "cannot read byte $offset of $target"
  replacement=$(((original + 1) % 255 + 1))
  /usr/bin/printf "$(/usr/bin/printf '\\%03o' "$replacement")" \
    | /bin/dd of="$target" bs=1 seek="$offset" count=1 conv=notrunc \
      >/dev/null 2>&1
}

# The container bytes are the contract every downstream ZIP tool relies on, so
# each defect is introduced into an otherwise valid archive produced exactly the
# way this project produces one, and must be refused before the listing,
# integrity, and extraction stages run.
assert_zip_container_rejected() {
  local zip="$1"
  local verifier_temporary="$2"
  local label="$3"
  local expected="$4"
  local output
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$zip" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "a $label ZIP container was accepted"
  fi
  assert_contains "$output" "$expected"
}

test_verifier_rejects_noncanonical_zip_containers() {
  local temporary verifier_temporary source valid valid_hash output
  temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-package-test.XXXXXX")"
  TEMPORARY_DIRS="$TEMPORARY_DIRS $temporary"
  verifier_temporary="$temporary/verifier-temporary"
  /bin/mkdir "$verifier_temporary"
  source="$temporary/source"
  /bin/mkdir -p "$source/Parallax.app/Contents/Resources"
  /usr/bin/printf 'payload\n' >"$source/Parallax.app/Contents/Info.plist"
  /usr/bin/printf 'resource\n' \
    >"$source/Parallax.app/Contents/Resources/resource.txt"
  valid="$temporary/canonical.zip"
  (
    cd "$source"
    LC_ALL=C /usr/bin/find Parallax.app -print \
      | LC_ALL=C /usr/bin/sort \
      | /usr/bin/zip -X -y -q "$valid" -@
  )
  valid_hash="$(sha256 "$valid")"

  # The container this project actually produces must clear the byte contract
  # and fail only on application content, so the gate cannot pass by rejecting
  # everything.
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$valid" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "an incomplete canonical container unexpectedly verified"
  fi
  assert_contains "$output" "application bundle is incomplete"
  [[ "$output" != *"end-of-central-directory"* \
      && "$output" != *"central directory"* \
      && "$output" != *"local header"* \
      && "$output" != *"tile the payload region"* ]] \
    || fail "a canonical producer container was rejected"

  /bin/cp "$valid" "$temporary/trailing.zip"
  /usr/bin/printf 'X' >>"$temporary/trailing.zip"
  assert_zip_container_rejected \
    "$temporary/trailing.zip" "$verifier_temporary" "trailing-payload" \
    "ZIP end-of-central-directory record is not the archive tail"

  /bin/cp "$valid" "$temporary/commented.zip"
  /usr/bin/printf 'appended archive comment\n' \
    | /usr/bin/zip -q -z "$temporary/commented.zip"
  assert_zip_container_rejected \
    "$temporary/commented.zip" "$verifier_temporary" "commented" \
    "ZIP end-of-central-directory record is not the archive tail"

  /bin/cat "$valid" "$valid" >"$temporary/concatenated.zip"
  assert_zip_container_rejected \
    "$temporary/concatenated.zip" "$verifier_temporary" "concatenated" \
    "ZIP central directory does not end at the end record"

  /usr/bin/printf 'prefixed stub\n' >"$temporary/prefixed.zip"
  /bin/cat "$valid" >>"$temporary/prefixed.zip"
  assert_zip_container_rejected \
    "$temporary/prefixed.zip" "$verifier_temporary" "prefixed" \
    "ZIP central directory does not end at the end record"

  local encrypted_source="$temporary/encrypted-source"
  /bin/mkdir -p "$encrypted_source/Parallax.app/Contents"
  /usr/bin/printf 'payload\n' \
    >"$encrypted_source/Parallax.app/Contents/Info.plist"
  (
    cd "$encrypted_source"
    /usr/bin/zip -q -r -P parallax-fixture "$temporary/encrypted.zip" \
      Parallax.app
  )
  assert_zip_container_rejected \
    "$temporary/encrypted.zip" "$verifier_temporary" "encrypted" \
    "ZIP declares an encrypted entry"

  # The central directory keeps its listing while the local header no longer
  # names the same entry, so a listing-only check cannot see the difference.
  /bin/cp "$valid" "$temporary/renamed-local.zip"
  /usr/bin/printf 'X' \
    | /bin/dd of="$temporary/renamed-local.zip" bs=1 seek=30 count=1 \
      conv=notrunc >/dev/null 2>&1
  [[ "$(/usr/bin/zipinfo -1 "$temporary/renamed-local.zip" \
      | /usr/bin/head -1)" == "Parallax.app/" ]] \
    || fail "renamed-local fixture changed the central directory listing"
  assert_zip_container_rejected \
    "$temporary/renamed-local.zip" "$verifier_temporary" "renamed-local" \
    "ZIP local header name contradicts the central directory"

  [[ "$(sha256 "$valid")" == "$valid_hash" ]] \
    || fail "container verification changed its input bytes"
  assert_no_verifier_temp_dirs "$verifier_temporary"
  pass "verification rejects non-canonical ZIP containers"
}


test_verifier_rejects_hostile_dmg_containers() {
  local temporary verifier_temporary source output
  temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-package-test.XXXXXX")"
  TEMPORARY_DIRS="$TEMPORARY_DIRS $temporary"
  verifier_temporary="$temporary/verifier-temporary"
  /bin/mkdir "$verifier_temporary"
  source="$temporary/source"
  /bin/mkdir -p "$source/Parallax.app/Contents"
  /bin/dd if=/dev/urandom of="$source/Parallax.app/Contents/payload.bin" \
    bs=1024 count=512 >/dev/null 2>&1
  /bin/ln -s /Applications "$source/Applications"

  local dmg="$temporary/container.dmg"
  /usr/bin/hdiutil create \
    -volname "Parallax" \
    -srcfolder "$source" \
    -format UDZO \
    "$dmg" >/dev/null

  # The published container structure must still reach application checks.
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$dmg" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "an incomplete DMG payload unexpectedly verified"
  fi
  assert_contains "$output" "application bundle is incomplete"

  local corrupt="$temporary/corrupt.dmg"
  /bin/cp "$dmg" "$corrupt"
  corrupt_one_byte "$corrupt" "$(($(/usr/bin/stat -f %z "$corrupt") / 2))"
  if /usr/bin/cmp -s "$dmg" "$corrupt"; then
    fail "corrupt DMG fixture is byte-identical to its source"
  fi
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$corrupt" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "a DMG with corrupt image data was accepted"
  fi
  assert_contains "$output" "DMG checksum verification failed"

  local uncompressed="$temporary/uncompressed.dmg"
  /usr/bin/hdiutil convert "$dmg" -format UDRO -o "$uncompressed" \
    >/dev/null 2>&1 \
    || fail "cannot build the alternate-format DMG fixture"
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$uncompressed" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "a DMG in an unpublished image format was accepted"
  fi
  assert_contains "$output" "Format is UDRO, expected UDZO"

  local encrypted="$temporary/encrypted.dmg"
  /usr/bin/printf 'fixture-password' \
    | /usr/bin/hdiutil create \
      -volname "Parallax" \
      -srcfolder "$source" \
      -format UDZO \
      -encryption AES-256 \
      -stdinpass \
      "$encrypted" >/dev/null 2>&1 \
    || fail "cannot build the encrypted DMG fixture"
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$encrypted" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "an encrypted DMG was accepted"
  fi
  assert_contains "$output" "DMG image inspection failed"

  /bin/ln -s "$dmg" "$temporary/symbolic-container.dmg"
  if output="$(
    TMPDIR="$verifier_temporary" "$PACKAGER" verify \
      --artifact "$temporary/symbolic-container.dmg" \
      --expect-local \
      --architecture native \
      2>&1
  )"; then
    fail "a symbolic-link DMG input was accepted"
  fi
  assert_contains "$output" "DMG must be a regular non-symbolic-link file"
  assert_no_verifier_dmg_mounts
  assert_no_verifier_temp_dirs "$verifier_temporary"
  pass "verification rejects corrupt, encrypted, and unpublished DMG containers"
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
test_verifier_rejects_untrustworthy_zip_inputs
test_verifier_rejects_corrupt_or_smuggled_zip_payloads
test_verifier_requires_a_closed_canonical_application_inventory
test_verifier_rejects_noncanonical_zip_containers
test_verifier_rejects_hostile_dmg_containers
test_local_and_unsigned_artifacts

echo "1..$TEST_COUNT"
