# Sourced by script/build_and_run.sh. Application, archive, signature, and Gatekeeper verification.

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
