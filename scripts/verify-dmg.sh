#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: scripts/verify-dmg.sh path/to/ClipShelf.dmg" >&2
  exit 2
fi
IMAGE_PATH="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
VERIFY_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/clipshelf-dmg-check.XXXXXX")"
MOUNT_PATH="$VERIFY_DIR/mounted"
MOUNTED=0
cleanup() {
  if [[ "$MOUNTED" -eq 1 ]]; then
    if ! /usr/bin/hdiutil detach -quiet "$MOUNT_PATH"; then
      echo "Could not detach the image; temporary files were kept at $VERIFY_DIR." >&2
      return 1
    fi
  fi
  rm -rf "$VERIFY_DIR"
}
trap cleanup EXIT

/usr/bin/hdiutil verify -quiet "$IMAGE_PATH"
/usr/bin/hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MOUNT_PATH" -quiet "$IMAGE_PATH"
MOUNTED=1
APP_PATH="$MOUNT_PATH/ClipShelf.app"
[[ "$(/usr/bin/readlink "$MOUNT_PATH/Applications")" == "/Applications" ]]
[[ -f "$MOUNT_PATH/安装说明.txt" ]]
[[ "$(/usr/bin/lipo -archs "$APP_PATH/Contents/MacOS/ClipShelf")" == "arm64" ]]
/usr/bin/codesign --verify --strict "$APP_PATH"

# Validate the installed copy after the disk image has been ejected.
INSTALLED_APP="$VERIFY_DIR/Installed/ClipShelf.app"
mkdir -p "$VERIFY_DIR/Installed"
/usr/bin/ditto "$APP_PATH" "$INSTALLED_APP"
/usr/bin/hdiutil detach -quiet "$MOUNT_PATH"
MOUNTED=0
/usr/bin/codesign --verify --strict "$INSTALLED_APP"
if [[ "$(/usr/bin/uname -m)" == "arm64" ]]; then
  "$INSTALLED_APP/Contents/MacOS/ClipShelf" --smoke-test
else
  echo "Startup verification requires an Apple Silicon Mac." >&2
  exit 1
fi
echo "DMG verification passed: arm64-only app, installation link, signature, copy, and startup."
