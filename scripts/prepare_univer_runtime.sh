#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_ROOT="$ROOT/.univer-runtime"
BUNDLE="$RUNTIME_ROOT/bundle"
OUT="$BUNDLE/UniverAssets"
CACHE="$RUNTIME_ROOT/npm"
MANIFEST="$RUNTIME_ROOT/.runtime-manifest"
STAMP="$OUT/.runtime-version"
SOURCE_HASH="$(cat \
  "$ROOT/resources/univer/entry.js" \
  "$ROOT/resources/univer/style-xml.mjs" \
  "$ROOT/resources/univer/index.html" \
  "$ROOT/resources/univer/host.css" | shasum -a 256 | awk '{print $1}')"
VERSION="univer=1.0.0-rc.0;sheetjs=0.20.2;jszip=3.10.1;esbuild=0.25.9;src=$SOURCE_HASH"

# Cache hit requires the stamp to match and every file recorded by the last
# successful build to still exist (catches lost font assets / licenses).
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$VERSION" \
      && -s "$MANIFEST" ]]; then
  CACHE_OK=1
  while IFS= read -r rel; do
    [[ -s "$OUT/$rel" ]] || { CACHE_OK=0; break; }
  done < "$MANIFEST"
  if [[ "$CACHE_OK" == 1 ]]; then
    echo "== Univer runtime cached: $VERSION"
    exit 0
  fi
fi

rm -rf "$BUNDLE" "$CACHE"
mkdir -p "$OUT" "$CACHE"

# npm registry 上的 xlsx 停在 0.18.5（含原型污染/ReDoS 修复前的老版本），
# SheetJS 官方只在自有 CDN 发布修复版，这里用 tarball URL 锁死版本。
cat > "$CACHE/package.json" <<'JSON'
{
  "private": true,
  "dependencies": {
    "@univerjs/presets": "1.0.0-rc.0",
    "@univerjs/preset-sheets-core": "1.0.0-rc.0",
    "react": "18.3.1",
    "react-dom": "18.3.1",
    "rxjs": "7.8.2",
    "xlsx": "https://cdn.sheetjs.com/xlsx-0.20.2/xlsx-0.20.2.tgz",
    "jszip": "3.10.1",
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
cp "$ROOT/resources/univer/style-xml.mjs" "$CACHE/style-xml.mjs"
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

for file in index.html univer-host.js univer-host.css xlsx.full.min.js host.css \
            licenses/Univer-Apache-2.0.txt; do
  if [[ ! -s "$OUT/$file" ]]; then
    echo "ERROR: Univer runtime output missing: $file" >&2
    exit 1
  fi
done
node --check "$OUT/univer-host.js"
node --check "$OUT/xlsx.full.min.js"
( cd "$OUT" && find . -type f | sed 's|^\./||' | sort > "$MANIFEST" )
printf '%s\n' "$VERSION" > "$STAMP"
echo "== Univer runtime ready: $VERSION ($(du -sh "$OUT" | awk '{print $1}'))"
