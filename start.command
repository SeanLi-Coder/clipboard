#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

if ! /usr/bin/xcrun --find swift >/dev/null 2>&1; then
  echo "Apple Command Line Tools are required. Run: xcode-select --install"
  echo "After installation, double-click start.command again."
  read -r -p "Press Enter to close..." || true
  exit 1
fi

if ! "$PROJECT_DIR/scripts/build.sh"; then
  echo "Build failed. Review the error above."
  read -r -p "Press Enter to close..." || true
  exit 1
fi
/usr/bin/open "$PROJECT_DIR/dist/ClipShelf.app"
echo "ClipShelf is running in the menu bar. Press Command-Shift-V to open history."
echo "You may close this Terminal window."
