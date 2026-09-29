#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

BUILD_ARCH="arm64"
if [[ "${1:-}" == "--arch" && $# -eq 2 ]]; then
  BUILD_ARCH="$2"
elif [[ $# -ne 0 ]]; then
  echo "Usage: scripts/package.sh [--arch arm64]" >&2
  exit 2
fi
"$PROJECT_DIR/scripts/build.sh" --arch "$BUILD_ARCH"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/ClipShelf.app/Contents/Info.plist)"
ARCHIVE_NAME="ClipShelf-${APP_VERSION}-macOS-${BUILD_ARCH}.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent dist/ClipShelf.app "dist/$ARCHIVE_NAME"
(
  cd dist
  /usr/bin/shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)
echo "Packaged: $PROJECT_DIR/dist/$ARCHIVE_NAME"
echo "Checksum: $PROJECT_DIR/dist/$ARCHIVE_NAME.sha256"
"$PROJECT_DIR/scripts/create-dmg.sh" "$PROJECT_DIR/dist/ClipShelf.app"
