# Sourced by script/build_and_run.sh. Input validation, tool discovery, and release preflight.

validate_inputs() {
  case "$DIST_DIR" in
    *$'\n'*) die "distribution directory cannot contain a newline" ;;
  esac
  case "$INSTALL_DIR" in
    *$'\n'*) die "installation directory cannot contain a newline" ;;
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
