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
  local maximum_entries=10000
  local maximum_inventory_bytes=2097152
  local maximum_entry_uncompressed_bytes=67108864
  local maximum_total_uncompressed_bytes=536870912
  local inventory_metrics
  if ! inventory_metrics="$(
    /usr/bin/zipinfo -1 "$zip" \
      | LC_ALL=C /usr/bin/awk \
        -v maximum_entries="$maximum_entries" \
        -v maximum_bytes="$maximum_inventory_bytes" '
          {
            entries += 1
            bytes += length($0) + 1
            if (entries > maximum_entries || bytes > maximum_bytes) {
              exit 42
            }
          }
          END {
            if (entries > maximum_entries || bytes > maximum_bytes) {
              exit 42
            }
            printf "%d %d\n", entries, bytes
          }
        '
  )"; then
    die "ZIP inventory exceeds verification limits or cannot be inspected"
  fi
  local inventory_entry_count
  read -r inventory_entry_count _ <<<"$inventory_metrics"
  [[ "$inventory_entry_count" -gt 0 ]] || die "ZIP is empty"

  if ! /usr/bin/zipinfo -l "$zip" \
      | LC_ALL=C /usr/bin/awk \
        -v expected_entries="$inventory_entry_count" \
        -v maximum_entry_bytes="$maximum_entry_uncompressed_bytes" \
        -v maximum_total_bytes="$maximum_total_uncompressed_bytes" '
          $1 ~ /^[-dlcbps]/ && $4 ~ /^[0-9]+$/ {
            entries += 1
            size = $4 + 0
            total += size
            if (size > maximum_entry_bytes || total > maximum_total_bytes) {
              exceeded = 1
              exit 42
            }
          }
          END {
            if (exceeded || entries != expected_entries) {
              exit 42
            }
          }
        '; then
    die "ZIP declared uncompressed size exceeds verification limits or cannot be inspected"
  fi

  local entries
  entries="$(/usr/bin/zipinfo -1 "$zip")" \
    || die "cannot inspect ZIP inventory"
  [[ -n "$entries" ]] || die "ZIP is empty"

  require_tool /usr/bin/perl
  local canonical_entries
  if ! canonical_entries="$(
    /usr/bin/printf '%s\n' "$entries" \
      | /usr/bin/perl \
        -MUnicode::Normalize=NFD \
        -Mfeature=fc \
        -CSDA \
        -ne 'chomp; s{/\z}{}; print fc(NFD($_)), "\n"'
  )"; then
    die "ZIP contains a path that cannot be normalized"
  fi

  local duplicates
  duplicates="$(
    /usr/bin/printf '%s\n' "$canonical_entries" \
      | LC_ALL=C /usr/bin/sort \
      | /usr/bin/uniq -d
  )"
  [[ -z "$duplicates" ]] \
    || die "ZIP contains duplicate or case/Unicode-equivalent entries"

  local canonical_app_root canonical_metadata_root
  canonical_app_root="$(
    /usr/bin/printf '%s\n' "$APP_NAME.app" \
      | /usr/bin/perl \
        -MUnicode::Normalize=NFD \
        -Mfeature=fc \
        -CSDA \
        -ne 'print fc(NFD($_))'
  )"
  canonical_metadata_root="__macosx"

  local entry normalized_entry top_level canonical_top_level
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    [[ "$entry" != /* ]] || die "ZIP contains an absolute path"
    normalized_entry="${entry%/}"
    [[ -n "$normalized_entry" ]] || die "ZIP contains an empty path"
    case "/$normalized_entry/" in
      */../*) die "ZIP contains a traversing path" ;;
      */./*|*//*) die "ZIP contains a non-canonical path" ;;
    esac
    case "$normalized_entry" in
      "$APP_NAME.app"|"$APP_NAME.app/"*) ;;
      "__MACOSX"|"__MACOSX/$APP_NAME.app"|"__MACOSX/$APP_NAME.app/"*) ;;
      *)
        top_level="${normalized_entry%%/*}"
        canonical_top_level="$(
          /usr/bin/printf '%s\n' "$top_level" \
            | /usr/bin/perl \
              -MUnicode::Normalize=NFD \
              -Mfeature=fc \
              -CSDA \
              -ne 'print fc(NFD($_))'
        )"
        if [[ "$canonical_top_level" == "$canonical_app_root" \
            || "$canonical_top_level" == "$canonical_metadata_root" ]]; then
          die "ZIP contains a case/Unicode-equivalent top-level collision"
        fi
        die "ZIP contains unexpected top-level payload"
        ;;
    esac
  done <<<"$entries"

  if /usr/bin/zipinfo -l "$zip" \
      | /usr/bin/awk -v root="$APP_NAME.app" '
          $1 ~ /^l/ && ($NF == root || $NF == root "/") { found = 1 }
          END { exit(found ? 0 : 1) }
        '; then
    die "ZIP application payload cannot be a symbolic link"
  fi
}

verify_dmg_top_level_inventory() {
  local mount_point="$1"
  local inventory="$2"
  local maximum_entries=64
  local maximum_inventory_bytes=65536
  require_tool /usr/bin/perl
  if ! /usr/bin/find "$mount_point" -mindepth 1 -maxdepth 1 -print0 \
      | MAXIMUM_DMG_INVENTORY_ENTRIES="$maximum_entries" \
        MAXIMUM_DMG_INVENTORY_BYTES="$maximum_inventory_bytes" \
        /usr/bin/perl -0 -ne '
          chomp;
          $entries += 1;
          $bytes += length($_) + 1;
          exit 42
            if $entries > $ENV{MAXIMUM_DMG_INVENTORY_ENTRIES}
              || $bytes > $ENV{MAXIMUM_DMG_INVENTORY_BYTES};
          print $_, "\0";
        ' >"$inventory"; then
    die "DMG top-level inventory exceeds verification limits or cannot be inspected"
  fi
  local found_app=0
  local found_applications=0
  local entry
  while IFS= read -r -d '' entry; do
    case "$entry" in
      "$mount_point/$APP_NAME.app")
        [[ -d "$entry" && ! -L "$entry" ]] \
          || die "DMG application payload is not a directory"
        found_app=1
        ;;
      "$mount_point/Applications")
        [[ -L "$entry" ]] || die "DMG Applications payload is not an alias"
        found_applications=1
        ;;
      *)
        die "DMG contains unexpected top-level payload"
        ;;
    esac
  done <"$inventory"

  [[ "$found_app" -eq 1 ]] || die "DMG is missing $APP_NAME.app"
  [[ "$found_applications" -eq 1 ]] \
    || die "DMG is missing the Applications alias"
}

verify_zip() (
  local zip="$1"
  local expectation="$2"
  local architecture="$3"
  local expected_bundle_id="$4"
  local expected_team_id="$5"
  local require_notarized="$6"
  require_tool /usr/bin/zipinfo
  safe_zip_entries "$zip"

  local temporary=""
  cleanup_verification_zip() {
    if [[ -n "$temporary" && -d "$temporary" ]]; then
      case "$(/usr/bin/basename "$temporary")" in
        parallax-verify-zip.*) /bin/rm -rf "$temporary" ;;
      esac
    fi
  }
  trap cleanup_verification_zip EXIT

  temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-verify-zip.XXXXXX")"
  /usr/bin/ditto -x -k "$zip" "$temporary"
  local app="$temporary/$APP_NAME.app"
  if [[ ! -d "$app" ]]; then
    die "ZIP does not contain $APP_NAME.app at its root"
  fi
  if [[ "$(/usr/bin/stat -f %HT "$app")" != "Directory" || -L "$app" ]]; then
    die "ZIP application payload is not a physical directory"
  fi
  local canonical_temporary canonical_app
  canonical_temporary="$(cd "$temporary" && pwd -P)"
  canonical_app="$(cd "$app" && pwd -P)"
  if [[ "$canonical_app" != "$canonical_temporary/$APP_NAME.app" ]]; then
    die "ZIP application payload resolves outside the extraction root"
  fi
  verify_app \
    "$app" \
    "$expectation" \
    "$architecture" \
    "$expected_bundle_id" \
    "$expected_team_id" \
    "$require_notarized"
)

verify_dmg() (
  local dmg="$1"
  local expectation="$2"
  local architecture="$3"
  local expected_bundle_id="$4"
  local expected_team_id="$5"
  local require_notarized="$6"
  require_tool /usr/bin/hdiutil

  local temporary attached=0
  temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parallax-verify-dmg.XXXXXX")"
  local verification_mount="$temporary/mount"
  /bin/mkdir "$verification_mount"

  detach_verification_dmg() {
    [[ "$attached" -eq 1 ]] || return 0
    if /usr/bin/hdiutil detach "$verification_mount" >/dev/null 2>&1 \
        || /usr/bin/hdiutil detach "$verification_mount" -force \
          >/dev/null 2>&1; then
      attached=0
      return 0
    fi
    return 1
  }
  cleanup_verification_dmg() {
    detach_verification_dmg || true
    if [[ "$attached" -eq 0 && -d "$temporary" ]]; then
      /bin/rm -rf "$temporary"
    fi
  }
  trap cleanup_verification_dmg EXIT

  attached=1
  /usr/bin/hdiutil attach \
    -readonly \
    -nobrowse \
    -mountpoint "$verification_mount" \
    "$dmg" >/dev/null

  verify_dmg_top_level_inventory \
    "$verification_mount" \
    "$temporary/top-level-inventory"
  [[ -L "$verification_mount/Applications" ]] \
    || die "DMG is missing the Applications alias"
  [[ "$(/usr/bin/readlink "$verification_mount/Applications")" == "/Applications" ]] \
    || die "DMG Applications alias has an unexpected target"
  verify_app \
    "$verification_mount/$APP_NAME.app" \
    "$expectation" \
    "$architecture" \
    "$expected_bundle_id" \
    "$expected_team_id" \
    "$require_notarized"

  detach_verification_dmg || die "could not detach DMG verification mount"

  if [[ "$expectation" == "signed" && "$require_notarized" -eq 1 ]]; then
    /usr/bin/codesign --verify --verbose=2 "$dmg" \
      || die "DMG signature verification failed"
    /usr/bin/xcrun stapler validate "$dmg" \
      || die "DMG notarization ticket is missing"
  fi
)

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
