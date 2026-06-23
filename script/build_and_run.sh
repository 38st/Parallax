#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Parallax"
BUNDLE_ID="${BUNDLE_ID:-com.parallax.Parallax}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-14.0}"
CONFIGURATION="debug"
CREATE_ZIP=0
CREATE_DMG=0
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
DIST_DIR="${DIST_DIR:-}"
NOTARIZE=0
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool-profile}"
STAPLE=0

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_DIST_DIR="$ROOT_DIR/dist"
DIST_DIR="${DIST_DIR:-$DEFAULT_DIST_DIR}"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_FILE="AppIcon.icns"

usage() {
  cat >&2 <<USAGE
usage: $0 [build|run|debug|logs|telemetry|verify|release] [options]

options:
  --version VERSION        Set CFBundleShortVersionString. Default: $VERSION
  --build BUILD           Set CFBundleVersion. Default: $BUILD_NUMBER
  --sign IDENTITY         Sign the app with codesign identity.
  --notarize              Notarize the signed app with notarytool.
  --staple                Staple the notarization ticket to the app.
  --notary-profile NAME   Keychain profile for notarytool. Default: $NOTARY_PROFILE
  --zip                   Create dist/Parallax-VERSION-BUILD.zip.
  --dmg                   Create dist/Parallax-VERSION-BUILD.dmg.
  --dist DIR              Output directory. Default: dist
  --help                  Show this help.

environment:
  SIGN_IDENTITY, VERSION, BUILD_NUMBER, BUNDLE_ID, MIN_SYSTEM_VERSION, DIST_DIR, NOTARY_PROFILE
USAGE
}

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --build)
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --sign)
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
      NOTARY_PROFILE="$2"
      shift 2
      ;;
    --zip)
      CREATE_ZIP=1
      shift
      ;;
    --dmg)
      CREATE_DMG=1
      shift
      ;;
    --dist)
      DIST_DIR="$2"
      APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
      APP_CONTENTS="$APP_BUNDLE/Contents"
      APP_MACOS="$APP_CONTENTS/MacOS"
      APP_RESOURCES="$APP_CONTENTS/Resources"
      APP_BINARY="$APP_MACOS/$APP_NAME"
      INFO_PLIST="$APP_CONTENTS/Info.plist"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

case "$MODE" in
  --help|-h)
    usage
    exit 0
    ;;
  release)
    CONFIGURATION="release"
    CREATE_ZIP=1
    NOTARIZE=1
    STAPLE=1
    ;;
  build|--build|run|debug|--debug|logs|--logs|telemetry|--telemetry|verify|--verify)
    CONFIGURATION="debug"
    ;;
  *)
    usage
    exit 2
    ;;
esac

build_binary() {
  if [[ "$CONFIGURATION" == "release" ]]; then
    swift build -c release
    swift build -c release --show-bin-path
  else
    swift build
    swift build --show-bin-path
  fi
}

write_info_plist() {
  cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
}

create_bundle() {
  if [[ "$MODE" != "build" && "$MODE" != "--build" && "$MODE" != "release" ]]; then
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  fi

  local build_dir
  build_dir="$(build_binary | tail -n 1)"

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES"
  cp "$build_dir/$APP_NAME" "$APP_BINARY"
  cp "$ROOT_DIR/Sources/Parallax/Resources/$ICON_FILE" "$APP_RESOURCES/$ICON_FILE"
  chmod +x "$APP_BINARY"
  write_info_plist
}

sign_bundle() {
  [[ -n "$SIGN_IDENTITY" ]] || return 0
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
  /usr/bin/codesign --verify --strict --deep --verbose=2 "$APP_BUNDLE"
}

notarize_bundle() {
  [[ "$NOTARIZE" -eq 1 ]] || return 0
  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "Error: --notarize requires --sign" >&2
    exit 1
  fi
  local zip_path="$DIST_DIR/$APP_NAME-notarize-tmp.zip"
  rm -f "$zip_path"
  /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$zip_path"
  echo "Submitting for notarization..."
  /usr/bin/xcrun notarytool submit "$zip_path" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$zip_path"
  echo "Notarization complete."
}

staple_bundle() {
  [[ "$STAPLE" -eq 1 ]] || return 0
  echo "Stapling notarization ticket..."
  /usr/bin/xcrun stapler staple "$APP_BUNDLE"
  /usr/bin/xcrun stapler validate "$APP_BUNDLE"
}

create_zip() {
  [[ "$CREATE_ZIP" -eq 1 ]] || return 0
  local zip_path="$DIST_DIR/$APP_NAME-$VERSION-$BUILD_NUMBER.zip"
  rm -f "$zip_path"
  /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$zip_path"
  echo "Created $zip_path"
}

create_dmg() {
  [[ "$CREATE_DMG" -eq 1 ]] || return 0
  local dmg_path="$DIST_DIR/$APP_NAME-$VERSION-$BUILD_NUMBER.dmg"
  rm -f "$dmg_path"
  /usr/bin/hdiutil create -volname "$APP_NAME" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$dmg_path"
  echo "Created $dmg_path"
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

create_bundle
sign_bundle
notarize_bundle
staple_bundle
create_zip
create_dmg

case "$MODE" in
  run)
    open_app
    ;;
  build|--build)
    echo "Built $APP_BUNDLE"
    ;;
  debug|--debug)
    lldb -- "$APP_BINARY"
    ;;
  logs|--logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  telemetry|--telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  verify|--verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    plutil -lint "$INFO_PLIST" >/dev/null
    [[ -f "$APP_RESOURCES/$ICON_FILE" ]]
    ;;
  release)
    echo "Built $APP_BUNDLE"
    ;;
esac
