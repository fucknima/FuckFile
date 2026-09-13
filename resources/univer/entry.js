import { createUniver, LocaleType, mergeLocales } from '@univerjs/presets';
import { UniverSheetsCorePreset } from '@univerjs/preset-sheets-core';
import sheetsCoreZhCN from '@univerjs/preset-sheets-core/locales/zh-CN';
import '@univerjs/preset-sheets-core/lib/index.css';

const MAX_NONEMPTY_CELLS = 1500000;
const MAX_ROWS = 1048576;
const MAX_COLUMNS = 16384;

let univerAPI = null;
let activeWorkbook = null;
let currentDocumentName = '电子表格';
let lastStateJSON = '';
let stateTimer = null;

function bridge(message) {
  try {
    window.webkit?.messageHandlers?.ffSheet?.postMessage(message);
  } catch (_) {}
}

function setStatus(text, error = false) {
  const box = document.getElementById('ff-status');
  const label = document.getElementById('ff-status-text');
  if (!box || !label) return;
  label.textContent = text || '';
  box.classList.toggle('ff-error', !!error);
  box.classList.remove('ff-hidden');
}

function hideStatus() {
  document.getElementById('ff-status')?.classList.add('ff-hidden');
}

function safeSheetId(index) {
  return `ff-sheet-${index + 1}`;
}

function normalizedCellValue(cell) {
  const result = {};
  if (!cell || typeof cell !== 'object') return result;

  if (typeof cell.f === 'string' && cell.f.length) {
    result.f = cell.f.startsWith('=') ? cell.f : `=${cell.f}`;
  }

  if (cell.v !== undefined && cell.v !== null) {
    if (cell.t === 'e') {
      result.v = cell.w != null ? String(cell.w) : String(cell.v);
    } else if (cell.v instanceof Date) {
      result.v = cell.v.toISOString();
    } else if (typeof cell.v === 'string' || typeof cell.v === 'number' ||
               typeof cell.v === 'boolean') {
      result.v = cell.v;
    } else {
      result.v = String(cell.v);
    }
  }

  if (typeof cell.z === 'string' && cell.z.length && cell.z !== 'General') {
    result.s = { n: { pattern: cell.z } };
  }
  return result;
}

function buildSheetData(sheet, sheetName, sheetId, hidden) {
  const cellData = {};
  let maxRow = 0;
  let maxColumn = 0;
  let cellCount = 0;

  for (const address of Object.keys(sheet)) {
    if (address[0] === '!') continue;
    let decoded;
    try { decoded = XLSX.utils.decode_cell(address); } catch (_) { continue; }
    if (!decoded || decoded.r < 0 || decoded.c < 0 ||
        decoded.r >= MAX_ROWS || decoded.c >= MAX_COLUMNS) continue;

    const source = sheet[address];
    if (!source) continue;
    const value = normalizedCellValue(source);
    if (!Object.keys(value).length) continue;

    if (++cellCount > MAX_NONEMPTY_CELLS) {
      throw new Error(`工作表“${sheetName}”非空单元格超过 ${MAX_NONEMPTY_CELLS.toLocaleString()} 个，已停止加载以保护内存。`);
    }
    if (!cellData[decoded.r]) cellData[decoded.r] = {};
    cellData[decoded.r][decoded.c] = value;
    maxRow = Math.max(maxRow, decoded.r);
    maxColumn = Math.max(maxColumn, decoded.c);
  }

  const mergeData = [];
  for (const merge of sheet['!merges'] || []) {
    if (!merge?.s || !merge?.e) continue;
    const startRow = Math.max(0, Math.min(MAX_ROWS - 1, merge.s.r | 0));
    const endRow = Math.max(startRow, Math.min(MAX_ROWS - 1, merge.e.r | 0));
    const startColumn = Math.max(0, Math.min(MAX_COLUMNS - 1, merge.s.c | 0));
    const endColumn = Math.max(startColumn, Math.min(MAX_COLUMNS - 1, merge.e.c | 0));
    mergeData.push({ startRow, endRow, startColumn, endColumn });
    maxRow = Math.max(maxRow, endRow);
    maxColumn = Math.max(maxColumn, endColumn);
  }

  const rowData = {};
  const sourceRows = sheet['!rows'] || [];
  for (let i = 0; i < sourceRows.length && i < MAX_ROWS; i++) {
    const row = sourceRows[i];
    if (!row) continue;
    const height = Number.isFinite(row.hpx) ? row.hpx :
      (Number.isFinite(row.hpt) ? row.hpt * 96 / 72 : undefined);
    const record = {};
    if (Number.isFinite(height) && height > 0) record.h = Math.max(5, Math.min(600, height));
    if (row.hidden) record.hd = 1;
    if (Object.keys(record).length) rowData[i] = record;
    maxRow = Math.max(maxRow, i);
  }

  const columnData = {};
  const sourceColumns = sheet['!cols'] || [];
  for (let i = 0; i < sourceColumns.length && i < MAX_COLUMNS; i++) {
    const column = sourceColumns[i];
    if (!column) continue;
    let width;
    if (Number.isFinite(column.wpx)) width = column.wpx;
    else if (Number.isFinite(column.wch)) width = column.wch * 7 + 5;
    else if (Number.isFinite(column.width)) width = column.width * 7 + 5;
    const record = {};
    if (Number.isFinite(width) && width > 0) record.w = Math.max(20, Math.min(800, width));
    if (column.hidden) record.hd = 1;
    if (Object.keys(record).length) columnData[i] = record;
    maxColumn = Math.max(maxColumn, i);
  }

  return {
    type: 0,
    id: sheetId,
    name: sheetName || 'Sheet',
    tabColor: '',
    hidden: hidden ? 1 : 0,
    rowCount: Math.max(100, Math.min(MAX_ROWS, maxRow + 50)),
    columnCount: Math.max(26, Math.min(MAX_COLUMNS, maxColumn + 10)),
    zoomRatio: 1,
    freeze: { xSplit: 0, ySplit: 0, startRow: -1, startColumn: -1 },
    scrollTop: 0,
    scrollLeft: 0,
    defaultColumnWidth: 73,
    defaultRowHeight: 19,
    mergeData,
    hideRow: [],
    hideColumn: [],
    cellData,
    rowData,
    columnData,
    status: 0,
    showGridlines: 1,
    rowHeader: { width: 46, hidden: 0 },
    columnHeader: { height: 20, hidden: 0 },
    selections: ['A1'],
    rightToLeft: 0,
  };
}

function convertWorkbook(book, name) {
  if (!book || !Array.isArray(book.SheetNames) || !book.SheetNames.length) {
    throw new Error('文件中没有可读取的工作表。');
  }

  const sheetOrder = [];
  const sheets = {};
  const metadata = book.Workbook?.Sheets || [];

  book.SheetNames.forEach((sheetName, index) => {
    const id = safeSheetId(index);
    const source = book.Sheets[sheetName];
    if (!source) return;
    sheetOrder.push(id);
    sheets[id] = buildSheetData(source, sheetName, id, Number(metadata[index]?.Hidden || 0) !== 0);
  });

  if (!sheetOrder.length) throw new Error('工作簿中的工作表均无法读取。');

  return {
    id: `ff-workbook-${Date.now().toString(36)}`,
    sheetOrder,
    name: name || 'Spreadsheet',
    appVersion: 'FuckFile-Univer-1',
    locale: LocaleType.ZH_CN,
    styles: {},
    sheets,
    resources: [{ name: 'SHEET_NUMFMT_PLUGIN', data: '{"model":{},"refModel":[]}' }],
  };
}

async function makeReadOnly(workbook) {
  const sheets = workbook?.getSheets?.() || [];
  await Promise.all(sheets.map(async (sheet) => {
    try {
      const permission = sheet.getWorksheetPermission?.();
      if (permission?.setReadOnly) await permission.setReadOnly();
    } catch (error) {
      console.warn('Failed to mark sheet read-only', error);
    }
  }));
}

function captureState() {
  try {
    if (!activeWorkbook) return null;
    const sheet = activeWorkbook.getActiveSheet?.();
    if (!sheet) return null;
    const scroll = sheet.getScrollState?.() || {};
    const activeRange = activeWorkbook.getActiveRange?.();
    return {
      sheetId: sheet.getSheetId?.() || null,
      zoom: Number(sheet.getZoom?.() || 1),
      row: Number(scroll.sheetViewStartRow || 0),
      column: Number(scroll.sheetViewStartColumn || 0),
      offsetX: Number(scroll.offsetX || 0),
      offsetY: Number(scroll.offsetY || 0),
      range: activeRange?.getA1Notation?.() || null,
    };
  } catch (_) {
    return null;
  }
}

function emitState(force = false) {
  const state = captureState();
  if (!state) return;
  const encoded = JSON.stringify(state);
  if (!force && encoded === lastStateJSON) return;
  lastStateJSON = encoded;
  bridge({ type: 'state', state });
}

function restoreState(state) {
  if (!state || !activeWorkbook) return;
  setTimeout(() => {
    try {
      const sheets = activeWorkbook.getSheets?.() || [];
      let sheet = sheets.find((item) => item.getSheetId?.() === state.sheetId) || sheets[0];
      if (!sheet) return;
      activeWorkbook.setActiveSheet?.(sheet);
      if (Number.isFinite(state.zoom)) sheet.zoom?.(Math.max(.25, Math.min(4, state.zoom)));
      if (Number.isFinite(state.row) && Number.isFinite(state.column))
        sheet.scrollToCell?.(Math.max(0, state.row | 0), Math.max(0, state.column | 0), 0);
      if (typeof state.range === 'string' && state.range.length) {
        try {
          const range = sheet.getRange?.(state.range);
          if (range) activeWorkbook.setActiveRange?.(range);
        } catch (_) {}
      }
      emitState(true);
    } catch (_) {}
  }, 180);
}

async function openDocument(payload = {}) {
  currentDocumentName = payload.name || '电子表格';
  setStatus(`正在打开 ${currentDocumentName}…`);
  try {
    if (!window.XLSX?.read) throw new Error('SheetJS 解析器未加载。');

    // WKURLSchemeHandler responses can surface as status 0 even when WebKit
    // delivered the custom-scheme body successfully. Treat only an explicit
    // HTTP-style error status as failure; arrayBuffer() is authoritative.
    const response = await fetch('ffsheet:///document', { cache: 'no-store' });
    if (response.status >= 400) throw new Error(`读取文件失败（${response.status}）`);
    const buffer = await response.arrayBuffer();
    if (!buffer || buffer.byteLength === 0) throw new Error('文件为空或无法读取。');
    const book = window.XLSX.read(buffer, {
      type: 'array',
      cellFormula: true,
      cellNF: true,
      cellStyles: true,
      cellText: true,
      cellDates: false,
      bookVBA: false,
      dense: false,
    });
    const data = convertWorkbook(book, currentDocumentName);

    if (activeWorkbook?.dispose) {
      try { activeWorkbook.dispose(); } catch (_) {}
    }
    activeWorkbook = univerAPI.createWorkbook(data);
    await makeReadOnly(activeWorkbook);
    restoreState(payload.state || null);

    hideStatus();
    bridge({ type: 'loaded', sheets: data.sheetOrder.length });
    emitState(true);
  } catch (error) {
    const message = error?.message || String(error || '未知错误');
    setStatus(message, true);
    bridge({ type: 'error', message });
  }
}

async function boot() {
  try {
    const result = createUniver({
      locale: LocaleType.ZH_CN,
      locales: { [LocaleType.ZH_CN]: mergeLocales(sheetsCoreZhCN) },
      presets: [UniverSheetsCorePreset({
        container: 'app',
        header: false,
        toolbar: false,
        formulaBar: true,
        footer: true,
        contextMenu: false,
        disableAutoFocus: true,
      })],
    });
    univerAPI = result.univerAPI;
    window.FFSpreadsheet = { open: openDocument, captureState };
    stateTimer = window.setInterval(() => emitState(false), 1200);
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) emitState(true);
    });
    bridge({ type: 'ready' });
  } catch (error) {
    const message = error?.message || String(error || 'Univer 初始化失败');
    setStatus(message, true);
    bridge({ type: 'error', message });
  }
}

window.addEventListener('beforeunload', () => {
  if (stateTimer) window.clearInterval(stateTimer);
});

boot();
