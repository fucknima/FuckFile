#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_ROOT="$ROOT/.univer-runtime"
BUNDLE="$RUNTIME_ROOT/bundle"
OUT="$BUNDLE/UniverAssets"
CACHE="$RUNTIME_ROOT/npm"
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
      && -s "$OUT/xlsx.full.min.js" \
      && -s "$OUT/host.css" ]]; then
  echo "== Univer runtime cached: $VERSION"
  exit 0
fi

rm -rf "$BUNDLE" "$CACHE"
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

# esbuild resolves bare imports from the entry file's directory. The source
# entry lives under resources/, while the pinned node_modules lives under
# .univer-runtime/npm. Build from a copied entry inside that npm workspace so
# @univerjs/* always resolves deterministically instead of depending on a
# machine-global NODE_PATH.
cp "$ROOT/resources/univer/entry.js" "$CACHE/entry.js"
"$CACHE/node_modules/.bin/esbuild" "$CACHE/entry.js" \
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
if [[ -f "$CACHE/node_modules/@univerjs/preset-sheets-core/LICENSE" ]]; then
  cp "$CACHE/node_modules/@univerjs/preset-sheets-core/LICENSE" \
    "$OUT/licenses/Univer-Apache-2.0.txt"
elif [[ -f "$CACHE/node_modules/@univerjs/presets/LICENSE" ]]; then
  cp "$CACHE/node_modules/@univerjs/presets/LICENSE" \
    "$OUT/licenses/Univer-Apache-2.0.txt"
else
  echo "ERROR: Univer license file is missing" >&2
  exit 1
fi
if [[ -f "$CACHE/node_modules/xlsx/LICENSE" ]]; then
  cp "$CACHE/node_modules/xlsx/LICENSE" \
    "$OUT/licenses/SheetJS-Apache-2.0.txt"
fi

printf '%s\n' "$VERSION" > "$STAMP"
for file in index.html univer-host.js univer-host.css xlsx.full.min.js host.css; do
  if [[ ! -s "$OUT/$file" ]]; then
    echo "ERROR: Univer runtime output missing: $file" >&2
    exit 1
  fi
done
node --check "$OUT/univer-host.js"
node --check "$OUT/xlsx.full.min.js"
echo "== Univer runtime ready: $VERSION ($(du -sh "$OUT" | awk '{print $1}'))"
