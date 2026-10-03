#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/parallax-localization-check.XXXXXX")"
trap 'rm -rf "$PROBE_ROOT"' EXIT
PROBE_APP="$PROBE_ROOT/LocalizationProbe.app"
mkdir -p "$PROBE_APP/Contents/MacOS" "$PROBE_APP/Contents/Resources/es.lproj"
# The CLI host must itself admit Spanish for Foundation to select it in another bundle.
plutil -create xml1 "$PROBE_APP/Contents/Info.plist"
plutil -insert CFBundleExecutable -string Probe "$PROBE_APP/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string test.parallax.localization "$PROBE_APP/Contents/Info.plist"
plutil -insert CFBundleDevelopmentRegion -string es "$PROBE_APP/Contents/Info.plist"
plutil -insert CFBundleLocalizations -json '["en","es"]' "$PROBE_APP/Contents/Info.plist"
plutil -insert CFBundleAllowMixedLocalizations -bool YES "$PROBE_APP/Contents/Info.plist"
swiftc "$SCRIPT_DIR/PackagedLocalizationCheck.swift" -o "$PROBE_APP/Contents/MacOS/Probe"
"$PROBE_APP/Contents/MacOS/Probe" "$1" -AppleLanguages '(es)'
