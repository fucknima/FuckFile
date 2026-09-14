// Unit checks for the pure XLSX style parser used by the spreadsheet viewer.
//
//   node tests/style_xml_check.mjs

import {
  parseStylesXml,
  parseThemePalette,
  parseWorksheetInfo,
  resolveColor,
  univerStyleForXf,
} from '../resources/univer/style-xml.mjs';

let failures = 0;

function check(condition, name) {
  if (condition) return;
  failures += 1;
  console.error('FAIL: ' + name);
}

function equal(actual, expected, name) {
  check(JSON.stringify(actual) === JSON.stringify(expected),
    `${name} (got ${JSON.stringify(actual)}, want ${JSON.stringify(expected)})`);
}

const THEME_XML = `<?xml version="1.0"?>
<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
<a:themeElements><a:clrScheme name="Office">
<a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>
<a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>
<a:dk2><a:srgbClr val="44546A"/></a:dk2>
<a:lt2><a:srgbClr val="E7E6E6"/></a:lt2>
<a:accent1><a:srgbClr val="4472C4"/></a:accent1>
<a:accent2><a:srgbClr val="ED7D31"/></a:accent2>
<a:accent3><a:srgbClr val="A5A5A5"/></a:accent3>
<a:accent4><a:srgbClr val="FFC000"/></a:accent4>
<a:accent5><a:srgbClr val="5B9BD5"/></a:accent5>
<a:accent6><a:srgbClr val="70AD47"/></a:accent6>
<a:hlink><a:srgbClr val="0563C1"/></a:hlink>
<a:folHlink><a:srgbClr val="954F72"/></a:folHlink>
</a:clrScheme></a:themeElements></a:theme>`;

const STYLES_XML = `<?xml version="1.0"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="1"><numFmt numFmtId="176" formatCode="0.00_ ;[Red]\\-0.00\\ "/></numFmts>
<fonts count="3">
<font><sz val="11"/><color theme="1"/><name val="Calibri"/></font>
<font><b/><i/><strike/><u/><sz val="14"/><color rgb="FFFF0000"/><name val="Arial"/></font>
<font><sz val="11"/><color indexed="10"/><name val="宋体"/><vertAlign val="superscript"/></font>
</fonts>
<fills count="3">
<fill><patternFill patternType="none"/></fill>
<fill><patternFill patternType="gray125"/></fill>
<fill><patternFill patternType="solid"><fgColor theme="4" tint="0.4"/><bgColor indexed="64"/></patternFill></fill>
</fills>
<borders count="2">
<border><left/><right/><top/><bottom/></border>
<border><left style="thin"><color rgb="FF000000"/></left><right style="medium"><color theme="3"/></right><top style="dashDot"><color indexed="10"/></top><bottom style="double"><color auto="1"/></bottom></border>
</borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="5">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"><alignment horizontal="center" vertical="center" wrapText="1" textRotation="45"/></xf>
<xf numFmtId="176" fontId="2" fillId="2" borderId="1" xfId="0" applyNumberFormat="1" applyFill="1" applyBorder="1"/>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1"/>
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"><alignment horizontal="right" textRotation="120"/></xf>
</cellXfs>
</styleSheet>`;

const SHEET_XML = `<?xml version="1.0"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<sheetPr><tabColor rgb="FF00B050"/></sheetPr>
<sheetViews><sheetView showGridLines="0" tabSelected="1"><pane xSplit="1" ySplit="2" topLeftCell="B3" activePane="bottomRight" state="frozen"/></sheetView></sheetViews>
<sheetData>
<row r="1"><c r="A1" s="1" t="s"><v>0</v></c><c r="B1" s="4"><v>1</v></c><c r="C1"/></row>
<row r="2"><c r="A2" s="2"><v>2</v></c><c r="B2" s="0"><v>3</v></c></row>
</sheetData>
</worksheet>`;

// --- theme -----------------------------------------------------------------
{
  const palette = parseThemePalette(THEME_XML);
  equal(palette[0], '#FFFFFF', 'theme index 0 is lt1');
  equal(palette[1], '#000000', 'theme index 1 is dk1');
  equal(palette[3], '#44546A', 'theme index 3 is dk2');
  equal(palette[4], '#4472C4', 'theme accent1');
  const fallback = parseThemePalette('');
  equal(fallback.length, 12, 'theme fallback length');
}

// --- colors ----------------------------------------------------------------
{
  const palette = parseThemePalette(THEME_XML);
  equal(resolveColor({ rgb: 'FFFF0000' }, palette), { rgb: '#FF0000' }, 'argb rgb');
  equal(resolveColor({ indexed: '10' }, palette), { rgb: '#FF0000' }, 'indexed color');
  equal(resolveColor({ theme: '1' }, palette), { rgb: '#000000' }, 'theme dk1 resolves to black');
  equal(resolveColor({ theme: '3' }, palette), { rgb: '#44546A' }, 'theme dk2');
  equal(resolveColor({ auto: '1' }, palette), { rgb: '#000000' }, 'auto color');
  check(resolveColor(null, palette) === null, 'missing color is null');
}

// --- styles ----------------------------------------------------------------
{
  const palette = parseThemePalette(THEME_XML);
  const tables = parseStylesXml(STYLES_XML);
  equal(tables.fonts.length, 3, 'font count');
  equal(tables.fills.length, 3, 'fill count');
  equal(tables.borders.length, 2, 'border count');

  equal(univerStyleForXf(0, tables, palette),
    { ff: 'Calibri', fs: 11, cl: { rgb: '#000000' } }, 'default xf keeps the base font');

  const bold = univerStyleForXf(1, tables, palette);
  equal(bold.ff, 'Arial', 'bold style font family');
  equal(bold.fs, 14, 'bold style font size');
  equal(bold.bl, 1, 'bold flag');
  equal(bold.it, 1, 'italic flag');
  equal(bold.ul, { s: 1 }, 'underline');
  equal(bold.st, { s: 1 }, 'strike');
  equal(bold.cl, { rgb: '#FF0000' }, 'font color');
  equal(bold.ht, 2, 'horizontal center');
  equal(bold.vt, 2, 'vertical center');
  equal(bold.tb, 3, 'wrap strategy');
  equal(bold.tr, { a: 45 }, 'text rotation');

  const tinted = univerStyleForXf(2, tables, palette);
  equal(tinted.ff, '宋体', 'east asian font family');
  equal(tinted.va, 3, 'superscript baseline');
  equal(tinted.cl, { rgb: '#FF0000' }, 'indexed font color');
  check(tinted.bg && /^#[0-9A-F]{6}$/.test(tinted.bg.rgb), 'tinted fill resolves to rgb');
  check(tinted.bg.rgb !== '#4472C4', 'tint changes the accent color');
  equal(tinted.bd.l, { s: 1, cl: { rgb: '#000000' } }, 'thin left border');
  equal(tinted.bd.r, { s: 8, cl: { rgb: '#44546A' } }, 'medium right border');
  equal(tinted.bd.t, { s: 5, cl: { rgb: '#FF0000' } }, 'dashDot top border from index 10');
  equal(tinted.bd.b, { s: 7, cl: { rgb: '#000000' } }, 'double bottom border auto color');
  check(tinted.n === undefined, 'xf style leaves numfmt to the cell');

  const borderOnly = univerStyleForXf(3, tables, palette);
  equal(borderOnly.bd.b, { s: 7, cl: { rgb: '#000000' } }, 'border-only style keeps bottom');
  equal(borderOnly.bd.l, { s: 1, cl: { rgb: '#000000' } }, 'border-only style keeps left');

  const rotationOnly = univerStyleForXf(4, tables, palette);
  equal(rotationOnly.tr, undefined, 'vertical rotation is not guessed');
  equal(rotationOnly.ht, 3, 'right alignment');
}

// --- worksheet -------------------------------------------------------------
{
  const info = parseWorksheetInfo(SHEET_XML);
  equal(info.xfIndexes.get('A1'), 1, 'A1 style index');
  equal(info.xfIndexes.get('B1'), 4, 'B1 style index');
  equal(info.xfIndexes.get('A2'), 2, 'A2 style index');
  check(!info.xfIndexes.has('C1'), 'unstyled cell is not indexed');

  const palette = parseThemePalette(THEME_XML);
  equal(resolveColor(info.tabColor, palette), { rgb: '#00B050' }, 'tab color');

  check(info.freeze && info.freeze.xSplit === 1 && info.freeze.ySplit === 2,
    'freeze splits');
  equal(info.freeze.startRow, 2, 'freeze start row');
  equal(info.freeze.startColumn, 1, 'freeze start column');
  equal(info.showGridLines, false, 'gridlines hidden');
}

if (failures) {
  console.error(failures + ' style check(s) failed');
  process.exit(1);
}
console.log('style checks passed');
