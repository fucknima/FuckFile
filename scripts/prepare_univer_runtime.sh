#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.univer-runtime/UniverAssets"
CACHE="$ROOT/.univer-runtime/npm"
STAMP="$OUT/.runtime-version"
SOURCE_HASH="$(cat \
  "$ROOT/resources/univer/entry.js" \
  "$ROOT/resources/univer/index.html" \
  "$ROOT/resources/univer/host.css" | shasum -a 256 | awk '{print $1}')"
VERSION="univer=1.0.0-rc.0;sheetjs=0.18.5;esbuild=0.25.9;src=$SOURCE_HASH"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$VERSION" \
      && -s "$OUT/index.html" \
      && -s "$OUT/univer-host.js" \
      && -s "$OUT/univer-host.css" \
      && -s "$OUT/xlsx.full.min.js" ]]; then
  echo "== Univer runtime cached: $VERSION"
  exit 0
fi

rm -rf "$OUT" "$CACHE"
mkdir -p "$OUT" "$CACHE"

cat > "$CACHE/package.json" <<'JSON'
{
  "private": true,
  "dependencies": {
    "@univerjs/presets": "1.0.0-rc.0",
    "@univerjs/preset-sheets-core": "1.0.0-rc.0",
    "react": "18.3.1",
    "react-dom": "18.3.1",
    "rxjs": "7.8.2",
    "xlsx": "0.18.5",
    "esbuild": "0.25.9"
  }
}
JSON

npm install --prefix "$CACHE" --ignore-scripts --no-audit --no-fund \
  --package-lock=false --legacy-peer-deps

"$CACHE/node_modules/.bin/esbuild" "$ROOT/resources/univer/entry.js" \
  --bundle \
  --minify \
  --format=iife \
  --platform=browser \
  --target=safari15 \
  --loader:.woff=file \
  --loader:.woff2=file \
  --loader:.ttf=file \
  --asset-names='assets/[name]-[hash]' \
  --outfile="$OUT/univer-host.js"

cp "$CACHE/node_modules/xlsx/dist/xlsx.full.min.js" "$OUT/xlsx.full.min.js"
cp "$ROOT/resources/univer/index.html" "$OUT/index.html"
cp "$ROOT/resources/univer/host.css" "$OUT/host.css"

mkdir -p "$OUT/licenses"
cp "$CACHE/node_modules/@univerjs/preset-sheets-core/LICENSE" \
  "$OUT/licenses/Univer-Apache-2.0.txt" 2>/dev/null || \
  cp "$CACHE/node_modules/@univerjs/presets/LICENSE" \
  "$OUT/licenses/Univer-Apache-2.0.txt"
cp "$CACHE/node_modules/xlsx/LICENSE" \
  "$OUT/licenses/SheetJS-Apache-2.0.txt" 2>/dev/null || true

printf '%s\n' "$VERSION" > "$STAMP"
for file in index.html univer-host.js univer-host.css xlsx.full.min.js host.css; do
  test -s "$OUT/$file"
done
node --check "$OUT/univer-host.js"
echo "== Univer runtime ready: $VERSION ($(du -sh "$OUT" | awk '{print $1}'))"
