#!/usr/bin/env bash
set -euo pipefail
APP_DIR="$1"          # e.g., apps/sys.clock
OUT_DIR="${2:-dist}"
mkdir -p "$OUT_DIR"

name=$(basename "$APP_DIR")
ver=$(jq -r .version "$APP_DIR/manifest.json")
dst="$OUT_DIR/$name-$ver.lmapp"

( cd "$APP_DIR" && zip -r "../../$dst" . >/dev/null )
sha=$(sha256sum "$dst" | awk '{print $1}')
echo "$sha" > "$OUT_DIR/$name-$ver.sha256"
echo "Built: $dst"
echo "SHA256: $sha"
