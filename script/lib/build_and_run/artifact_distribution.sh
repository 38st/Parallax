# Sourced by script/build_and_run.sh. Notarization, archive creation, and atomic publication.

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

launch_services_register() {
  echo "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
}

unregister_local_app() {
  local app="$1"
  local register
  register="$(launch_services_register)"
  [[ -x "$register" ]] || return 0
  "$register" -u "$app" >/dev/null 2>&1 || true
}

register_local_app() {
  local app="$1"
  local register
  register="$(launch_services_register)"
  [[ -x "$register" ]] || return 0
  "$register" -f "$app" >/dev/null
}

prepare_install_directory() {
  [[ ! -L "$INSTALL_DIR" ]] \
    || die "installation directory cannot be a symbolic link"
  [[ -d "$INSTALL_DIR" ]] \
    || die "installation directory does not exist: $INSTALL_DIR"
  INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd -P)"
  [[ -w "$INSTALL_DIR" ]] \
    || die "installation directory is not writable: $INSTALL_DIR"
}

stop_running_local_app() {
  if /usr/bin/pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    /usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    local attempt
    for attempt in 1 2 3 4 5; do
      /usr/bin/pgrep -x "$APP_NAME" >/dev/null 2>&1 || return 0
      /bin/sleep 1
    done
    die "$APP_NAME is still running; quit it and try again"
  fi
}

remove_legacy_local_app() {
  local app="$1"
  [[ "$app" != "$INSTALL_DIR/$APP_NAME.app" ]] \
    || die "refusing to remove the canonical installed application"
  [[ -e "$app" ]] || return 0
  [[ ! -L "$app" && -d "$app" ]] \
    || die "legacy local application is not a regular app directory: $app"
  unregister_local_app "$app"
  /bin/rm -rf "$app"
}
