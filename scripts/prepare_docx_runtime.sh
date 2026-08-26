#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.docx-runtime/DocxAssets"
CACHE="$ROOT/.docx-runtime/npm"
STAMP="$OUT/.runtime-version"
VERSION='docx-preview=0.4.0;jszip=3.10.1;host=1'

node --check "$ROOT/resources/docx/docx-host.js"
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$VERSION" && -s "$OUT/index.html" && -s "$OUT/docx-preview.min.js" && -s "$OUT/jszip.min.js" && -s "$OUT/docx-host.js" && -s "$OUT/docx.css" ]]; then
  echo "== DOCX runtime cached: $VERSION"
  exit 0
fi

rm -rf "$OUT" "$CACHE"
mkdir -p "$OUT" "$CACHE"
cat > "$CACHE/package.json" <<'JSON'
{"private":true,"dependencies":{"docx-preview":"0.4.0","jszip":"3.10.1"}}
JSON
npm install --prefix "$CACHE" --ignore-scripts --no-audit --no-fund --package-lock=false
cp "$CACHE/node_modules/jszip/dist/jszip.min.js" "$OUT/jszip.min.js"
cp "$CACHE/node_modules/docx-preview/dist/docx-preview.min.js" "$OUT/docx-preview.min.js"
cp "$ROOT/resources/docx/index.html" "$OUT/index.html"
cp "$ROOT/resources/docx/docx-host.js" "$OUT/docx-host.js"
cp "$ROOT/resources/docx/docx.css" "$OUT/docx.css"
mkdir -p "$OUT/licenses"
cp "$CACHE/node_modules/jszip/LICENSE.markdown" "$OUT/licenses/JSZip-LICENSE.txt"
cp "$CACHE/node_modules/docx-preview/LICENSE" "$OUT/licenses/docx-preview-LICENSE.txt"
printf '%s\n' "$VERSION" > "$STAMP"
for f in index.html docx-host.js docx.css jszip.min.js docx-preview.min.js; do test -s "$OUT/$f"; done
echo "== DOCX runtime ready: $VERSION ($(du -sh "$OUT" | awk '{print $1}'))"
