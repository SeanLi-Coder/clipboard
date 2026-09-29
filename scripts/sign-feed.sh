#!/bin/bash
set +x
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -lt 1 ]]; then
  echo "Usage: scripts/sign-feed.sh <ClipShelf-version-macOS-arm64.dmg> [--key-file path | --account name] [--output path]" >&2
  exit 2
fi
ARCHIVE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
shift
KEY_FILE=""
KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-com.seanli.clipshelf.updates}"
FEED_OUTPUT="$PROJECT_DIR/dist/appcast.xml"
while [[ $# -gt 0 ]]; do
  if [[ $# -lt 2 ]]; then echo "Missing option value." >&2; exit 2; fi
  case "$1" in
    --key-file) KEY_FILE="$2" ;;
    --account) KEY_ACCOUNT="$2" ;;
    --output) FEED_OUTPUT="$2" ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift 2
done
ARCHIVE_NAME="$(basename "$ARCHIVE")"
if [[ ! -f "$ARCHIVE" || ! "$ARCHIVE_NAME" =~ ^ClipShelf-([0-9]+\.[0-9]+\.[0-9]+)-macOS-arm64\.dmg$ ]]; then
  echo "Expected a versioned ClipShelf Apple Silicon DMG." >&2
  exit 2
fi
APP_VERSION="${BASH_REMATCH[1]}"
REPOSITORY="${CLIPSHELF_REPOSITORY:-SeanLi-Coder/clipboard}"
if [[ ! "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "CLIPSHELF_REPOSITORY must be owner/repository." >&2
  exit 2
fi
TOOLS_DIR="$("$PROJECT_DIR/scripts/download-sparkle-tools.sh")"
STAGING_DIR="$(/usr/bin/mktemp -d "$PROJECT_DIR/.build/sign-feed.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
umask 077
mkdir "$STAGING_DIR/updates"
SIGNING_FLAGS=(--account "$KEY_ACCOUNT")
VERIFICATION_FLAGS=(--account "$KEY_ACCOUNT")
if [[ -n "$KEY_FILE" ]]; then
  if [[ ! -s "$KEY_FILE" ]]; then echo "The signing key file is missing or empty." >&2; exit 1; fi
  cat "$KEY_FILE" > "$STAGING_DIR/private-key"
  chmod 600 "$STAGING_DIR/private-key"
  SIGNING_FLAGS=(--ed-key-file "$STAGING_DIR/private-key")
  VERIFICATION_FLAGS=(--key-file "$STAGING_DIR/private-key")
fi
cp "$ARCHIVE" "$STAGING_DIR/updates/$ARCHIVE_NAME"
DOWNLOAD_PREFIX="https://github.com/$REPOSITORY/releases/download/v$APP_VERSION/"
"$TOOLS_DIR/generate_appcast" "${SIGNING_FLAGS[@]}" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --link "https://github.com/$REPOSITORY" \
  --maximum-deltas 0 --maximum-versions 1 \
  -o "$STAGING_DIR/updates/appcast.xml" "$STAGING_DIR/updates"

# Always sign the feed explicitly, including when an app's settings change.
"$TOOLS_DIR/sign_update" "${SIGNING_FLAGS[@]}" "$STAGING_DIR/updates/appcast.xml"
"$PROJECT_DIR/scripts/verify-feed.sh" "$STAGING_DIR/updates/appcast.xml" "$ARCHIVE" "${VERIFICATION_FLAGS[@]}"
mkdir -p "$(dirname "$FEED_OUTPUT")"
cp "$STAGING_DIR/updates/appcast.xml" "$FEED_OUTPUT"
chmod 644 "$FEED_OUTPUT"
(
  cd "$(dirname "$FEED_OUTPUT")"
  /usr/bin/shasum -a 256 "$(basename "$FEED_OUTPUT")" > "$(basename "$FEED_OUTPUT").sha256"
)
echo "Signed and verified update feed: $FEED_OUTPUT"
