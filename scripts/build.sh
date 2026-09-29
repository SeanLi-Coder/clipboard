#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

BUILD_ARCH="arm64"
if [[ "${1:-}" == "--arch" && $# -eq 2 ]]; then
  BUILD_ARCH="$2"
elif [[ $# -ne 0 ]]; then
  echo "Usage: scripts/build.sh [--arch arm64]" >&2
  exit 2
fi
if [[ "$BUILD_ARCH" != "arm64" ]]; then
  echo "ClipShelf supports Apple Silicon (arm64) only." >&2
  exit 2
fi

APP_VERSION="${CLIPSHELF_VERSION:-1.1.0}"
APP_BUILD="${CLIPSHELF_BUILD_NUMBER:-$APP_VERSION}"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$APP_BUILD" =~ ^[0-9]+(\.[0-9]+\.[0-9]+)?$ ]]; then
  echo "CLIPSHELF_VERSION must be x.y.z; CLIPSHELF_BUILD_NUMBER must be an integer or x.y.z." >&2
  exit 2
fi
if ! /usr/bin/xcrun --find swift >/dev/null 2>&1; then
  echo "Apple Command Line Tools are required. Run: xcode-select --install" >&2
  exit 1
fi

echo "Building ClipShelf $APP_VERSION for $BUILD_ARCH..."
/usr/bin/xcrun swift build --configuration release --arch "$BUILD_ARCH"
BINARY_DIR="$(/usr/bin/xcrun swift build --configuration release --arch "$BUILD_ARCH" --show-bin-path)"

SPARKLE_FRAMEWORKS=()
while IFS= read -r -d '' FRAMEWORK_PATH; do
  SPARKLE_FRAMEWORKS+=("$FRAMEWORK_PATH")
done < <(/usr/bin/find "$PROJECT_DIR/.build/artifacts/sparkle" -type d -name Sparkle.framework -prune -print0)
if [[ ${#SPARKLE_FRAMEWORKS[@]} -ne 1 ]]; then
  echo "Expected exactly one Sparkle.framework in the resolved SwiftPM artifact." >&2
  exit 1
fi
SPARKLE_SOURCE="${SPARKLE_FRAMEWORKS[0]}"
SPARKLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SPARKLE_SOURCE/Resources/Info.plist")"
if [[ "$SPARKLE_VERSION" != "2.10.0" ]]; then
  echo "Expected Sparkle 2.10.0, found $SPARKLE_VERSION." >&2
  exit 1
fi
SPARKLE_LICENSE="$PROJECT_DIR/.build/checkouts/Sparkle/LICENSE"
if [[ ! -f "$SPARKLE_LICENSE" ]]; then
  SPARKLE_LICENSE="$PROJECT_DIR/.build/checkouts/sparkle/LICENSE"
fi
if [[ ! -f "$SPARKLE_LICENSE" ]]; then
  echo "The resolved Sparkle package is missing its LICENSE file." >&2
  exit 1
fi

if [[ ! -f Resources/AppIcon.icns || scripts/generate-icon.swift -nt Resources/AppIcon.icns ]]; then
  echo "Generating app icon..."
  /usr/bin/xcrun swift scripts/generate-icon.swift .build/ClipShelf.iconset
  /usr/bin/iconutil --convert icns .build/ClipShelf.iconset --output Resources/AppIcon.icns
fi

mkdir -p dist
STAGING_DIR="$(/usr/bin/mktemp -d "$PROJECT_DIR/dist/.clipshelf-build.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/ClipShelf.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources" "$STAGED_APP/Contents/Frameworks"
cp "$BINARY_DIR/ClipShelf" "$STAGED_APP/Contents/MacOS/ClipShelf"
if [[ "$(/usr/bin/lipo -archs "$STAGED_APP/Contents/MacOS/ClipShelf")" != "arm64" ]]; then
  echo "The app executable must contain only the arm64 architecture." >&2
  exit 1
fi
cp Resources/Info.plist "$STAGED_APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$STAGED_APP/Contents/Resources/AppIcon.icns"
cp "$SPARKLE_LICENSE" "$STAGED_APP/Contents/Resources/Sparkle-LICENSE.txt"
/usr/bin/ditto "$SPARKLE_SOURCE" "$STAGED_APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_BUNDLE="$STAGED_APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_CONTENTS="$SPARKLE_BUNDLE/Versions/B"

# Thin the framework and its helpers before signing the nested code inside out.
for SPARKLE_BINARY in \
  "$SPARKLE_CONTENTS/Sparkle" \
  "$SPARKLE_CONTENTS/Autoupdate" \
  "$SPARKLE_CONTENTS/Updater.app/Contents/MacOS/Updater" \
  "$SPARKLE_CONTENTS/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
  "$SPARKLE_CONTENTS/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"; do
  if [[ "$(/usr/bin/lipo -archs "$SPARKLE_BINARY")" != "arm64" ]]; then
    /usr/bin/lipo "$SPARKLE_BINARY" -thin arm64 -output "$SPARKLE_BINARY.arm64"
    mv "$SPARKLE_BINARY.arm64" "$SPARKLE_BINARY"
    chmod +x "$SPARKLE_BINARY"
  fi
done

# Local ad-hoc builds must not enable Hardened Runtime library validation.
for SIGN_TARGET in \
  "$SPARKLE_CONTENTS/XPCServices/Installer.xpc" \
  "$SPARKLE_CONTENTS/XPCServices/Downloader.xpc" \
  "$SPARKLE_CONTENTS/Autoupdate" \
  "$SPARKLE_CONTENTS/Updater.app" \
  "$SPARKLE_BUNDLE"; do
  /usr/bin/codesign --force --sign - --options 0 --timestamp=none "$SIGN_TARGET"
done
if ! /usr/bin/otool -l "$STAGED_APP/Contents/MacOS/ClipShelf" | /usr/bin/grep -F '@executable_path/../Frameworks' >/dev/null; then
  /usr/bin/install_name_tool -add_rpath '@executable_path/../Frameworks' "$STAGED_APP/Contents/MacOS/ClipShelf"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$STAGED_APP/Contents/Info.plist"
/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - --options 0 --timestamp=none "$STAGED_APP/Contents/MacOS/ClipShelf"
/usr/bin/codesign --force --sign - --options 0 --timestamp=none "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

if [[ -e dist/ClipShelf.app ]]; then
  mv dist/ClipShelf.app "$STAGING_DIR/Previous.app"
fi
mv "$STAGED_APP" dist/ClipShelf.app
echo "Built: $PROJECT_DIR/dist/ClipShelf.app"
