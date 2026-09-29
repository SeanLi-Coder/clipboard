#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

BUILD_ARCH="$(/usr/bin/uname -m)"
if [[ "${1:-}" == "--arch" && $# -eq 2 ]]; then
  BUILD_ARCH="$2"
elif [[ $# -ne 0 ]]; then
  echo "Usage: scripts/build.sh [--arch arm64|x86_64]" >&2
  exit 2
fi
case "$BUILD_ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $BUILD_ARCH" >&2; exit 2 ;; esac

APP_VERSION="${CLIPSHELF_VERSION:-1.0.0}"
APP_BUILD="${CLIPSHELF_BUILD_NUMBER:-1}"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$APP_BUILD" =~ ^[0-9]+$ ]]; then
  echo "CLIPSHELF_VERSION must be x.y.z; CLIPSHELF_BUILD_NUMBER must be an integer." >&2
  exit 2
fi
if ! /usr/bin/xcrun --find swift >/dev/null 2>&1; then
  echo "Apple Command Line Tools are required. Run: xcode-select --install" >&2
  exit 1
fi

echo "Building ClipShelf $APP_VERSION for $BUILD_ARCH..."
/usr/bin/xcrun swift build --configuration release --arch "$BUILD_ARCH"
BINARY_DIR="$(/usr/bin/xcrun swift build --configuration release --arch "$BUILD_ARCH" --show-bin-path)"

if [[ ! -f Resources/AppIcon.icns || scripts/generate-icon.swift -nt Resources/AppIcon.icns ]]; then
  echo "Generating app icon..."
  /usr/bin/xcrun swift scripts/generate-icon.swift .build/ClipShelf.iconset
  /usr/bin/iconutil --convert icns .build/ClipShelf.iconset --output Resources/AppIcon.icns
fi

mkdir -p dist
STAGING_DIR="$(/usr/bin/mktemp -d "$PROJECT_DIR/dist/.clipshelf-build.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/ClipShelf.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BINARY_DIR/ClipShelf" "$STAGED_APP/Contents/MacOS/ClipShelf"
cp Resources/Info.plist "$STAGED_APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$STAGED_APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$STAGED_APP/Contents/Info.plist"
/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$STAGED_APP/Contents/MacOS/ClipShelf"
/usr/bin/codesign --force --sign - "$STAGED_APP"
/usr/bin/codesign --verify --strict --verbose=2 "$STAGED_APP"

if [[ -e dist/ClipShelf.app ]]; then
  mv dist/ClipShelf.app "$STAGING_DIR/Previous.app"
fi
mv "$STAGED_APP" dist/ClipShelf.app
echo "Built: $PROJECT_DIR/dist/ClipShelf.app"
