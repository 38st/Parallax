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

BUILD_SCRIPT_LIB_DIR="$ROOT_DIR/script/lib/build_and_run"
# Keep the command entry point small while loading each packaging responsibility.
source "$BUILD_SCRIPT_LIB_DIR/input_and_tools.sh"
source "$BUILD_SCRIPT_LIB_DIR/artifact_verification.sh"
source "$BUILD_SCRIPT_LIB_DIR/app_assembly.sh"
source "$BUILD_SCRIPT_LIB_DIR/artifact_distribution.sh"

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
