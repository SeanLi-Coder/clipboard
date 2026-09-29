#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -gt 1 ]]; then
  echo "Usage: scripts/create-dmg.sh [path/to/ClipShelf.app]" >&2
  exit 2
fi
APP_PATH="${1:-$PROJECT_DIR/dist/ClipShelf.app}"
if [[ ! -f "$APP_PATH/Contents/MacOS/ClipShelf" ]]; then
  echo "A built ClipShelf.app is required. Run scripts/build.sh first." >&2
  exit 1
fi
if [[ "$(/usr/bin/lipo -archs "$APP_PATH/Contents/MacOS/ClipShelf")" != "arm64" ]]; then
  echo "DMG packaging supports Apple Silicon (arm64) only." >&2
  exit 1
fi
/usr/bin/codesign --verify --strict "$APP_PATH"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "The app version must be x.y.z." >&2
  exit 1
fi

mkdir -p "$PROJECT_DIR/dist"
STAGING_DIR="$(/usr/bin/mktemp -d "$PROJECT_DIR/dist/.clipshelf-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
CONTENTS_DIR="$STAGING_DIR/contents"
mkdir -p "$CONTENTS_DIR"
/usr/bin/ditto "$APP_PATH" "$CONTENTS_DIR/ClipShelf.app"
ln -s /Applications "$CONTENTS_DIR/Applications"
cat > "$CONTENTS_DIR/安装说明.txt" <<'INSTRUCTIONS'
ClipShelf · Apple Silicon

1. 将 ClipShelf.app 拖到 Applications（应用程序）。
2. 从“应用程序”打开 ClipShelf。
3. 复制内容后按 ⌘⇧V 浏览历史，按 ↑↓ 选择，按 Enter 恢复，再按 ⌘V 使用。
4. 安装完成后，可在 Finder 中推出 ClipShelf 磁盘映像。

需要 Apple Silicon Mac 和 macOS 13 或更新版本。
此版本尚未完成 Apple Developer ID 签名和公证。若首次打开被阻止，请确认来源后，
到“系统设置 → 隐私与安全性”允许打开。

源码与更新：https://github.com/SeanLi-Coder/clipboard
INSTRUCTIONS

IMAGE_NAME="ClipShelf-${APP_VERSION}-macOS-arm64.dmg"
echo "Creating Apple Silicon disk image..."
/usr/bin/hdiutil create -quiet -volname "ClipShelf" -fs HFS+ -format UDZO \
  -srcfolder "$CONTENTS_DIR" "$STAGING_DIR/$IMAGE_NAME"
/usr/bin/hdiutil verify -quiet "$STAGING_DIR/$IMAGE_NAME"
mv "$STAGING_DIR/$IMAGE_NAME" "$PROJECT_DIR/dist/$IMAGE_NAME"
(
  cd "$PROJECT_DIR/dist"
  /usr/bin/shasum -a 256 "$IMAGE_NAME" > "$IMAGE_NAME.sha256"
)
echo "Packaged: $PROJECT_DIR/dist/$IMAGE_NAME"
echo "Checksum: $PROJECT_DIR/dist/$IMAGE_NAME.sha256"
