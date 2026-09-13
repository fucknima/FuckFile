#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_ROOT="$ROOT/.docx-runtime"
BUNDLE="$RUNTIME_ROOT/bundle"
OUT="$BUNDLE/DocxAssets"
CACHE="$RUNTIME_ROOT/npm"
STAMP="$OUT/.runtime-version"
SOURCE_HASH="$(cat \
  "$ROOT/resources/docx/docx-host.js" \
  "$ROOT/resources/docx/index.html" \
  "$ROOT/resources/docx/docx.css" | shasum -a 256 | awk '{print $1}')"
VERSION="docx-preview=0.4.0;jszip=3.10.1;host=3;src=$SOURCE_HASH"

node --check "$ROOT/resources/docx/docx-host.js"
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$VERSION" \
      && -s "$OUT/index.html" \
      && -s "$OUT/docx-preview.min.js" \
      && -s "$OUT/jszip.min.js" \
      && -s "$OUT/docx-host.js" \
      && -s "$OUT/docx.css" ]]; then
  echo "== DOCX runtime cached: $VERSION"
  exit 0
fi

# Keep the generated runtime behind a wrapper directory. Theos RESOURCE_DIRS
# copies the *contents* of each listed directory into the .app root. Without
# this wrapper, DocxAssets itself is flattened and index.html/docx-host.js end
# up at the bundle root, while the native viewer correctly looks for
# <bundle>/DocxAssets/... .
rm -rf "$BUNDLE" "$CACHE"
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
for f in index.html docx-host.js docx.css jszip.min.js docx-preview.min.js; do
  if [[ ! -s "$OUT/$f" ]]; then
    echo "ERROR: DOCX runtime output missing: $f" >&2
    exit 1
  fi
done
node --check "$OUT/docx-host.js"
echo "== DOCX runtime ready: $VERSION ($(du -sh "$OUT" | awk '{print $1}'))"
