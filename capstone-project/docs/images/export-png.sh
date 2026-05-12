#!/usr/bin/env bash
# Export .drawio files to PNG using the Draw.io desktop CLI.
#
# Requirements:
#   macOS:   brew install --cask drawio   (installs /Applications/draw.io.app)
#   Linux:   download AppImage from https://github.com/jgraph/drawio-desktop/releases
#
# Usage:
#   chmod +x export-png.sh
#   ./export-png.sh

set -euo pipefail

DRAWIO_BIN=""

# Detect draw.io binary (macOS app bundle or system PATH)
if [ -x "/Applications/draw.io.app/Contents/MacOS/draw.io" ]; then
  DRAWIO_BIN="/Applications/draw.io.app/Contents/MacOS/draw.io"
elif command -v draw.io &>/dev/null; then
  DRAWIO_BIN="draw.io"
elif command -v drawio &>/dev/null; then
  DRAWIO_BIN="drawio"
else
  echo "ERROR: draw.io CLI not found."
  echo "Install via: brew install --cask drawio"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for DRAWIO_FILE in "$SCRIPT_DIR"/*.drawio; do
  PNG_FILE="${DRAWIO_FILE%.drawio}.png"
  echo "Exporting: $(basename "$DRAWIO_FILE") → $(basename "$PNG_FILE")"
  "$DRAWIO_BIN" \
    --export \
    --format png \
    --scale 2 \
    --output "$PNG_FILE" \
    "$DRAWIO_FILE"
done

echo "Done. PNG files written to: $SCRIPT_DIR"
