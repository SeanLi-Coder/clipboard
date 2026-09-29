#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS_VERSION="2.10.0"
TOOLS_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
CACHE_DIR="$PROJECT_DIR/.build/sparkle-tools"
ARCHIVE="$CACHE_DIR/Sparkle-$TOOLS_VERSION.tar.xz"
TOOLS_DIR="$CACHE_DIR/$TOOLS_VERSION"
mkdir -p "$CACHE_DIR"

if [[ ! -f "$ARCHIVE" ]] || [[ "$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')" != "$TOOLS_SHA256" ]]; then
  DOWNLOAD_PATH="$(/usr/bin/mktemp "$CACHE_DIR/.download.XXXXXX")"
  trap 'rm -f "$DOWNLOAD_PATH"' EXIT
  /usr/bin/curl --fail --silent --show-error --location --retry 3 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$TOOLS_VERSION/Sparkle-$TOOLS_VERSION.tar.xz" \
    --output "$DOWNLOAD_PATH"
  if [[ "$(/usr/bin/shasum -a 256 "$DOWNLOAD_PATH" | /usr/bin/awk '{print $1}')" != "$TOOLS_SHA256" ]]; then
    echo "Sparkle tools archive checksum verification failed." >&2
    exit 1
  fi
  mv "$DOWNLOAD_PATH" "$ARCHIVE"
  trap - EXIT
fi

# Re-extract the tools from the verified archive before executing them.
mkdir -p "$TOOLS_DIR"
/usr/bin/tar -xf "$ARCHIVE" -C "$TOOLS_DIR" ./bin ./LICENSE
printf '%s\n' "$TOOLS_DIR/bin"
