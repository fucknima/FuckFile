#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.office-runtime/OfficeAssets"
CACHE="$ROOT/.office-runtime/npm"
STAMP="$OUT/.runtime-version"
VERSION_KEY='docx-preview=0.4.0;jszip=3.10.1;pptx-renderer=1.2.4;sheetjs=0.20.3;host=2'

validate_host() {
  command -v node >/dev/null 2>&1 || { echo 'ERROR: node is required to validate Office host' >&2; return 1; }
  node --check "$ROOT/resources/office/office-host.js"
  grep -Fq 'class VirtualSheet' "$ROOT/resources/office/office-host.js" || { echo 'ERROR: virtual sheet renderer missing' >&2; return 1; }
  if grep -Fq 'sheet_to_html' "$ROOT/resources/office/office-host.js"; then
    echo 'ERROR: legacy whole-sheet DOM renderer reintroduced' >&2
    return 1
  fi
  grep -Fq '.sheet-viewport' "$ROOT/resources/office/office.css" || { echo 'ERROR: virtual sheet viewport CSS missing' >&2; return 1; }
  grep -Fq '.sheet-cell {' "$ROOT/resources/office/office.css" || { echo 'ERROR: virtual sheet cell CSS missing' >&2; return 1; }
  grep -Fq 'position:absolute' "$ROOT/resources/office/office.css" || { echo 'ERROR: virtual sheet absolute positioning missing' >&2; return 1; }
}

validate_host

if [[ -f "$STAMP" ]] && [[ "$(cat "$STAMP")" == "$VERSION_KEY" ]] \
   && [[ -s "$OUT/docx-preview.min.js" ]] \
   && [[ -s "$OUT/jszip.min.js" ]] \
   && [[ -s "$OUT/pptx-renderer.browser.es.js" ]] \
   && [[ -s "$OUT/xlsx.full.min.js" ]] \
   && [[ -s "$OUT/index.html" ]] \
   && [[ -s "$OUT/office-host.js" ]] \
   && [[ -s "$OUT/office.css" ]]; then
  echo "== Office runtime cached: $VERSION_KEY"
  exit 0
fi

command -v npm >/dev/null 2>&1 || { echo 'ERROR: npm is required to prepare Office runtime' >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo 'ERROR: curl is required to prepare Office runtime' >&2; exit 1; }

rm -rf "$OUT" "$CACHE"
mkdir -p "$OUT" "$CACHE"

cat > "$CACHE/package.json" <<'JSON'
{
  "private": true,
  "dependencies": {
    "@aiden0z/pptx-renderer": "1.2.4",
    "docx-preview": "0.4.0",
    "jszip": "3.10.1"
  }
}
JSON

npm install --prefix "$CACHE" --ignore-scripts --no-audit --no-fund --package-lock=false

cp "$CACHE/node_modules/jszip/dist/jszip.min.js" "$OUT/jszip.min.js"
cp "$CACHE/node_modules/docx-preview/dist/docx-preview.min.js" "$OUT/docx-preview.min.js"

PPTX_BROWSER_ENTRY="$(find "$CACHE/node_modules/@aiden0z/pptx-renderer" -type f -name 'aiden0z-pptx-renderer.browser.es.js' -print -quit)"
if [[ -z "$PPTX_BROWSER_ENTRY" ]]; then
  echo 'ERROR: @aiden0z/pptx-renderer browser bundle not found' >&2
  exit 1
fi
cp "$PPTX_BROWSER_ENTRY" "$OUT/pptx-renderer.browser.es.js"

curl --fail --location --retry 3 --retry-delay 2 \
  'https://cdn.sheetjs.com/xlsx-0.20.3/package/dist/xlsx.full.min.js' \
  --output "$OUT/xlsx.full.min.js"

cp "$ROOT/resources/office/index.html" "$OUT/index.html"
cp "$ROOT/resources/office/office-host.js" "$OUT/office-host.js"
cp "$ROOT/resources/office/office.css" "$OUT/office.css"

mkdir -p "$OUT/licenses"
cp "$CACHE/node_modules/jszip/LICENSE.markdown" "$OUT/licenses/JSZip-LICENSE.txt"
cp "$CACHE/node_modules/docx-preview/LICENSE" "$OUT/licenses/docx-preview-LICENSE.txt"
cp "$CACHE/node_modules/@aiden0z/pptx-renderer/LICENSE" "$OUT/licenses/pptx-renderer-LICENSE.txt"
curl --fail --location --retry 3 --retry-delay 2 \
  'https://cdn.sheetjs.com/xlsx-0.20.3/package/LICENSE' \
  --output "$OUT/licenses/SheetJS-LICENSE.txt"
cp "$ROOT/third_party/office-runtime/NOTICE.txt" "$OUT/NOTICE.txt"

printf '%s\n' "$VERSION_KEY" > "$STAMP"
for file in index.html office-host.js office.css jszip.min.js docx-preview.min.js pptx-renderer.browser.es.js xlsx.full.min.js NOTICE.txt; do
  test -s "$OUT/$file" || { echo "ERROR: missing Office runtime asset: $file" >&2; exit 1; }
done
cmp -s "$ROOT/resources/office/office-host.js" "$OUT/office-host.js" || { echo 'ERROR: packaged Office host is stale' >&2; exit 1; }
cmp -s "$ROOT/resources/office/office.css" "$OUT/office.css" || { echo 'ERROR: packaged Office CSS is stale' >&2; exit 1; }
printf '== Office runtime ready: %s\n' "$VERSION_KEY"
printf '== Office runtime size: %s\n' "$(du -sh "$OUT" | awk '{print $1}')"
