#!/bin/bash
set +x
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -lt 2 ]]; then
  echo "Usage: scripts/verify-feed.sh <appcast.xml> <archive.dmg> [--key-file path | --account name]" >&2
  exit 2
fi
FEED_PATH="$1"
ARCHIVE="$2"
shift 2
SIGNING_FLAGS=(--account "${SPARKLE_KEY_ACCOUNT:-com.seanli.clipshelf.updates}")
if [[ $# -ne 0 ]]; then
  if [[ $# -ne 2 ]]; then echo "Expected one signing key option." >&2; exit 2; fi
  case "$1" in
    --key-file)
      if [[ ! -s "$2" ]]; then echo "The signing key file is missing or empty." >&2; exit 1; fi
      SIGNING_FLAGS=(--ed-key-file "$2") ;;
    --account) SIGNING_FLAGS=(--account "$2") ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
fi
ARCHIVE_NAME="$(basename "$ARCHIVE")"
if [[ ! -f "$ARCHIVE" || ! "$ARCHIVE_NAME" =~ ^ClipShelf-([0-9]+\.[0-9]+\.[0-9]+)-macOS-arm64\.dmg$ ]]; then
  echo "Expected a versioned ClipShelf Apple Silicon DMG." >&2
  exit 2
fi
APP_VERSION="${BASH_REMATCH[1]}"
REPOSITORY="${CLIPSHELF_REPOSITORY:-SeanLi-Coder/clipboard}"
TOOLS_DIR="$("$PROJECT_DIR/scripts/download-sparkle-tools.sh")"
"$TOOLS_DIR/sign_update" "${SIGNING_FLAGS[@]}" --verify "$FEED_PATH"
ARCHIVE_SIGNATURE="$(/usr/bin/python3 "$PROJECT_DIR/scripts/validate-appcast.py" \
  "$FEED_PATH" "$APP_VERSION" "https://github.com/$REPOSITORY/releases/download/v$APP_VERSION/$ARCHIVE_NAME" "$ARCHIVE")"
"$TOOLS_DIR/sign_update" "${SIGNING_FLAGS[@]}" --verify "$ARCHIVE" "$ARCHIVE_SIGNATURE"
echo "Verified update feed and archive: $ARCHIVE_NAME"
