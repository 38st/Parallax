# Sourced by script/build_and_run.sh. Build staging, application assembly, signing, and cleanup.

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
  if ! swift build \
      -c "$configuration" \
      --triple "$triple" \
      --scratch-path "$scratch" >&2; then
    die "SwiftPM compilation failed for $triple ($configuration)"
  fi
  swift build \
      -c "$configuration" \
      --triple "$triple" \
      --scratch-path "$scratch" \
      --show-bin-path \
    || die "SwiftPM could not report the output path for $triple ($configuration)"
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
