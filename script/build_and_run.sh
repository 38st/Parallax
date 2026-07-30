#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Parallax"
RESOURCE_BUNDLE_NAME="Parallax_Parallax.bundle"
ICON_FILE="AppIcon.icns"
PROVENANCE_FILE="PackagingProvenance.plist"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
VERSION_ENV_WAS_SET="${VERSION+x}"
BUILD_NUMBER_ENV_WAS_SET="${BUILD_NUMBER+x}"
MIN_SYSTEM_VERSION_ENV_WAS_SET="${MIN_SYSTEM_VERSION+x}"
BUNDLE_ID="${BUNDLE_ID:-com.parallax.Parallax}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-14.0}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-}"
VERSION_WAS_SET="${VERSION_ENV_WAS_SET:+1}"
VERSION_WAS_SET="${VERSION_WAS_SET:-0}"
BUILD_NUMBER_WAS_SET="${BUILD_NUMBER_ENV_WAS_SET:+1}"
BUILD_NUMBER_WAS_SET="${BUILD_NUMBER_WAS_SET:-0}"
MIN_SYSTEM_VERSION_WAS_SET="${MIN_SYSTEM_VERSION_ENV_WAS_SET:+1}"
MIN_SYSTEM_VERSION_WAS_SET="${MIN_SYSTEM_VERSION_WAS_SET:-0}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool-profile}"
ARCHITECTURE=""
ARTIFACT=""
EXPECTATION=""
EXPECTED_TEAM_ID=""
EXPECT_NOTARIZED=0
CREATE_ZIP=-1
CREATE_DMG=0
NOTARIZE=0
STAPLE=0
CONFIGURATION="debug"
STAGING_DIR=""
LOCK_DIR=""
BUILD_LOCK_DIR=""
BUILD_CACHE_ROOT="/private/tmp/com.parallax.Parallax-SwiftPM"
MOUNT_POINT=""
PUBLISHED_DESTINATIONS=()
PUBLISHED_SOURCES=()
PUBLISH_COMMITTED=0

die() {
  echo "Error: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<USAGE
usage:
  $0 build|run|debug|logs|telemetry [options]
  $0 archive --version VERSION --build BUILD [--zip] [--dmg] [options]
  $0 release --sign IDENTITY --notarize --staple [--zip] [--dmg] [options]
  $0 verify --artifact PATH (--expect-local|--expect-unsigned|--expect-signed) [options]

modes:
  build/run/...  Build, ad-hoc sign, verify, and atomically publish a local debug app.
  archive        Build and verify an unsigned, hardened local release archive.
  release        Build, Developer ID sign, notarize, staple, and verify distribution artifacts.
  verify         Verify the specified existing .app, .zip, or .dmg without rebuilding it.

options:
  --version VERSION          CFBundleShortVersionString. Default: $VERSION
  --build BUILD              CFBundleVersion. Default: $BUILD_NUMBER
  --bundle-id IDENTIFIER     Bundle identifier. Default: $BUNDLE_ID
  --minimum-system-version V Minimum macOS version. Default: $MIN_SYSTEM_VERSION
  --architecture VALUE       native, universal, arm64, or x86_64.
                             Defaults: native for local/local verification;
                             universal for archive/release and signed/unsigned verification.
  --dist DIR                 Output directory. Default: $DIST_DIR
  --zip / --no-zip           Enable/disable ZIP output. Archive and release default to ZIP.
  --dmg                      Create a DMG with an Applications alias.
  --sign IDENTITY            Developer ID Application identity (release only).
  --notarize                 Submit release artifacts with notarytool.
  --staple                   Staple notarization tickets.
  --notary-profile NAME      notarytool keychain profile. Default: $NOTARY_PROFILE

verification options:
  --artifact PATH            Existing .app, .zip, or .dmg to verify.
  --expect-local             Expect a local ad-hoc signed debug app.
  --expect-unsigned          Expect an ad-hoc signed release rejected by Gatekeeper.
  --expect-signed            Expect a Developer ID signed release.
  --expect MODE              Alias accepting local, unsigned, or signed.
  --team-id TEAM             Required Team ID for signed verification.
  --notarized                Require stapler and Gatekeeper validation.

environment:
  SIGN_IDENTITY, VERSION, BUILD_NUMBER, BUNDLE_ID, MIN_SYSTEM_VERSION,
  DIST_DIR, NOTARY_PROFILE, SOURCE_DATE_EPOCH
USAGE
}

require_option_value() {
  [[ $# -ge 2 && -n "${2:-}" ]] || die "$1 requires a value"
}

if [[ "$MODE" == "--help" || "$MODE" == "-h" ]]; then
  usage
  exit 0
fi
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      require_option_value "$@"
      VERSION="$2"
      VERSION_WAS_SET=1
      shift 2
      ;;
    --build)
      require_option_value "$@"
      BUILD_NUMBER="$2"
      BUILD_NUMBER_WAS_SET=1
      shift 2
      ;;
    --bundle-id)
      require_option_value "$@"
      BUNDLE_ID="$2"
      shift 2
      ;;
    --minimum-system-version)
      require_option_value "$@"
      MIN_SYSTEM_VERSION="$2"
      MIN_SYSTEM_VERSION_WAS_SET=1
      shift 2
      ;;
    --architecture)
      require_option_value "$@"
      ARCHITECTURE="$2"
      shift 2
      ;;
    --dist)
      require_option_value "$@"
      DIST_DIR="$2"
      shift 2
      ;;
    --zip)
      CREATE_ZIP=1
      shift
      ;;
    --no-zip)
      CREATE_ZIP=0
      shift
      ;;
    --dmg)
      CREATE_DMG=1
      shift
      ;;
    --sign)
      require_option_value "$@"
      SIGN_IDENTITY="$2"
      shift 2
      ;;
    --notarize)
      NOTARIZE=1
      shift
      ;;
    --staple)
      STAPLE=1
      shift
      ;;
    --notary-profile)
      require_option_value "$@"
      NOTARY_PROFILE="$2"
      shift 2
      ;;
    --artifact)
      require_option_value "$@"
      ARTIFACT="$2"
      shift 2
      ;;
    --expect-local)
      EXPECTATION="local"
      shift
      ;;
    --expect-unsigned)
      EXPECTATION="unsigned"
      shift
      ;;
    --expect-signed)
      EXPECTATION="signed"
      shift
      ;;
    --expect)
      require_option_value "$@"
      EXPECTATION="$2"
      shift 2
      ;;
    --team-id)
      require_option_value "$@"
      EXPECTED_TEAM_ID="$2"
      shift 2
      ;;
    --notarized)
      EXPECT_NOTARIZED=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown option: $1"
      ;;
  esac
done

case "$MODE" in
  build|run|debug|logs|telemetry)
    CONFIGURATION="debug"
    [[ "$CREATE_ZIP" -eq -1 ]] && CREATE_ZIP=0
    ARCHITECTURE="${ARCHITECTURE:-native}"
    ;;
  archive)
    CONFIGURATION="release"
    [[ "$CREATE_ZIP" -eq -1 ]] && CREATE_ZIP=1
    ARCHITECTURE="${ARCHITECTURE:-universal}"
    ;;
  release)
    CONFIGURATION="release"
    [[ "$CREATE_ZIP" -eq -1 ]] && CREATE_ZIP=1
    ARCHITECTURE="${ARCHITECTURE:-universal}"
    NOTARIZE=1
    STAPLE=1
    ;;
  verify)
    [[ "$CREATE_ZIP" -eq -1 ]] && CREATE_ZIP=0
    if [[ -z "$ARCHITECTURE" ]]; then
      case "$EXPECTATION" in
        signed|unsigned) ARCHITECTURE="universal" ;;
        *) ARCHITECTURE="native" ;;
      esac
    fi
    ;;
  --build)
    MODE="build"
    CONFIGURATION="debug"
    [[ "$CREATE_ZIP" -eq -1 ]] && CREATE_ZIP=0
    ARCHITECTURE="${ARCHITECTURE:-native}"
    ;;
  --debug)
    MODE="debug"
    CONFIGURATION="debug"
    [[ "$CREATE_ZIP" -eq -1 ]] && CREATE_ZIP=0
    ARCHITECTURE="${ARCHITECTURE:-native}"
    ;;
  --logs)
    MODE="logs"
    CONFIGURATION="debug"
    [[ "$CREATE_ZIP" -eq -1 ]] && CREATE_ZIP=0
    ARCHITECTURE="${ARCHITECTURE:-native}"
    ;;
  --telemetry)
    MODE="telemetry"
    CONFIGURATION="debug"
    [[ "$CREATE_ZIP" -eq -1 ]] && CREATE_ZIP=0
    ARCHITECTURE="${ARCHITECTURE:-native}"
    ;;
  --verify)
    MODE="verify"
    [[ "$CREATE_ZIP" -eq -1 ]] && CREATE_ZIP=0
    if [[ -z "$ARCHITECTURE" ]]; then
      case "$EXPECTATION" in
        signed|unsigned) ARCHITECTURE="universal" ;;
        *) ARCHITECTURE="native" ;;
      esac
    fi
    ;;
  *)
    usage
    die "unknown mode: $MODE"
    ;;
esac

validate_inputs() {
  case "$DIST_DIR" in
    *$'\n'*) die "distribution directory cannot contain a newline" ;;
  esac
  [[ "$BUNDLE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$ ]] \
    || die "invalid bundle identifier: $BUNDLE_ID"
  [[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die "version must be semantic MAJOR.MINOR.PATCH"
  [[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] \
    || die "build number must be a positive integer"
  [[ "$MIN_SYSTEM_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] \
    || die "minimum system version must be numeric, for example 14.0"
  case "$ARCHITECTURE" in
    native|universal|arm64|x86_64) ;;
    *) die "architecture must be native, universal, arm64, or x86_64" ;;
  esac
  case "$EXPECTATION" in
    ""|local|unsigned|signed) ;;
    *) die "expectation must be local, unsigned, or signed" ;;
  esac
  if [[ -z "$SOURCE_DATE_EPOCH" ]]; then
    SOURCE_DATE_EPOCH="$(
      /usr/bin/git -C "$ROOT_DIR" show -s --format=%ct HEAD 2>/dev/null \
        || echo 0
    )"
  fi
  [[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] \
    || die "SOURCE_DATE_EPOCH must be a nonnegative integer"
}

require_tool() {
  [[ -x "$1" ]] || die "required tool is unavailable: $1"
}

native_architecture() {
  /usr/bin/uname -m
}

requested_architectures() {
  case "$ARCHITECTURE" in
    native) native_architecture ;;
    universal) echo "arm64 x86_64" ;;
    arm64|x86_64) echo "$ARCHITECTURE" ;;
  esac
}

preflight_tools() {
  require_tool /usr/bin/codesign
  require_tool /usr/bin/ditto
  require_tool /usr/bin/git
  require_tool /usr/bin/lipo
  require_tool /usr/bin/plutil
  require_tool /usr/bin/shasum
  require_tool /usr/bin/xcrun
  require_tool /usr/sbin/spctl
  command -v swift >/dev/null 2>&1 || die "Swift toolchain is unavailable"
  /usr/bin/xcrun --find vtool >/dev/null \
    || die "vtool is unavailable"
  if [[ "$CREATE_DMG" -eq 1 ]]; then
    require_tool /usr/bin/hdiutil
  fi
}

require_clean_release_tree() {
  /usr/bin/git -C "$ROOT_DIR" rev-parse --verify HEAD >/dev/null 2>&1 \
    || die "release requires a committed Git revision"
  local changes
  changes="$(/usr/bin/git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)"
  [[ -z "$changes" ]] \
    || die "release requires a clean Git working tree; commit or remove every tracked and untracked change first"
}

preflight_release_credentials() {
  [[ -n "$SIGN_IDENTITY" ]] \
    || die "release requires --sign IDENTITY or SIGN_IDENTITY"
  [[ "$NOTARIZE" -eq 1 && "$STAPLE" -eq 1 ]] \
    || die "release requires notarization and stapling"
  require_tool /usr/bin/security

  local identities
  identities="$(/usr/bin/security find-identity -v -p codesigning 2>&1)" \
    || die "unable to inspect signing identities"
  if ! /usr/bin/grep -F -- "$SIGN_IDENTITY" <<<"$identities" >/dev/null; then
    die "signing identity is not available: $SIGN_IDENTITY"
  fi

  /usr/bin/xcrun notarytool history \
    --keychain-profile "$NOTARY_PROFILE" \
    >/dev/null 2>&1 \
    || die "notary profile is unavailable or invalid: $NOTARY_PROFILE"
}

sha256() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

plist_read() {
  /usr/bin/plutil -extract "$1" raw -o - "$2"
}

normalize_os_version() {
  /usr/bin/awk -F. '{
    major = $1 + 0
    minor = (NF > 1 ? $2 : 0) + 0
    patch = (NF > 2 ? $3 : 0) + 0
    printf "%d.%d.%d\n", major, minor, patch
  }' <<<"$1"
}

verify_architectures() {
  local binary="$1"
  local declared="$2"
  local actual
  actual="$(/usr/bin/lipo -archs "$binary")" \
    || die "cannot inspect executable architectures"

  local expected
  case "$declared" in
    native) expected="$(native_architecture)" ;;
    universal) expected="arm64 x86_64" ;;
    arm64|x86_64) expected="$declared" ;;
    *) die "unknown declared architecture: $declared" ;;
  esac

  local architecture
  for architecture in $expected; do
    case " $actual " in
      *" $architecture "*) ;;
      *) die "missing executable architecture $architecture (found: $actual)" ;;
    esac
  done
  for architecture in $actual; do
    case " $expected " in
      *" $architecture "*) ;;
      *) die "undeclared executable architecture $architecture (expected: $expected)" ;;
    esac
  done
}

verify_deployment_target() {
  local binary="$1"
  local plist="$2"
  local plist_target
  plist_target="$(plist_read LSMinimumSystemVersion "$plist")"
  local normalized_plist
  normalized_plist="$(normalize_os_version "$plist_target")"

  local targets
  targets="$(/usr/bin/xcrun vtool -show-build "$binary" \
    | /usr/bin/awk '$1 == "minos" { print $2 }' \
    | /usr/bin/sort -u)"
  [[ -n "$targets" ]] || die "cannot read Mach-O deployment target"

  local target
  while IFS= read -r target; do
    [[ "$(normalize_os_version "$target")" == "$normalized_plist" ]] \
      || die "Info.plist minimum OS $plist_target does not match Mach-O $target"
  done <<<"$targets"
}

verify_resource_bundle() {
  local app="$1"
  local bundle="$app/Contents/Resources/$RESOURCE_BUNDLE_NAME"
  [[ -d "$bundle" ]] \
    || die "missing SwiftPM runtime resource bundle: $RESOURCE_BUNDLE_NAME"
  [[ -f "$bundle/$ICON_FILE" ]] \
    || die "SwiftPM resource bundle cannot load $ICON_FILE"
  [[ -f "$app/Contents/Resources/$ICON_FILE" ]] \
    || die "missing application icon"
  [[ -f "$app/Contents/Resources/$PROVENANCE_FILE" ]] \
    || die "missing packaging provenance"
  /usr/bin/plutil -lint "$bundle/Info.plist" >/dev/null \
    || die "invalid SwiftPM resource bundle Info.plist"
  /usr/bin/plutil -lint \
    "$app/Contents/Resources/$PROVENANCE_FILE" >/dev/null \
    || die "invalid packaging provenance"
}

verify_code_signature() {
  local app="$1"
  local expectation="$2"
  local expected_bundle_id="$3"
  local expected_team_id="$4"
  local require_notarized="$5"

  /usr/bin/codesign --verify --strict --deep --verbose=2 "$app" \
    || die "strict code-signature verification failed"
  local details
  details="$(/usr/bin/codesign -d --verbose=4 "$app" 2>&1)"
  /usr/bin/grep -F "Identifier=$expected_bundle_id" <<<"$details" >/dev/null \
    || die "code-signing identifier does not match $expected_bundle_id"
  /usr/bin/grep -E 'flags=.*runtime' <<<"$details" >/dev/null \
    || die "hardened runtime is not enabled"

  case "$expectation" in
    local|unsigned)
      /usr/bin/grep -F "TeamIdentifier=not set" <<<"$details" >/dev/null \
        || die "expected an unsigned ad-hoc signature"
      if [[ "$expectation" == "unsigned" ]] \
          && /usr/sbin/spctl --assess --type execute "$app" >/dev/null 2>&1; then
        die "unsigned archive was unexpectedly accepted by Gatekeeper"
      fi
      ;;
    signed)
      local actual_team_id
      actual_team_id="$(/usr/bin/awk -F= \
        '/^TeamIdentifier=/{print $2; exit}' <<<"$details")"
      [[ -n "$actual_team_id" && "$actual_team_id" != "not set" ]] \
        || die "signed release has no Team ID"
      if [[ -n "$expected_team_id" && "$actual_team_id" != "$expected_team_id" ]]; then
        die "Team ID $actual_team_id does not match $expected_team_id"
      fi
      /usr/sbin/spctl --assess --type execute --verbose=4 "$app" \
        || die "Gatekeeper rejected the signed release"
      if [[ "$require_notarized" -eq 1 ]]; then
        /usr/bin/xcrun stapler validate "$app" \
          || die "application notarization ticket is missing"
      fi
      ;;
  esac
}

verify_app() {
  local app="$1"
  local expectation="$2"
  local architecture="$3"
  local expected_bundle_id="$4"
  local expected_team_id="$5"
  local require_notarized="$6"

  [[ -d "$app" && "${app##*.}" == "app" ]] \
    || die "artifact is not an application bundle: $app"
  local plist="$app/Contents/Info.plist"
  local binary="$app/Contents/MacOS/$APP_NAME"
  [[ -f "$plist" && -x "$binary" ]] \
    || die "application bundle is incomplete"
  /usr/bin/plutil -lint "$plist" >/dev/null \
    || die "Info.plist validation failed"
  [[ "$(plist_read CFBundleIdentifier "$plist")" == "$expected_bundle_id" ]] \
    || die "Info.plist bundle identifier does not match $expected_bundle_id"
  [[ "$(plist_read CFBundleExecutable "$plist")" == "$APP_NAME" ]] \
    || die "Info.plist executable is incorrect"
  local artifact_version
  artifact_version="$(plist_read CFBundleShortVersionString "$plist")"
  [[ "$artifact_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die "Info.plist version is not semantic MAJOR.MINOR.PATCH"
  if [[ "$VERSION_WAS_SET" -eq 1 && "$artifact_version" != "$VERSION" ]]; then
    die "Info.plist version $artifact_version does not match $VERSION"
  fi
  local artifact_build
  artifact_build="$(plist_read CFBundleVersion "$plist")"
  [[ "$artifact_build" =~ ^[1-9][0-9]*$ ]] \
    || die "Info.plist build number is not a positive integer"
  if [[ "$BUILD_NUMBER_WAS_SET" -eq 1 \
      && "$artifact_build" != "$BUILD_NUMBER" ]]; then
    die "Info.plist build $artifact_build does not match $BUILD_NUMBER"
  fi
  local artifact_minimum_os
  artifact_minimum_os="$(plist_read LSMinimumSystemVersion "$plist")"
  [[ "$artifact_minimum_os" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] \
    || die "Info.plist minimum OS is invalid"
  if [[ "$MIN_SYSTEM_VERSION_WAS_SET" -eq 1 \
      && "$(normalize_os_version "$artifact_minimum_os")" \
        != "$(normalize_os_version "$MIN_SYSTEM_VERSION")" ]]; then
    die "Info.plist minimum OS $artifact_minimum_os does not match $MIN_SYSTEM_VERSION"
  fi

  verify_architectures "$binary" "$architecture"
  verify_deployment_target "$binary" "$plist"
  verify_resource_bundle "$app"
  verify_code_signature \
    "$app" \
    "$expectation" \
    "$expected_bundle_id" \
    "$expected_team_id" \
    "$require_notarized"
}

safe_zip_entries() {
  local zip="$1"
  local entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    [[ "$entry" != /* ]] || die "ZIP contains an absolute path"
    case "/$entry/" in
      */../*) die "ZIP contains a traversing path" ;;
    esac
  done < <(/usr/bin/zipinfo -1 "$zip")
}

verify_zip() {
  local zip="$1"
  local expectation="$2"
  local architecture="$3"
  local expected_bundle_id="$4"
  local expected_team_id="$5"
  local require_notarized="$6"
  require_tool /usr/bin/zipinfo
  safe_zip_entries "$zip"

  local temporary
  temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-verify-zip.XXXXXX")"
  /usr/bin/ditto -x -k "$zip" "$temporary"
  local app="$temporary/$APP_NAME.app"
  if [[ ! -d "$app" ]]; then
    /bin/rm -rf "$temporary"
    die "ZIP does not contain $APP_NAME.app at its root"
  fi
  verify_app \
    "$app" \
    "$expectation" \
    "$architecture" \
    "$expected_bundle_id" \
    "$expected_team_id" \
    "$require_notarized"
  /bin/rm -rf "$temporary"
}

verify_dmg() {
  local dmg="$1"
  local expectation="$2"
  local architecture="$3"
  local expected_bundle_id="$4"
  local expected_team_id="$5"
  local require_notarized="$6"
  require_tool /usr/bin/hdiutil

  local temporary
  temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-verify-dmg.XXXXXX")"
  MOUNT_POINT="$temporary/mount"
  /bin/mkdir "$MOUNT_POINT"
  /usr/bin/hdiutil attach \
    -readonly \
    -nobrowse \
    -mountpoint "$MOUNT_POINT" \
    "$dmg" >/dev/null

  [[ -L "$MOUNT_POINT/Applications" ]] \
    || die "DMG is missing the Applications alias"
  [[ "$(/usr/bin/readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] \
    || die "DMG Applications alias has an unexpected target"
  verify_app \
    "$MOUNT_POINT/$APP_NAME.app" \
    "$expectation" \
    "$architecture" \
    "$expected_bundle_id" \
    "$expected_team_id" \
    "$require_notarized"

  /usr/bin/hdiutil detach "$MOUNT_POINT" >/dev/null
  MOUNT_POINT=""
  /bin/rm -rf "$temporary"

  if [[ "$expectation" == "signed" && "$require_notarized" -eq 1 ]]; then
    /usr/bin/codesign --verify --verbose=2 "$dmg" \
      || die "DMG signature verification failed"
    /usr/bin/xcrun stapler validate "$dmg" \
      || die "DMG notarization ticket is missing"
  fi
}

verify_artifact() {
  local artifact="$1"
  local expectation="$2"
  local architecture="$3"
  local expected_bundle_id="$4"
  local expected_team_id="$5"
  local require_notarized="$6"
  [[ -e "$artifact" ]] || die "artifact does not exist: $artifact"

  case "$artifact" in
    *.app)
      verify_app \
        "$artifact" "$expectation" "$architecture" \
        "$expected_bundle_id" "$expected_team_id" "$require_notarized"
      ;;
    *.zip)
      verify_zip \
        "$artifact" "$expectation" "$architecture" \
        "$expected_bundle_id" "$expected_team_id" "$require_notarized"
      ;;
    *.dmg)
      verify_dmg \
        "$artifact" "$expectation" "$architecture" \
        "$expected_bundle_id" "$expected_team_id" "$require_notarized"
      ;;
    *)
      die "unsupported artifact type (expected .app, .zip, or .dmg)"
      ;;
  esac
}

cleanup() {
  local status=$?
  if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
    if [[ "$status" -ne 0 && "$PUBLISH_COMMITTED" -eq 0 ]]; then
      local index
      for ((index = 0; index < ${#PUBLISHED_DESTINATIONS[@]}; index++)); do
        local destination="${PUBLISHED_DESTINATIONS[$index]}"
        local source="${PUBLISHED_SOURCES[$index]}"
        if [[ -f "$destination" && -f "$source" \
            && "$(/usr/bin/stat -f %i "$destination")" \
              == "$(/usr/bin/stat -f %i "$source")" ]]; then
          /bin/rm -f "$destination"
        fi
      done
    fi
    case "$(basename "$STAGING_DIR")" in
      .parallax-package.*) /bin/rm -rf "$STAGING_DIR" ;;
    esac
  fi
  if [[ -n "$LOCK_DIR" && -d "$LOCK_DIR" ]]; then
    /bin/rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
  fi
  if [[ -n "$BUILD_LOCK_DIR" && -d "$BUILD_LOCK_DIR" ]]; then
    /bin/rmdir "$BUILD_LOCK_DIR" >/dev/null 2>&1 || true
  fi
  exit "$status"
}

prepare_stable_build_cache() {
  [[ ! -L "$BUILD_CACHE_ROOT" ]] \
    || die "stable SwiftPM build cache cannot be a symbolic link"
  if [[ -e "$BUILD_CACHE_ROOT" ]]; then
    [[ -d "$BUILD_CACHE_ROOT" ]] \
      || die "stable SwiftPM build cache is not a directory"
    [[ "$(/usr/bin/stat -f %u "$BUILD_CACHE_ROOT")" \
        == "$(/usr/bin/id -u)" ]] \
      || die "stable SwiftPM build cache is owned by another user"
  else
    /bin/mkdir -m 0700 "$BUILD_CACHE_ROOT"
  fi
  /bin/chmod 0700 "$BUILD_CACHE_ROOT"
  BUILD_LOCK_DIR="$BUILD_CACHE_ROOT/.packaging.lock"
  /bin/mkdir "$BUILD_LOCK_DIR" 2>/dev/null \
    || die "another Parallax build is using the stable SwiftPM cache"
}

build_slice() {
  local architecture="$1"
  local configuration="$2"
  local triple="${architecture}-apple-macosx"
  local scratch="$BUILD_CACHE_ROOT/$configuration-$architecture"
  swift build \
    -c "$configuration" \
    --triple "$triple" \
    --scratch-path "$scratch" >&2
  swift build \
    -c "$configuration" \
    --triple "$triple" \
    --scratch-path "$scratch" \
    --show-bin-path
}

copy_resource_bundle() {
  local source_bundle="$1"
  local destination_bundle="$2"
  [[ -d "$source_bundle" ]] \
    || die "SwiftPM did not produce $RESOURCE_BUNDLE_NAME"
  /usr/bin/ditto "$source_bundle" "$destination_bundle"
}

write_info_plist() {
  local plist="$1"
  /usr/bin/plutil -create xml1 "$plist"
  /usr/bin/plutil -insert CFBundleDevelopmentRegion -string en "$plist"
  /usr/bin/plutil -insert CFBundleDisplayName -string "$APP_NAME" "$plist"
  /usr/bin/plutil -insert CFBundleExecutable -string "$APP_NAME" "$plist"
  /usr/bin/plutil -insert CFBundleIconFile -string AppIcon "$plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$plist"
  /usr/bin/plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$plist"
  /usr/bin/plutil -insert CFBundleName -string "$APP_NAME" "$plist"
  /usr/bin/plutil -insert CFBundlePackageType -string APPL "$plist"
  /usr/bin/plutil -insert CFBundleShortVersionString -string "$VERSION" "$plist"
  /usr/bin/plutil -insert CFBundleVersion -string "$BUILD_NUMBER" "$plist"
  /usr/bin/plutil -insert LSApplicationCategoryType \
    -string public.app-category.utilities "$plist"
  /usr/bin/plutil -insert LSMinimumSystemVersion \
    -string "$MIN_SYSTEM_VERSION" "$plist"
  /usr/bin/plutil -insert NSHighResolutionCapable -bool YES "$plist"
  /usr/bin/plutil -insert NSPrincipalClass -string NSApplication "$plist"
  /usr/bin/plutil -lint "$plist" >/dev/null
}

write_provenance() {
  local plist="$1"
  local binary="$2"
  local signing_identity="$3"
  local architectures
  architectures="$(/usr/bin/lipo -archs "$binary")"
  local git_revision
  git_revision="$(/usr/bin/git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null \
    || echo unavailable)"
  local dirty="NO"
  if [[ -n "$(/usr/bin/git -C "$ROOT_DIR" status --porcelain 2>/dev/null)" ]]; then
    dirty="YES"
  fi
  local toolchain
  toolchain="$(swift --version 2>&1 | /usr/bin/sed -n '1p')"
  local sdk
  sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"
  local built_at
  built_at="$(/bin/date -u -r "$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"

  /usr/bin/plutil -create xml1 "$plist"
  /usr/bin/plutil -insert Application -string "$APP_NAME" "$plist"
  /usr/bin/plutil -insert Architectures -string "$architectures" "$plist"
  /usr/bin/plutil -insert PreSigningBinarySHA256 \
    -string "$(sha256 "$binary")" "$plist"
  /usr/bin/plutil -insert BuildNumber -string "$BUILD_NUMBER" "$plist"
  /usr/bin/plutil -insert BuiltAtUTC -string "$built_at" "$plist"
  /usr/bin/plutil -insert BundleIdentifier -string "$BUNDLE_ID" "$plist"
  /usr/bin/plutil -insert GitDirty -bool "$dirty" "$plist"
  /usr/bin/plutil -insert GitRevision -string "$git_revision" "$plist"
  /usr/bin/plutil -insert MinimumSystemVersion \
    -string "$MIN_SYSTEM_VERSION" "$plist"
  /usr/bin/plutil -insert SDKVersion -string "$sdk" "$plist"
  /usr/bin/plutil -insert SigningIdentity -string "$signing_identity" "$plist"
  /usr/bin/plutil -insert SourceDateEpoch \
    -integer "$SOURCE_DATE_EPOCH" "$plist"
  /usr/bin/plutil -insert SwiftToolchain -string "$toolchain" "$plist"
  /usr/bin/plutil -insert Version -string "$VERSION" "$plist"
  /usr/bin/plutil -lint "$plist" >/dev/null
}

assemble_app() {
  local app="$1"
  local architectures
  architectures="$(requested_architectures)"
  local contents="$app/Contents"
  local macos="$contents/MacOS"
  local resources="$contents/Resources"
  local binary="$macos/$APP_NAME"
  /bin/mkdir -p "$macos" "$resources"

  local first_build_dir=""
  local architecture
  local slice_paths=""
  for architecture in $architectures; do
    local build_dir
    build_dir="$(build_slice "$architecture" "$CONFIGURATION")"
    [[ -x "$build_dir/$APP_NAME" ]] \
      || die "SwiftPM did not produce the $APP_NAME executable"
    slice_paths="$slice_paths $build_dir/$APP_NAME"
    if [[ -z "$first_build_dir" ]]; then
      first_build_dir="$build_dir"
    else
      /usr/bin/diff -qr \
        "$first_build_dir/$RESOURCE_BUNDLE_NAME" \
        "$build_dir/$RESOURCE_BUNDLE_NAME" >/dev/null \
        || die "SwiftPM resource bundles differ between architectures"
    fi
  done

  if [[ "$ARCHITECTURE" == "universal" ]]; then
    # shellcheck disable=SC2086
    /usr/bin/lipo -create $slice_paths -output "$binary"
  else
    /bin/cp "${slice_paths# }" "$binary"
  fi
  /bin/chmod 0755 "$binary"

  copy_resource_bundle \
    "$first_build_dir/$RESOURCE_BUNDLE_NAME" \
    "$resources/$RESOURCE_BUNDLE_NAME"
  /bin/cp "$resources/$RESOURCE_BUNDLE_NAME/$ICON_FILE" \
    "$resources/$ICON_FILE"
  write_info_plist "$contents/Info.plist"
  write_provenance \
    "$resources/$PROVENANCE_FILE" \
    "$binary" \
    "${SIGN_IDENTITY:-adhoc}"
  verify_deployment_target "$binary" "$contents/Info.plist"
}

sign_app() {
  local app="$1"
  if [[ "$MODE" == "release" ]]; then
    /usr/bin/codesign \
      --force \
      --deep \
      --options runtime \
      --timestamp \
      --sign "$SIGN_IDENTITY" \
      "$app"
  else
    /usr/bin/codesign \
      --force \
      --deep \
      --options runtime \
      --sign - \
      "$app"
  fi
}

notarize_and_staple_app() {
  local app="$1"
  local submission_zip="$STAGING_DIR/$APP_NAME-notary-submission.zip"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
    "$app" "$submission_zip"
  /usr/bin/xcrun notarytool submit \
    "$submission_zip" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
  /bin/rm -f "$submission_zip"
  /usr/bin/xcrun stapler staple "$app"
  /usr/bin/xcrun stapler validate "$app"
}

create_zip() {
  local app="$1"
  local output="$2"
  if [[ "$MODE" == "release" ]]; then
    # Preserve Apple-specific metadata on the final stapled bundle. Release
    # mode verifies the re-extracted ticket before publication.
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
      "$app" "$output"
    return
  fi
  local parent
  parent="$(/usr/bin/dirname "$app")"
  (
    cd "$parent"
    LC_ALL=C /usr/bin/find "$APP_NAME.app" -print \
      | LC_ALL=C /usr/bin/sort \
      | /usr/bin/zip -X -y -q "$output" -@
  )
}

create_dmg() {
  local app="$1"
  local output="$2"
  local source="$STAGING_DIR/dmg-source"
  /bin/mkdir "$source"
  /usr/bin/ditto "$app" "$source/$APP_NAME.app"
  /bin/ln -s /Applications "$source/Applications"
  normalize_tree_timestamps "$source"
  /usr/bin/hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$source" \
    -format UDZO \
    "$output" >/dev/null
}

normalize_tree_timestamps() {
  local root="$1"
  while IFS= read -r -d '' entry; do
    /usr/bin/touch -h -t \
      "$(/bin/date -u -r "$SOURCE_DATE_EPOCH" +%Y%m%d%H%M.%S)" \
      "$entry"
  done < <(/usr/bin/find "$root" -print0)
}

sign_notarize_and_staple_dmg() {
  local dmg="$1"
  /usr/bin/codesign \
    --force \
    --timestamp \
    --sign "$SIGN_IDENTITY" \
    "$dmg"
  /usr/bin/xcrun notarytool submit \
    "$dmg" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
  /usr/bin/xcrun stapler staple "$dmg"
  /usr/bin/xcrun stapler validate "$dmg"
}

publish_file_exclusively() {
  local source="$1"
  local destination="$2"
  /bin/ln "$source" "$destination" 2>/dev/null \
    || die "artifact collision: $destination already exists"
  PUBLISHED_SOURCES[${#PUBLISHED_SOURCES[@]}]="$source"
  PUBLISHED_DESTINATIONS[${#PUBLISHED_DESTINATIONS[@]}]="$destination"
}

publish_local_app() {
  local source="$1"
  local destination="$2"
  local backup="$STAGING_DIR/previous-$APP_NAME.app"
  if [[ -e "$destination" ]]; then
    /bin/mv "$destination" "$backup"
  fi
  if ! /bin/mv "$source" "$destination"; then
    if [[ -e "$backup" ]]; then
      /bin/mv "$backup" "$destination"
    fi
    die "could not publish local application"
  fi
  if [[ -e "$backup" ]]; then
    /bin/rm -rf "$backup"
  fi
}

if [[ "$MODE" == "verify" ]]; then
  validate_inputs
  [[ -n "$ARTIFACT" ]] || die "verify requires --artifact PATH"
  [[ -n "$EXPECTATION" ]] \
    || die "verify requires --expect-local, --expect-unsigned, or --expect-signed"
  if [[ "$EXPECT_NOTARIZED" -eq 1 && "$EXPECTATION" != "signed" ]]; then
    die "--notarized requires --expect-signed"
  fi
  preflight_tools
  verify_artifact \
    "$ARTIFACT" \
    "$EXPECTATION" \
    "$ARCHITECTURE" \
    "$BUNDLE_ID" \
    "$EXPECTED_TEAM_ID" \
    "$EXPECT_NOTARIZED"
  echo "Verified $ARTIFACT"
  exit 0
fi

trap cleanup EXIT INT TERM HUP
validate_inputs
preflight_tools
prepare_stable_build_cache
if [[ "$MODE" == "release" ]]; then
  require_clean_release_tree
  preflight_release_credentials
elif [[ -n "$SIGN_IDENTITY" || "$NOTARIZE" -eq 1 || "$STAPLE" -eq 1 ]]; then
  die "signing and notarization options are valid only in release mode"
fi

ARTIFACT_STEM="$APP_NAME-$VERSION-$BUILD_NUMBER"
ZIP_OUTPUT="$DIST_DIR/$ARTIFACT_STEM.zip"
DMG_OUTPUT="$DIST_DIR/$ARTIFACT_STEM.dmg"
PROVENANCE_OUTPUT="$DIST_DIR/$ARTIFACT_STEM.provenance.plist"
if [[ "$MODE" == "archive" || "$MODE" == "release" ]]; then
  [[ "$CREATE_ZIP" -eq 1 || "$CREATE_DMG" -eq 1 ]] \
    || die "archive and release require at least one of --zip or --dmg"
  [[ ! -e "$PROVENANCE_OUTPUT" ]] \
    || die "artifact collision: $PROVENANCE_OUTPUT"
  if [[ "$CREATE_ZIP" -eq 1 ]]; then
    [[ ! -e "$ZIP_OUTPUT" ]] || die "artifact collision: $ZIP_OUTPUT"
  fi
  if [[ "$CREATE_DMG" -eq 1 ]]; then
    [[ ! -e "$DMG_OUTPUT" ]] || die "artifact collision: $DMG_OUTPUT"
  fi
fi

/bin/mkdir -p "$DIST_DIR"
DIST_DIR="$(cd "$DIST_DIR" && pwd -P)"
LOCK_DIR="$DIST_DIR/.parallax-packaging.lock"
/bin/mkdir "$LOCK_DIR" 2>/dev/null \
  || die "another packaging invocation is active for $DIST_DIR"
STAGING_DIR="$(/usr/bin/mktemp -d "$DIST_DIR/.parallax-package.XXXXXX")"

STAGED_APP="$STAGING_DIR/$APP_NAME.app"
assemble_app "$STAGED_APP"
sign_app "$STAGED_APP"

APP_EXPECTATION="local"
APP_NOTARIZED=0
if [[ "$MODE" == "archive" ]]; then
  APP_EXPECTATION="unsigned"
elif [[ "$MODE" == "release" ]]; then
  notarize_and_staple_app "$STAGED_APP"
  APP_EXPECTATION="signed"
  APP_NOTARIZED=1
fi

verify_app \
  "$STAGED_APP" \
  "$APP_EXPECTATION" \
  "$ARCHITECTURE" \
  "$BUNDLE_ID" \
  "" \
  "$APP_NOTARIZED"

if [[ "$MODE" == "build" || "$MODE" == "run" \
    || "$MODE" == "debug" || "$MODE" == "logs" \
    || "$MODE" == "telemetry" ]]; then
  publish_local_app "$STAGED_APP" "$DIST_DIR/$APP_NAME.app"
  case "$MODE" in
    run)
      /usr/bin/open -n "$DIST_DIR/$APP_NAME.app"
      ;;
    debug)
      lldb -- "$DIST_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME"
      ;;
    logs)
      /usr/bin/open -n "$DIST_DIR/$APP_NAME.app"
      /usr/bin/log stream \
        --info \
        --style compact \
        --predicate "process == \"$APP_NAME\""
      ;;
    telemetry)
      /usr/bin/open -n "$DIST_DIR/$APP_NAME.app"
      /usr/bin/log stream \
        --info \
        --style compact \
        --predicate "subsystem == \"$BUNDLE_ID\""
      ;;
  esac
  echo "Built $DIST_DIR/$APP_NAME.app"
  exit 0
fi

normalize_tree_timestamps "$STAGED_APP"

STAGED_ZIP="$STAGING_DIR/$ARTIFACT_STEM.zip"
STAGED_DMG="$STAGING_DIR/$ARTIFACT_STEM.dmg"
STAGED_PROVENANCE="$STAGING_DIR/$ARTIFACT_STEM.provenance.plist"
if [[ "$CREATE_ZIP" -eq 1 ]]; then
  create_zip "$STAGED_APP" "$STAGED_ZIP"
  verify_zip \
    "$STAGED_ZIP" "$APP_EXPECTATION" "$ARCHITECTURE" \
    "$BUNDLE_ID" "" "$APP_NOTARIZED"
fi
if [[ "$CREATE_DMG" -eq 1 ]]; then
  create_dmg "$STAGED_APP" "$STAGED_DMG"
  if [[ "$MODE" == "release" ]]; then
    sign_notarize_and_staple_dmg "$STAGED_DMG"
  fi
  verify_dmg \
    "$STAGED_DMG" "$APP_EXPECTATION" "$ARCHITECTURE" \
    "$BUNDLE_ID" "" "$APP_NOTARIZED"
fi

/bin/cp \
  "$STAGED_APP/Contents/Resources/$PROVENANCE_FILE" \
  "$STAGED_PROVENANCE"
/usr/bin/plutil -insert PackagedBinarySHA256 \
  -string "$(sha256 "$STAGED_APP/Contents/MacOS/$APP_NAME")" \
  "$STAGED_PROVENANCE"
if [[ "$CREATE_ZIP" -eq 1 ]]; then
  /usr/bin/plutil -insert ZIPSHA256 -string "$(sha256 "$STAGED_ZIP")" \
    "$STAGED_PROVENANCE"
fi
if [[ "$CREATE_DMG" -eq 1 ]]; then
  /usr/bin/plutil -insert DMGSHA256 -string "$(sha256 "$STAGED_DMG")" \
    "$STAGED_PROVENANCE"
fi
/usr/bin/plutil -lint "$STAGED_PROVENANCE" >/dev/null

if [[ "$CREATE_ZIP" -eq 1 ]]; then
  publish_file_exclusively "$STAGED_ZIP" "$DIST_DIR/$ARTIFACT_STEM.zip"
fi
if [[ "$CREATE_DMG" -eq 1 ]]; then
  publish_file_exclusively "$STAGED_DMG" "$DIST_DIR/$ARTIFACT_STEM.dmg"
fi
publish_file_exclusively \
  "$STAGED_PROVENANCE" \
  "$DIST_DIR/$ARTIFACT_STEM.provenance.plist"
PUBLISH_COMMITTED=1

echo "Published verified $MODE artifacts for $ARTIFACT_STEM in $DIST_DIR"
