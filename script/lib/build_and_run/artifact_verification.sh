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

# The bundle must be a closed, canonical tree: no links or special files, no
# hidden Apple or editor residue, one deterministic mode per kind, and, when
# closed membership is required, no payload outside the published layout. A
# stapled release bundle carries an extra notarization record, so membership
# closure is asserted where the bundle is produced and relaxed for a signed
# expectation.
verify_application_inventory() {
  local app="$1"
  local closed="$2"
  local maximum_entries=4096
  local maximum_path_bytes=1024
  [[ ! -L "$app" ]] || die "application bundle is a symbolic link"
  [[ "$(/usr/bin/stat -f %Lp "$app")" == "755" ]] \
    || die "application bundle permissions are not canonical"
  local entries=0
  local entry relative base mode byte_count
  local saw_contents=0
  while IFS= read -r -d '' entry; do
    entries=$((entries + 1))
    [[ "$entries" -le "$maximum_entries" ]] \
      || die "application bundle exceeds $maximum_entries inventory entries"
    relative="${entry#"$app/"}"
    byte_count="$(
      LC_ALL=C /usr/bin/printf '%s' "$relative" \
        | /usr/bin/wc -c \
        | /usr/bin/tr -d ' '
    )"
    [[ "$byte_count" -le "$maximum_path_bytes" ]] \
      || die "application bundle path exceeds the $maximum_path_bytes-byte limit"
    case "$relative" in
      *[[:cntrl:]]*) die "application bundle path contains a control character" ;;
    esac
    base="${relative##*/}"
    case "$base" in
      .*) die "application bundle carries hidden residue: $relative" ;;
    esac
    [[ ! -L "$entry" ]] \
      || die "application bundle contains a symbolic link: $relative"
    mode="$(/usr/bin/stat -f %Lp "$entry")" \
      || die "cannot inspect application bundle permissions: $relative"
    if [[ -d "$entry" ]]; then
      [[ "$mode" == "755" ]] \
        || die "application directory permissions are not canonical: $relative"
    elif [[ -f "$entry" ]]; then
      [[ "$(/usr/bin/stat -f %l "$entry")" -eq 1 ]] \
        || die "application file has more than one hard link: $relative"
      if [[ "$relative" == "Contents/MacOS/$APP_NAME" ]]; then
        [[ "$mode" == "755" ]] \
          || die "application executable permissions are not canonical"
      else
        [[ "$mode" == "644" ]] \
          || die "application file permissions are not canonical: $relative"
      fi
    else
      die "application bundle contains a special file: $relative"
    fi
    case "$relative" in
      Contents)
        saw_contents=1
        ;;
      Contents/*) ;;
      *)
        die "application bundle contains unexpected top-level payload: $relative"
        ;;
    esac
    if [[ "$closed" -eq 1 ]]; then
      case "$relative" in
        Contents \
          |Contents/Info.plist \
          |Contents/MacOS \
          |Contents/MacOS/"$APP_NAME" \
          |Contents/Resources \
          |Contents/Resources/* \
          |Contents/_CodeSignature \
          |Contents/_CodeSignature/*) ;;
        Contents/MacOS/*)
          die "application bundle contains an unexpected executable payload: $relative"
          ;;
        *)
          die "application bundle contains unexpected payload: $relative"
          ;;
      esac
    fi
  done < <(/usr/bin/find -x "$app" -mindepth 1 -print0)
  [[ "$entries" -gt 0 ]] || die "application bundle is empty"
  [[ "$saw_contents" -eq 1 ]] || die "application bundle has no Contents directory"
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
  local closed_inventory=1
  [[ "$expectation" != "signed" ]] || closed_inventory=0
  verify_application_inventory "$app" "$closed_inventory"
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

# Bounded, fail-closed input contract shared by archive verification. A
# verifiable archive is a singly named regular file of bounded size whose bytes
# are proven not to change between inspection and use.
require_bounded_archive_input() {
  local archive="$1"
  local kind="$2"
  local maximum_bytes=536870912
  case "$archive" in
    *[[:cntrl:]]*) die "$kind path contains a control character" ;;
  esac
  [[ -f "$archive" && ! -L "$archive" ]] \
    || die "$kind must be a regular non-symbolic-link file"
  [[ "$(/usr/bin/stat -f %l "$archive")" -eq 1 ]] \
    || die "$kind must have exactly one hard link"
  local size
  size="$(/usr/bin/stat -f %z "$archive")" \
    || die "cannot inspect the $kind size"
  [[ "$size" -gt 0 ]] || die "$kind is empty"
  [[ "$size" -le "$maximum_bytes" ]] \
    || die "$kind exceeds the 512 MiB verification limit"
}

canonical_archive_path() {
  local requested="$1"
  local parent
  parent="$(cd "$(/usr/bin/dirname "$requested")" 2>/dev/null && pwd -P)" \
    || die "cannot resolve the directory containing $requested"
  [[ "$parent" != "/" ]] || parent=""
  /usr/bin/printf '%s/%s\n' "$parent" "$(/usr/bin/basename "$requested")"
}

archive_identity() {
  local archive="$1"
  local device inode size digest
  device="$(/usr/bin/stat -f %d "$archive")" || return 1
  inode="$(/usr/bin/stat -f %i "$archive")" || return 1
  size="$(/usr/bin/stat -f %z "$archive")" || return 1
  digest="$(sha256 "$archive")" || return 1
  /usr/bin/printf '%s:%s:%s:%s\n' "$device" "$inode" "$size" "$digest"
}

require_unchanged_archive() {
  local archive="$1"
  local expected="$2"
  local kind="$3"
  local observed
  observed="$(archive_identity "$archive")" \
    || die "$kind could not be re-inspected before use"
  [[ "$observed" == "$expected" ]] \
    || die "$kind changed during verification"
}

zip_entry_kinds() {
  local zip="$1"
  /usr/bin/zipinfo -l "$zip" \
    | LC_ALL=C /usr/bin/awk '
        $1 ~ /^[-dlcbps]/ && $4 ~ /^[0-9]+$/ { print substr($1, 1, 1) }
      '
}

verify_zip_entry_names() {
  local entries="$1"
  local maximum_path_bytes=512
  /usr/bin/printf '%s\n' "$entries" \
    | /usr/bin/iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 \
    || die "ZIP entry names are not valid UTF-8"
  local entry byte_count
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || die "ZIP contains an empty path"
    case "$entry" in
      *[[:cntrl:]]*) die "ZIP entry name contains a control character" ;;
      *'^'*) die "ZIP entry name contains an escaped control character" ;;
      *'?'*) die "ZIP entry name has an ambiguous listed representation" ;;
      *'\'*) die "ZIP entry name contains an ambiguous path separator" ;;
    esac
    byte_count="$(
      LC_ALL=C /usr/bin/printf '%s' "$entry" \
        | /usr/bin/wc -c \
        | /usr/bin/tr -d ' '
    )"
    [[ "$byte_count" -le "$maximum_path_bytes" ]] \
      || die "ZIP entry path exceeds the $maximum_path_bytes-byte limit"
  done <<<"$entries"
}

# Every entry must be a plain directory or file whose declared type agrees with
# its path, and every Apple metadata record must describe a payload entry that
# the same archive actually carries.
verify_zip_entry_kinds() {
  local entries="$1"
  local kinds="$2"
  local failure
  if ! failure="$(
    LC_ALL=C /usr/bin/awk \
      -v root="$APP_NAME.app" \
      -v metadata_root="__MACOSX" '
        NR == FNR {
          kind[FNR] = $0
          declared = FNR
          next
        }
        {
          name[FNR] = $0
          listed = FNR
        }
        END {
          if (listed == 0 || declared != listed) {
            print "ZIP name and metadata listings disagree"
            exit 1
          }
          for (n = 1; n <= listed; n++) {
            entry = name[n]
            present[entry] = kind[n]
            if (kind[n] == "d") {
              if (entry !~ /\/$/) {
                print "ZIP directory entry lacks a trailing separator: " entry
                exit 1
              }
            } else if (kind[n] == "-") {
              if (entry ~ /\/$/) {
                print "ZIP file entry has a directory path: " entry
                exit 1
              }
            } else {
              print "ZIP contains a link or special entry: " entry
              exit 1
            }
          }
          if (!((root "/") in present)) {
            print "ZIP has no explicit " root " directory entry"
            exit 1
          }
          for (n = 1; n <= listed; n++) {
            entry = name[n]
            if (entry == metadata_root "/") {
              continue
            }
            if (index(entry, metadata_root "/") != 1) {
              continue
            }
            relative = substr(entry, length(metadata_root) + 2)
            if (kind[n] == "d") {
              if (!(relative in present) || present[relative] != "d") {
                print "ZIP metadata directory has no payload target: " entry
                exit 1
              }
              continue
            }
            separator = 0
            if (match(relative, /^.*\//)) {
              separator = RLENGTH
            }
            parent = substr(relative, 1, separator)
            base = substr(relative, separator + 1)
            if (substr(base, 1, 2) != "._" || base == "._") {
              print "ZIP carries non-metadata payload under " metadata_root \
                ": " entry
              exit 1
            }
            target = parent substr(base, 3)
            if (!(target in present) && !((target "/") in present)) {
              print "ZIP metadata record has no payload target: " entry
              exit 1
            }
          }
        }
      ' \
      <(/usr/bin/printf '%s\n' "$kinds") \
      <(/usr/bin/printf '%s\n' "$entries")
  )"; then
    die "${failure:-ZIP structure could not be inspected}"
  fi
}

# Reject the archive before extraction if any stored payload fails its CRC, if a
# local header disagrees with the central directory, or if an entry is
# encrypted. ditto reports none of those conditions through its exit status.
verify_zip_payload_integrity() {
  local zip="$1"
  require_tool /usr/bin/unzip
  /usr/bin/unzip -qq -t "$zip" </dev/null >/dev/null 2>&1 \
    || die "ZIP payload integrity check failed (checksum, header, or encryption)"
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

  local maximum_compression_ratio=1000
  if ! /usr/bin/zipinfo -l "$zip" \
      | LC_ALL=C /usr/bin/awk \
        -v maximum_ratio="$maximum_compression_ratio" '
          $1 ~ /^[-dlcbps]/ && $4 ~ /^[0-9]+$/ && $6 ~ /^[0-9]+$/ {
            expanded = $4 + 0
            compressed = $6 + 0
            if (expanded > 0 \
                && (compressed <= 0 \
                  || expanded > compressed * maximum_ratio)) {
              exit 42
            }
          }
        '; then
    die "ZIP entry exceeds the declared compression-ratio limit"
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

  verify_zip_entry_names "$entries"
  local entry_kinds
  entry_kinds="$(zip_entry_kinds "$zip")" \
    || die "cannot inspect ZIP entry metadata"
  verify_zip_entry_kinds "$entries" "$entry_kinds"
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
  require_tool /usr/bin/iconv
  zip="$(canonical_archive_path "$zip")"
  require_bounded_archive_input "$zip" "ZIP"
  local identity
  identity="$(archive_identity "$zip")" \
    || die "cannot inspect the ZIP identity"
  safe_zip_entries "$zip"
  verify_zip_payload_integrity "$zip"

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
  require_unchanged_archive "$zip" "$identity" "ZIP"
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

# hdiutil attach hands the image to the kernel's disk-image and filesystem
# parsers. Inspect the container first and accept only the exact structure this
# project publishes: a single-segment, checksummed, unencrypted, zlib-compressed
# UDIF image with a GUID partition scheme, no license agreement, and a bounded
# declared size. Encrypted or otherwise unreadable containers fail closed here
# because hdiutil cannot describe them without a credential.
dmg_image_property() {
  local key="$1"
  local evidence="$2"
  /usr/bin/plutil -extract "$key" raw -o - "$evidence" 2>/dev/null
}

require_dmg_image_property() {
  local key="$1"
  local expected="$2"
  local evidence="$3"
  local observed
  observed="$(dmg_image_property "$key" "$evidence")" \
    || die "DMG image property $key is unavailable"
  [[ "$observed" == "$expected" ]] \
    || die "DMG image property $key is $observed, expected $expected"
}

verify_dmg_image_structure() {
  local dmg="$1"
  local evidence="$2"
  local maximum_bytes=536870912
  /usr/bin/hdiutil imageinfo -plist -stdinpass "$dmg" \
    </dev/null >"$evidence" 2>/dev/null \
    || die "DMG image inspection failed (unreadable, encrypted, or unsupported)"
  /usr/bin/plutil -lint "$evidence" >/dev/null 2>&1 \
    || die "DMG image inspection produced malformed evidence"
  require_dmg_image_property "Class Name" "CUDIFDiskImage" "$evidence"
  require_dmg_image_property "Format" "UDZO" "$evidence"
  require_dmg_image_property "Checksum Type" "CRC32" "$evidence"
  require_dmg_image_property "Properties.Encrypted" "false" "$evidence"
  require_dmg_image_property "Properties.Checksummed" "true" "$evidence"
  require_dmg_image_property "Properties.Compressed" "true" "$evidence"
  require_dmg_image_property \
    "Properties.Software License Agreement" "false" "$evidence"
  require_dmg_image_property "partitions.partition-scheme" "GUID" "$evidence"
  require_dmg_image_property "Segments.0" "$dmg" "$evidence"
  if dmg_image_property "Segments.1" "$evidence" >/dev/null; then
    die "DMG is segmented across more than one file"
  fi
  local declared_bytes
  declared_bytes="$(dmg_image_property "Size Information.Total Bytes" "$evidence")" \
    || die "DMG declared size is unavailable"
  [[ "$declared_bytes" =~ ^[0-9]+$ ]] \
    || die "DMG declared size is not an integer"
  [[ "$declared_bytes" -gt 0 && "$declared_bytes" -le "$maximum_bytes" ]] \
    || die "DMG declared size exceeds the 512 MiB verification limit"
  /usr/bin/hdiutil verify -quiet -stdinpass "$dmg" \
    </dev/null >/dev/null 2>&1 \
    || die "DMG checksum verification failed"
}

verify_dmg() (
  local dmg="$1"
  local expectation="$2"
  local architecture="$3"
  local expected_bundle_id="$4"
  local expected_team_id="$5"
  local require_notarized="$6"
  require_tool /usr/bin/hdiutil
  dmg="$(canonical_archive_path "$dmg")"
  require_bounded_archive_input "$dmg" "DMG"
  local identity
  identity="$(archive_identity "$dmg")" \
    || die "cannot inspect the DMG identity"

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

  verify_dmg_image_structure "$dmg" "$temporary/image-information.plist"
  require_unchanged_archive "$dmg" "$identity" "DMG"
  attached=1
  /usr/bin/hdiutil attach \
    -readonly \
    -verify \
    -noignorebadchecksums \
    -noautoopen \
    -nobrowse \
    -stdinpass \
    -mountpoint "$verification_mount" \
    "$dmg" </dev/null >/dev/null

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
  require_unchanged_archive "$dmg" "$identity" "DMG"

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
