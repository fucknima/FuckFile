// Pure XLSX style parsing for the offline spreadsheet viewer.
//
// SheetJS (community) only exposes fills on `cell.s` and never exposes fonts,
// borders, alignment or freeze panes, so the viewer reads the OOXML parts
// itself (styles.xml / theme1.xml / worksheet XML) and maps them onto Univer's
// IStyleData. Everything in this module is pure on purpose so
// tests/style_xml_check.mjs can cover it without a browser or a zip.

// XLSX theme indexes are NOT the clrScheme document order: index 0 is lt1
// (background 1), 1 is dk1 (text 1), 2 is lt2, 3 is dk2, then accents/hyperlinks
// (same convention SheetJS uses via XLSXThemeClrScheme).
const DEFAULT_THEME = [
  '#FFFFFF', // 0 lt1
  '#000000', // 1 dk1
  '#E7E6E6', // 2 lt2
  '#44546A', // 3 dk2
  '#4472C4', // 4 accent1
  '#ED7D31', // 5 accent2
  '#A5A5A5', // 6 accent3
  '#FFC000', // 7 accent4
  '#5B9BD5', // 8 accent5
  '#70AD47', // 9 accent6
  '#0563C1', // 10 hlink
  '#954F72', // 11 folHlink
];

// [MS-XLS] / [MS-OI29500] legacy indexed palette (SheetJS XLSIcv).
const INDEXED_COLORS = [
  '000000', 'FFFFFF', 'FF0000', '00FF00', '0000FF', 'FFFF00', 'FF00FF', '00FFFF',
  '000000', 'FFFFFF', 'FF0000', '00FF00', '0000FF', 'FFFF00', 'FF00FF', '00FFFF',
  '800000', '008000', '000080', '808000', '800080', '008080', 'C0C0C0', '808080',
  '9999FF', '993366', 'FFFFCC', 'CCFFFF', '660066', 'FF8080', '0066CC', 'CCCCFF',
  '000080', 'FF00FF', 'FFFF00', '00FFFF', '800080', '800000', '008080', '0000FF',
  '00CCFF', 'CCFFFF', 'CCFFCC', 'FFFF99', '99CCFF', 'FF99CC', 'CC99FF', 'FFCC99',
  '3366FF', '33CCCC', '99CC00', 'FFCC00', 'FF9900', 'FF6600', '666699', '969696',
  '003366', '339966', '003300', '333300', '993300', '993366', '333399', '333333',
  'FFFFFF', '000000', '000000', '000000', '000000', '000000', '000000', '000000',
  '000000', '000000', '000000', '000000', '000000', '000000', '000000', '000000',
  '000000', '000000',
];

// Univer BorderStyleTypes enum.
const BORDER_STYLE_TYPES = {
  thin: 1, hair: 2, dotted: 3, dashed: 4, dashDot: 5, dashDotDot: 6,
  double: 7, medium: 8, mediumDashed: 9, mediumDashDot: 10,
  mediumDashDotDot: 11, slantDashDot: 12, thick: 13,
};

// Univer HorizontalAlign / VerticalAlign / WrapStrategy enums.
const HORIZONTAL_ALIGN = {
  left: 1, center: 2, right: 3, justify: 4, distributed: 6,
  centerContinuous: 2, fill: 1,
};
const VERTICAL_ALIGN = { top: 1, center: 2, bottom: 3 };
const WRAP = 3;

export function unescapeXml(value) {
  return String(value == null ? '' : value)
    .replace(/&#x([0-9a-fA-F]+);/g, (_, hex) => String.fromCodePoint(parseInt(hex, 16)))
    .replace(/&#(\d+);/g, (_, code) => String.fromCodePoint(Number(code)))
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&');
}

export function attributes(tag) {
  const out = {};
  const re = /([\w:.-]+)\s*=\s*"([^"]*)"/g;
  let match;
  while ((match = re.exec(String(tag || '')))) out[match[1]] = match[2];
  return out;
}

function section(xml, name) {
  const match = new RegExp(`<${name}\\b[\\s\\S]*?<\\/${name}>`).exec(xml);
  return match ? match[0] : '';
}

function blocks(xml, name) {
  return xml.match(new RegExp(
    `<${name}\\b[^>]*\\/>|<${name}\\b[^>]*>[\\s\\S]*?<\\/${name}>`, 'g')) || [];
}

function colorFromTag(block, name) {
  const match = new RegExp(`<${name}\\b([^>]*?)\\/?>`).exec(block);
  return match ? attributes(match[1]) : null;
}

function isOn(value) {
  return value === undefined || value === '' || value === '1' || value === 'true';
}

// a:clrScheme document order is dk1, lt1, dk2, lt2, accent1..6, hlink,
// folHlink while styles.xml theme indexes use lt1, dk1, lt2, dk2, …. The
// order below maps the parsed document order onto the theme index order.
const THEME_INDEX_ORDER = [1, 0, 3, 2, 4, 5, 6, 7, 8, 9, 10, 11];

export function parseThemePalette(xml) {
  const palette = DEFAULT_THEME.slice();
  const scheme = /<a:clrScheme[\s\S]*?<\/a:clrScheme>/.exec(String(xml || ''));
  if (!scheme) return palette;
  const entries = scheme[0].match(
    /<a:(?:dk1|lt1|dk2|lt2|accent[1-6]|hlink|folHlink)\b[\s\S]*?<\/a:\w+>/g) || [];
  for (let index = 0; index < entries.length && index < 12; index += 1) {
    const entry = entries[index];
    let hex = null;
    const srgb = /<a:srgbClr\b[^>]*\bval="([0-9A-Fa-f]{6,8})"/.exec(entry);
    if (srgb) hex = srgb[1].slice(-6).toUpperCase();
    if (!hex) {
      const sys = /<a:sysClr\b[^>]*\blastClr="([0-9A-Fa-f]{6,8})"/.exec(entry);
      if (sys) hex = sys[1].slice(-6).toUpperCase();
    }
    if (hex) palette[THEME_INDEX_ORDER[index]] = `#${hex}`;
  }
  return palette;
}

export function parseStylesXml(xml) {
  const source = String(xml || '');
  const numFmts = {};
  for (const tag of section(source, 'numFmts').match(/<numFmt\b[^>]*>/g) || []) {
    const attributes_ = attributes(tag);
    if (attributes_.numFmtId != null)
      numFmts[Number(attributes_.numFmtId)] = unescapeXml(attributes_.formatCode);
  }

  const fonts = blocks(section(source, 'fonts'), 'font').map((block) => {
    const name = /<name\b[^>]*\bval="([^"]*)"/.exec(block) ||
      /<rFont\b[^>]*\bval="([^"]*)"/.exec(block);
    const size = /<sz\b[^>]*\bval="([\d.]+)"/.exec(block);
    const vertAlign = /<vertAlign\b[^>]*\bval="([^"]*)"/.exec(block);
    const underline = /<u\b([^>]*?)\/?>/.exec(block);
    const underlineValue = underline ? attributes(underline[1]).val : undefined;
    return {
      name: name ? unescapeXml(name[1]) : undefined,
      size: size ? Number(size[1]) : undefined,
      bold: /<b\b[^>]*\bval="(?:1|true)"/.test(block) || /<b\s*\/>/.test(block),
      italic: /<i\b[^>]*\bval="(?:1|true)"/.test(block) || /<i\s*\/>/.test(block),
      strike: /<strike\b[^>]*\bval="(?:1|true)"/.test(block) || /<strike\s*\/>/.test(block),
      underline: underline ? (underlineValue === undefined || underlineValue !== 'none') : false,
      vertAlign: vertAlign ? vertAlign[1] : undefined,
      color: colorFromTag(block, 'color'),
    };
  });

  const fills = blocks(section(source, 'fills'), 'fill').map((block) => {
    const pattern = /<patternFill\b([^>]*?)\/?>/.exec(block);
    const gradient = /<gradientFill\b[\s\S]*?<stop\b[\s\S]*?<color\b[^>]*\/>[\s\S]*?<\/gradientFill>/.exec(block);
    let patternType = pattern ? attributes(pattern[1]).patternType : undefined;
    let fgColor = colorFromTag(block, 'fgColor');
    if (!fgColor && gradient) fgColor = colorFromTag(gradient[0], 'color');
    if (!patternType && gradient) patternType = 'gradient';
    return { patternType, fgColor, bgColor: colorFromTag(block, 'bgColor') };
  });

  const borders = blocks(section(source, 'borders'), 'border').map((block) => {
    const side = (name) => {
      const match = new RegExp(
        `<${name}\\b([^>]*)>[\\s\\S]*?<\\/${name}>|<${name}\\b([^>]*)\\/>`).exec(block);
      if (!match) return null;
      const attributes_ = attributes(match[1] || match[2] || '');
      if (!attributes_.style || attributes_.style === 'none') return null;
      return { style: attributes_.style, color: colorFromTag(match[0], 'color') };
    };
    return { left: side('left'), right: side('right'), top: side('top'), bottom: side('bottom') };
  });

  const parseXfs = (name) => blocks(section(source, name), 'xf').map((block) => {
    const head = block.slice(0, block.indexOf('>') + 1);
    const attributes_ = attributes(head);
    const number = (key) => (attributes_[key] != null ? Number(attributes_[key]) : undefined);
    const alignment = /<alignment\b([^>]*?)\/?>/.exec(block);
    const alignmentAttributes = alignment ? attributes(alignment[1]) : null;
    return {
      numFmtId: number('numFmtId'),
      fontId: number('fontId'),
      fillId: number('fillId'),
      borderId: number('borderId'),
      xfId: number('xfId'),
      alignment: alignmentAttributes ? {
        horizontal: alignmentAttributes.horizontal,
        vertical: alignmentAttributes.vertical,
        wrapText: alignmentAttributes.wrapText === '1' || alignmentAttributes.wrapText === 'true',
        textRotation: alignmentAttributes.textRotation != null
          ? Number(alignmentAttributes.textRotation) : undefined,
      } : null,
    };
  });

  return {
    numFmts,
    fonts,
    fills,
    borders,
    cellXfs: parseXfs('cellXfs'),
    cellStyleXfs: parseXfs('cellStyleXfs'),
  };
}

// Reads the per-cell xf indexes plus the sheet view settings SheetJS drops.
export function parseWorksheetInfo(xml) {
  const source = String(xml || '');
  const xfIndexes = new Map();
  const cellRegex = /<c\b[^>]*>/g;
  let match;
  while ((match = cellRegex.exec(source))) {
    const tag = match[0];
    const ref = /\br="([A-Za-z]{1,3}\d{1,7})"/.exec(tag);
    if (!ref) continue;
    const style = /\bs="(\d+)"/.exec(tag);
    if (style) xfIndexes.set(ref[1].toUpperCase(), Number(style[1]));
  }

  let freeze = null;
  const pane = /<pane\b([^>]*?)\/?>/.exec(source);
  if (pane) {
    const attributes_ = attributes(pane[1]);
    if ((attributes_.state === 'frozen' || attributes_.state === 'frozenSplit') &&
        (Number(attributes_.xSplit) > 0 || Number(attributes_.ySplit) > 0)) {
      let startRow = Number(attributes_.ySplit) || 0;
      let startColumn = Number(attributes_.xSplit) || 0;
      const topLeft = /^([A-Za-z]{1,3})(\d{1,7})$/.exec(attributes_.topLeftCell || '');
      if (topLeft) {
        startColumn = 0;
        for (const letter of topLeft[1].toUpperCase())
          startColumn = startColumn * 26 + (letter.charCodeAt(0) - 64);
        startColumn -= 1;
        startRow = Number(topLeft[2]) - 1;
      }
      freeze = {
        xSplit: Number(attributes_.xSplit) || 0,
        ySplit: Number(attributes_.ySplit) || 0,
        startRow: Math.max(0, startRow),
        startColumn: Math.max(0, startColumn),
      };
    }
  }

  let showGridLines = null;
  const sheetView = /<sheetView\b([^>]*?)[>/]/.exec(source);
  if (sheetView) {
    const attributes_ = attributes(sheetView[1]);
    if (attributes_.showGridLines === '0' || attributes_.showGridLines === 'false')
      showGridLines = false;
  }

  const tabColor = colorFromTag(source, 'tabColor');
  return { xfIndexes, freeze, showGridLines, tabColor };
}

function hexToRgb(hex) {
  const clean = String(hex || '').replace('#', '');
  return [
    parseInt(clean.slice(0, 2), 16),
    parseInt(clean.slice(2, 4), 16),
    parseInt(clean.slice(4, 6), 16),
  ];
}

function rgbToHex(rgb) {
  return rgb.map((value) => Math.max(0, Math.min(255, Math.round(value)))
    .toString(16).padStart(2, '0').toUpperCase()).join('');
}

// Mirrors SheetJS rgb_tint (HSL lightness scaling).
function applyTint(hex, tint) {
  if (!tint) return hex;
  const [r, g, b] = hexToRgb(hex).map((value) => value / 255);
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  let h = 0;
  let s = 0;
  let l = (max + min) / 2;
  if (max !== min) {
    const delta = max - min;
    s = l > 0.5 ? delta / (2 - max - min) : delta / (max + min);
    if (max === r) h = ((g - b) / delta + (g < b ? 6 : 0)) / 6;
    else if (max === g) h = ((b - r) / delta + 2) / 6;
    else h = ((r - g) / delta + 4) / 6;
  }
  l = tint < 0 ? l * (1 + tint) : 1 - (1 - l) * (1 - tint);
  l = Math.max(0, Math.min(1, l));
  if (s === 0) {
    const gray = Math.round(l * 255);
    return rgbToHex([gray, gray, gray]);
  }
  const hueToRgb = (p, q, t) => {
    let value = t;
    if (value < 0) value += 1;
    if (value > 1) value -= 1;
    if (value < 1 / 6) return p + (q - p) * 6 * value;
    if (value < 1 / 2) return q;
    if (value < 2 / 3) return p + (q - p) * (2 / 3 - value) * 6;
    return p;
  };
  const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  const p = 2 * l - q;
  return rgbToHex([
    hueToRgb(p, q, h + 1 / 3) * 255,
    hueToRgb(p, q, h) * 255,
    hueToRgb(p, q, h - 1 / 3) * 255,
  ]);
}

export function resolveColor(color, palette) {
  if (!color) return null;
  const theme = palette && palette.length ? palette : DEFAULT_THEME;
  if (color.auto && color.auto !== '0' && color.auto !== 'false') return { rgb: '#000000' };
  if (color.rgb) {
    const hex = String(color.rgb).replace('#', '');
    const clean = hex.length >= 6 ? hex.slice(-6) : hex.padStart(6, '0');
    if (/^[0-9A-Fa-f]{6}$/.test(clean)) {
      const tint = Number(color.tint) || 0;
      return { rgb: `#${tint ? applyTint(clean, tint) : clean.toUpperCase()}` };
    }
  }
  if (color.theme != null) {
    const base = theme[Number(color.theme)] || theme[0];
    const tint = Number(color.tint) || 0;
    return { rgb: tint ? `#${applyTint(base, tint)}` : base };
  }
  if (color.indexed != null) {
    const index = Number(color.indexed);
    const hex = INDEXED_COLORS[index < 0 || index >= INDEXED_COLORS.length
      ? 1 : index];
    return { rgb: `#${hex}` };
  }
  return null;
}

export function univerStyleForXf(index, tables, palette) {
  const xfs = tables && tables.cellXfs ? tables.cellXfs : [];
  const xf = xfs[index];
  if (!xf) return null;
  const base = (tables.cellStyleXfs && tables.cellStyleXfs[xf.xfId || 0]) || null;
  const idFor = (key) => (xf[key] != null ? xf[key] : (base ? base[key] : undefined));

  const style = {};
  const font = tables.fonts ? tables.fonts[idFor('fontId')] : null;
  if (font) {
    if (font.name) style.ff = font.name;
    if (Number.isFinite(font.size) && font.size > 0) style.fs = font.size;
    if (font.bold) style.bl = 1;
    if (font.italic) style.it = 1;
    if (font.underline) style.ul = { s: 1 };
    if (font.strike) style.st = { s: 1 };
    if (font.vertAlign === 'superscript') style.va = 3;
    else if (font.vertAlign === 'subscript') style.va = 2;
    const color = resolveColor(font.color, palette);
    if (color) style.cl = color;
  }

  const fill = tables.fills ? tables.fills[idFor('fillId')] : null;
  if (fill && fill.patternType && fill.patternType !== 'none' &&
      fill.patternType !== 'gray125') {
    const foreground = resolveColor(fill.fgColor, palette);
    if (foreground) style.bg = foreground;
    else {
      const background = resolveColor(fill.bgColor, palette);
      if (background) style.bg = background;
    }
  }

  const border = tables.borders ? tables.borders[idFor('borderId')] : null;
  if (border) {
    const mapped = {};
    const side = (univerKey, value) => {
      if (!value || !BORDER_STYLE_TYPES[value.style]) return;
      mapped[univerKey] = {
        s: BORDER_STYLE_TYPES[value.style],
        cl: resolveColor(value.color, palette) || { rgb: '#000000' },
      };
    };
    side('l', border.left);
    side('r', border.right);
    side('t', border.top);
    side('b', border.bottom);
    if (Object.keys(mapped).length) style.bd = mapped;
  }

  const alignment = xf.alignment || (base && base.alignment) || null;
  if (alignment) {
    const horizontal = HORIZONTAL_ALIGN[alignment.horizontal];
    if (horizontal) style.ht = horizontal;
    const vertical = VERTICAL_ALIGN[alignment.vertical];
    if (vertical) style.vt = vertical;
    if (alignment.wrapText) style.tb = WRAP;
    // Excel stores counter-clockwise degrees; >90 means vertical text and is
    // left unmapped rather than guessed.
    if (Number.isFinite(alignment.textRotation) &&
        alignment.textRotation > 0 && alignment.textRotation <= 90)
      style.tr = { a: alignment.textRotation };
  }

  return Object.keys(style).length ? style : null;
}

export { DEFAULT_THEME, INDEXED_COLORS, BORDER_STYLE_TYPES };
