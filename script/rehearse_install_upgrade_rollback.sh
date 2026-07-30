#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Parallax"
PREVIOUS_ARTIFACT=""
CANDIDATE_ARTIFACT=""
WORK_PARENT="${TMPDIR:-/tmp}"
KEEP_WORK_DIR=0
WORK_DIR=""

die() {
  echo "Error: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<USAGE
usage:
  $0 --previous PATH --candidate PATH [--work-parent DIR] [--keep]

Rehearses, in an isolated temporary Applications directory:
  1. clean candidate installation and first launch smoke test
  2. previous-version installation
  3. candidate upgrade with rollback backup
  4. rollback to the byte-identical previous app

PATH may be a Parallax.app directory or a ZIP containing Parallax.app.
No files in /Applications or the input artifacts are changed.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --previous)
      [[ $# -ge 2 && -n "$2" ]] || die "--previous requires a path"
      PREVIOUS_ARTIFACT="$2"
      shift 2
      ;;
    --candidate)
      [[ $# -ge 2 && -n "$2" ]] || die "--candidate requires a path"
      CANDIDATE_ARTIFACT="$2"
      shift 2
      ;;
    --work-parent)
      [[ $# -ge 2 && -n "$2" ]] || die "--work-parent requires a directory"
      WORK_PARENT="$2"
      shift 2
      ;;
    --keep)
      KEEP_WORK_DIR=1
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

[[ -n "$PREVIOUS_ARTIFACT" ]] || die "--previous is required"
[[ -n "$CANDIDATE_ARTIFACT" ]] || die "--candidate is required"
[[ -e "$PREVIOUS_ARTIFACT" ]] || die "previous artifact does not exist"
[[ -e "$CANDIDATE_ARTIFACT" ]] || die "candidate artifact does not exist"
[[ -d "$WORK_PARENT" ]] || die "work parent does not exist: $WORK_PARENT"

WORK_DIR="$(/usr/bin/mktemp -d "$WORK_PARENT/parallax-install-rehearsal.XXXXXX")"
cleanup() {
  if [[ "$KEEP_WORK_DIR" -eq 1 ]]; then
    echo "Preserved rehearsal workspace: $WORK_DIR"
  else
    /bin/rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT INT TERM HUP

materialize_app() {
  local artifact="$1"
  local destination="$2"
  case "$artifact" in
    *.app)
      [[ -d "$artifact" ]] || die "app artifact is not a directory: $artifact"
      /usr/bin/ditto "$artifact" "$destination"
      ;;
    *.zip)
      local extraction="$WORK_DIR/extract-$RANDOM"
      /bin/mkdir "$extraction"
      /usr/bin/ditto -x -k "$artifact" "$extraction"
      [[ -d "$extraction/$APP_NAME.app" ]] \
        || die "ZIP does not contain $APP_NAME.app at its root: $artifact"
      /usr/bin/ditto "$extraction/$APP_NAME.app" "$destination"
      ;;
    *)
      die "unsupported artifact (expected .app or .zip): $artifact"
      ;;
  esac
}

app_build() {
  /usr/bin/plutil -extract CFBundleVersion raw -o - "$1/Contents/Info.plist"
}

app_version() {
  /usr/bin/plutil -extract CFBundleShortVersionString raw -o - \
    "$1/Contents/Info.plist"
}

app_tree_hash() {
  (
    cd "$1"
    LC_ALL=C /usr/bin/find . -type f -print \
      | LC_ALL=C /usr/bin/sort \
      | while IFS= read -r path; do
          /usr/bin/shasum -a 256 "$path"
        done \
      | /usr/bin/shasum -a 256 \
      | /usr/bin/awk '{print $1}'
  )
}

smoke_test() {
  local app="$1"
  local home="$2"
  /usr/bin/codesign --verify --deep --strict "$app"
  /bin/mkdir -p "$home"
  local output
  output="$(
    HOME="$home" \
      CFFIXED_USER_HOME="$home" \
      "$app/Contents/MacOS/$APP_NAME" --resource-smoke-test
  )"
  [[ "$output" == *"Parallax packaged resources: OK"* ]] \
    || die "runtime resource smoke test failed for $app"
}

PREVIOUS_APP="$WORK_DIR/previous/$APP_NAME.app"
CANDIDATE_APP="$WORK_DIR/candidate/$APP_NAME.app"
/bin/mkdir -p "$WORK_DIR/previous" "$WORK_DIR/candidate"
materialize_app "$PREVIOUS_ARTIFACT" "$PREVIOUS_APP"
materialize_app "$CANDIDATE_ARTIFACT" "$CANDIDATE_APP"

PREVIOUS_VERSION="$(app_version "$PREVIOUS_APP")"
PREVIOUS_BUILD="$(app_build "$PREVIOUS_APP")"
CANDIDATE_VERSION="$(app_version "$CANDIDATE_APP")"
CANDIDATE_BUILD="$(app_build "$CANDIDATE_APP")"
[[ "$PREVIOUS_VERSION/$PREVIOUS_BUILD" != "$CANDIDATE_VERSION/$CANDIDATE_BUILD" ]] \
  || die "previous and candidate versions are identical"

APPLICATIONS_DIR="$WORK_DIR/Applications"
INSTALLED_APP="$APPLICATIONS_DIR/$APP_NAME.app"
ROLLBACK_APP="$APPLICATIONS_DIR/.rollback-$APP_NAME.app"
/bin/mkdir "$APPLICATIONS_DIR"

# Clean installation.
/usr/bin/ditto "$CANDIDATE_APP" "$INSTALLED_APP"
smoke_test "$INSTALLED_APP" "$WORK_DIR/home-clean"
[[ "$(app_build "$INSTALLED_APP")" == "$CANDIDATE_BUILD" ]] \
  || die "clean installation has the wrong build"
/bin/mv "$INSTALLED_APP" "$WORK_DIR/clean-install-verified.app"

# Install the previous release, then atomically replace it with the candidate.
/usr/bin/ditto "$PREVIOUS_APP" "$INSTALLED_APP"
smoke_test "$INSTALLED_APP" "$WORK_DIR/home-previous"
PREVIOUS_TREE_HASH="$(app_tree_hash "$INSTALLED_APP")"
/bin/mv "$INSTALLED_APP" "$ROLLBACK_APP"
/usr/bin/ditto "$CANDIDATE_APP" "$APPLICATIONS_DIR/.candidate-$APP_NAME.app"
/bin/mv "$APPLICATIONS_DIR/.candidate-$APP_NAME.app" "$INSTALLED_APP"
smoke_test "$INSTALLED_APP" "$WORK_DIR/home-upgrade"
[[ "$(app_build "$INSTALLED_APP")" == "$CANDIDATE_BUILD" ]] \
  || die "upgrade has the wrong build"

# Roll back without modifying the preserved prior app.
/bin/mv "$INSTALLED_APP" "$APPLICATIONS_DIR/.failed-$APP_NAME.app"
/bin/mv "$ROLLBACK_APP" "$INSTALLED_APP"
smoke_test "$INSTALLED_APP" "$WORK_DIR/home-rollback"
[[ "$(app_build "$INSTALLED_APP")" == "$PREVIOUS_BUILD" ]] \
  || die "rollback has the wrong build"
[[ "$(app_tree_hash "$INSTALLED_APP")" == "$PREVIOUS_TREE_HASH" ]] \
  || die "rollback did not restore the byte-identical previous app"

echo "PASS clean install: $CANDIDATE_VERSION ($CANDIDATE_BUILD)"
echo "PASS upgrade: $PREVIOUS_VERSION ($PREVIOUS_BUILD) -> $CANDIDATE_VERSION ($CANDIDATE_BUILD)"
echo "PASS rollback: restored $PREVIOUS_VERSION ($PREVIOUS_BUILD)"
