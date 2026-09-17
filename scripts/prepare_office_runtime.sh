#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_ROOT="$ROOT/.office-runtime"
BUNDLE="$RUNTIME_ROOT/bundle"
OUT="$BUNDLE/OfficeAssets"
CACHE="$RUNTIME_ROOT/npm"
MANIFEST="$RUNTIME_ROOT/.runtime-manifest"
STAMP="$OUT/.runtime-version"
SOURCE_HASH="$(cat \
  "$ROOT/resources/office/entry.js" \
  "$ROOT/resources/office/fixed-layout.js" \
  "$ROOT/resources/office/index.html" \
  "$ROOT/resources/office/host.css" | shasum -a 256 | awk '{print $1}')"
VERSION="reamkit=1.29.0;docx-preview=0.4.0;jszip=3.10.1;mdgate=0.6.25;marked=18.0.12;dompurify=3.4.15;esbuild=0.25.9;fixed-layout=3;src=$SOURCE_HASH"

# Cache hit requires the stamp to match and every file recorded by the last
# successful build to still exist (catches lost assets / licenses).
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$VERSION" \
      && -s "$MANIFEST" ]]; then
  CACHE_OK=1
  while IFS= read -r rel; do
    [[ -s "$OUT/$rel" ]] || { CACHE_OK=0; break; }
  done < "$MANIFEST"
  if [[ "$CACHE_OK" == 1 ]]; then
    echo "== Office runtime cached: $VERSION"
    exit 0
  fi
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

# Keep the fixed-layout compatibility shim in the same runtime file that CI
# already verifies inside the final .app. This avoids another Build-810 class
# failure where index.html references a helper that was never copied.
printf '\n' >> "$OUT/office-host.js"
cat "$ROOT/resources/office/fixed-layout.js" >> "$OUT/office-host.js"

cp "$ROOT/resources/office/index.html" "$OUT/index.html"
cp "$ROOT/resources/office/host.css" "$OUT/host.css"

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

for file in index.html office-host.js host.css; do
  if [[ ! -s "$OUT/$file" ]]; then
    echo "ERROR: Office runtime output missing: $file" >&2
    exit 1
  fi
done
node --check "$OUT/office-host.js"

grep -q 'ffoffice:///document' "$OUT/office-host.js" || {
  echo "ERROR: Office runtime document bridge missing" >&2; exit 1;
}
grep -q 'FFOffice' "$OUT/office-host.js" || {
  echo "ERROR: Office runtime native bridge missing" >&2; exit 1;
}
grep -q 'legacy-word-docx-layout' "$OUT/office-host.js" || {
  echo "ERROR: Office runtime legacy Word layout path missing" >&2; exit 1;
}
grep -q 'ff-fixed-layout-stage' "$OUT/office-host.js" || {
  echo "ERROR: Office fixed-layout compositor scaler missing" >&2; exit 1;
}

( cd "$OUT" && find . -type f | sed 's|^\./||' | sort > "$MANIFEST" )
printf '%s\n' "$VERSION" > "$STAMP"
echo "== Office runtime ready: $VERSION ($(du -sh "$OUT" | awk '{print $1}'))"
