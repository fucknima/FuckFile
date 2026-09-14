#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_ROOT="$ROOT/.office-runtime"
BUNDLE="$RUNTIME_ROOT/bundle"
OUT="$BUNDLE/OfficeAssets"
CACHE="$RUNTIME_ROOT/npm"
STAMP="$OUT/.runtime-version"
SOURCE_HASH="$(cat \
  "$ROOT/resources/office/entry.js" \
  "$ROOT/resources/office/fixed-layout.js" \
  "$ROOT/resources/office/index.html" \
  "$ROOT/resources/office/host.css" | shasum -a 256 | awk '{print $1}')"
VERSION="reamkit=1.29.0;docx-preview=0.4.0;jszip=3.10.1;mdgate=0.6.25;marked=18.0.12;dompurify=3.4.15;esbuild=0.25.9;fixed-layout=1;src=$SOURCE_HASH"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$VERSION" \
      && -s "$OUT/index.html" \
      && -s "$OUT/office-host.js" \
      && -s "$OUT/fixed-layout.js" \
      && -s "$OUT/host.css" ]]; then
  echo "== Office runtime cached: $VERSION"
  exit 0
fi

rm -rf "$BUNDLE" "$CACHE"
mkdir -p "$OUT" "$CACHE"

cat > "$CACHE/package.json" <<'JSON'
{
  "private": true,
  "dependencies": {
    "reamkit": "1.29.0",
    "docx-preview": "0.4.0",
    "jszip": "3.10.1",
    "@mdgate/odf": "0.6.25",
    "@mdgate/rtf": "0.6.25",
    "@mdgate/pages": "0.6.25",
    "@mdgate/numbers": "0.6.25",
    "@mdgate/keynote": "0.6.25",
    "@mdgate/wps": "0.6.25",
    "marked": "18.0.12",
    "dompurify": "3.4.15",
    "esbuild": "0.25.9"
  }
}
JSON

npm install --prefix "$CACHE" --ignore-scripts --no-audit --no-fund \
  --package-lock=false --legacy-peer-deps

cp "$ROOT/resources/office/entry.js" "$CACHE/entry.js"
"$CACHE/node_modules/.bin/esbuild" "$CACHE/entry.js" \
  --bundle \
  --minify \
  --format=iife \
  --platform=browser \
  --target=safari15 \
  --outfile="$OUT/office-host.js"

cp "$ROOT/resources/office/index.html" "$OUT/index.html"
cp "$ROOT/resources/office/host.css" "$OUT/host.css"
cp "$ROOT/resources/office/fixed-layout.js" "$OUT/fixed-layout.js"

mkdir -p "$OUT/licenses"
for pkg in \
  reamkit docx-preview jszip \
  @mdgate/odf @mdgate/rtf @mdgate/pages @mdgate/numbers @mdgate/keynote @mdgate/wps \
  marked dompurify; do
  src="$CACHE/node_modules/$pkg"
  safe="$(echo "$pkg" | tr '/@' '__')"
  if [[ -f "$src/LICENSE" ]]; then
    cp "$src/LICENSE" "$OUT/licenses/${safe}.txt"
  elif [[ -f "$src/LICENSE.md" ]]; then
    cp "$src/LICENSE.md" "$OUT/licenses/${safe}.txt"
  elif [[ -f "$src/LICENSE.markdown" ]]; then
    cp "$src/LICENSE.markdown" "$OUT/licenses/${safe}.txt"
  elif [[ -f "$src/package.json" ]]; then
    cp "$src/package.json" "$OUT/licenses/${safe}-package.json"
  fi
done

printf '%s\n' "$VERSION" > "$STAMP"
for file in index.html office-host.js fixed-layout.js host.css; do
  if [[ ! -s "$OUT/$file" ]]; then
    echo "ERROR: Office runtime output missing: $file" >&2
    exit 1
  fi
done
node --check "$OUT/office-host.js"
node --check "$OUT/fixed-layout.js"

grep -q 'ffoffice:///document' "$OUT/office-host.js" || {
  echo "ERROR: Office runtime document bridge missing" >&2; exit 1;
}
grep -q 'FFOffice' "$OUT/office-host.js" || {
  echo "ERROR: Office runtime native bridge missing" >&2; exit 1;
}
grep -q 'legacy-word-docx-layout' "$OUT/office-host.js" || {
  echo "ERROR: Office runtime legacy Word layout path missing" >&2; exit 1;
}
grep -q 'scale(' "$OUT/fixed-layout.js" || {
  echo "ERROR: Office fixed-layout compositor scaler missing" >&2; exit 1;
}

echo "== Office runtime ready: $VERSION ($(du -sh "$OUT" | awk '{print $1}'))"
