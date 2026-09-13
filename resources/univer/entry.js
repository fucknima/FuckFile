import { createUniver, LocaleType, mergeLocales } from '@univerjs/presets';
import { UniverSheetsCorePreset } from '@univerjs/preset-sheets-core';
import sheetsCoreZhCN from '@univerjs/preset-sheets-core/locales/zh-CN';
import '@univerjs/preset-sheets-core/lib/index.css';

const MAX_NONEMPTY_CELLS = 1500000;
const MAX_ROWS = 1048576;
const MAX_COLUMNS = 16384;
const MIN_ZOOM = 0.25;
const MAX_ZOOM = 4;
const ROW_HEADER_WIDTH = 46;
const COLUMN_HEADER_HEIGHT = 20;

let univerAPI = null;
let activeWorkbook = null;
let currentDocumentName = '电子表格';
let lastStateJSON = '';
let stateTimer = null;
let pinchState = null;
let panState = null;
let momentumFrame = 0;
let scrollFrame = 0;
let pendingScrollX = 0;
let pendingScrollY = 0;
let sheetMenuVisible = false;

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
    rowHeader: { width: ROW_HEADER_WIDTH, hidden: 0 },
    columnHeader: { height: COLUMN_HEADER_HEIGHT, hidden: 0 },
    selections: [],
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
    appVersion: 'FuckFile-Univer-Viewer-3',
    locale: LocaleType.ZH_CN,
    styles: {},
    sheets,
    resources: [{ name: 'SHEET_NUMFMT_PLUGIN', data: '{"model":{},"refModel":[]}' }],
  };
}

function activeSheet() {
  return activeWorkbook?.getActiveSheet?.() || null;
}

function sheetId(sheet) {
  return sheet?.getSheetId?.() || null;
}

function sheetName(sheet) {
  return sheet?.getSheetName?.() || sheet?.getName?.() || '工作表';
}

async function enforceViewerMode(workbook = activeWorkbook) {
  if (!workbook) return;
  const sheets = workbook.getSheets?.() || [];
  await Promise.all(sheets.map(async (sheet) => {
    try {
      const permission = sheet.getWorksheetPermission?.();
      if (permission?.setReadOnly) await permission.setReadOnly();
    } catch (error) {
      console.warn('Failed to mark sheet read-only', error);
    }
  }));

  try { workbook.disableSelection?.(); } catch (_) {}
  try { workbook.transparentSelection?.(); } catch (_) {}
  try { await workbook.endEditingAsync?.(false); } catch (_) {}
  const focused = document.activeElement;
  if (focused && focused !== document.body && focused !== document.documentElement) {
    try { focused.blur?.(); } catch (_) {}
  }
}

function clampZoom(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) return 1;
  return Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, numeric));
}

function updateZoomHUD() {
  const label = document.getElementById('ff-zoom-value');
  const sheet = activeSheet();
  const zoom = clampZoom(sheet?.getZoom?.() || 1);
  if (label) label.textContent = `${Math.round(zoom * 100)}%`;
}

function setActiveZoom(value, emit = false) {
  const sheet = activeSheet();
  if (!sheet?.zoom) return null;
  const zoom = clampZoom(value);
  try {
    sheet.zoom(zoom);
    updateZoomHUD();
    if (emit) emitState(true);
    return zoom;
  } catch (_) {
    return null;
  }
}

function closeSheetMenu() {
  sheetMenuVisible = false;
  document.getElementById('ff-sheet-menu')?.classList.add('ff-hidden');
  document.getElementById('ff-sheet-button')?.setAttribute('aria-expanded', 'false');
}

function refreshSheetHUD() {
  const button = document.getElementById('ff-sheet-button');
  const menu = document.getElementById('ff-sheet-menu');
  if (!button || !menu || !activeWorkbook) return;

  const sheets = activeWorkbook.getSheets?.() || [];
  const current = activeSheet();
  button.textContent = sheetName(current);
  button.disabled = sheets.length <= 1;
  button.setAttribute('aria-label', sheets.length > 1 ? '切换工作表' : '当前工作表');

  menu.textContent = '';
  for (const sheet of sheets) {
    const item = document.createElement('button');
    item.type = 'button';
    item.className = 'ff-sheet-menu-item';
    if (sheetId(sheet) === sheetId(current)) item.classList.add('ff-active');
    item.textContent = sheetName(sheet);
    item.addEventListener('click', async () => {
      try {
        activeWorkbook.setActiveSheet?.(sheet);
        await enforceViewerMode();
        refreshSheetHUD();
        updateZoomHUD();
        emitState(true);
      } finally {
        closeSheetMenu();
      }
    });
    menu.appendChild(item);
  }
}

function appContentPoint(clientX, clientY) {
  const app = document.getElementById('app');
  const rect = app?.getBoundingClientRect?.();
  if (!rect) return { x: 0, y: 0 };
  return {
    x: Math.max(0, clientX - rect.left - ROW_HEADER_WIDTH),
    y: Math.max(0, clientY - rect.top - COLUMN_HEADER_HEIGHT),
  };
}

function appViewportCenter() {
  const app = document.getElementById('app');
  const rect = app?.getBoundingClientRect?.();
  if (!rect) return { x: 0, y: 0 };
  return {
    x: rect.left + ROW_HEADER_WIDTH + Math.max(0, rect.width - ROW_HEADER_WIDTH) / 2,
    y: rect.top + COLUMN_HEADER_HEIGHT + Math.max(0, rect.height - COLUMN_HEADER_HEIGHT) / 2,
  };
}

function touchCenter(touches) {
  if (!touches?.length) return { x: 0, y: 0 };
  let x = 0;
  let y = 0;
  for (let i = 0; i < touches.length; i++) {
    x += touches[i].clientX;
    y += touches[i].clientY;
  }
  return { x: x / touches.length, y: y / touches.length };
}

function dispatchSheetWheel(deltaX, deltaY, clientX, clientY) {
  const app = document.getElementById('app');
  if (!app) return;
  const target = document.elementFromPoint(clientX, clientY) || app;
  try {
    target.dispatchEvent(new WheelEvent('wheel', {
      bubbles: true,
      cancelable: true,
      deltaMode: 0,
      deltaX,
      deltaY,
      clientX,
      clientY,
    }));
  } catch (_) {}
}

function applyRelativeScroll(deltaX, deltaY, clientX = 0, clientY = 0) {
  const dx = Number(deltaX) || 0;
  const dy = Number(deltaY) || 0;
  if (Math.abs(dx) < 0.01 && Math.abs(dy) < 0.01) return true;

  try {
    const result = univerAPI?.executeCommand?.('sheet.command.set-scroll-relative', {
      offsetX: dx,
      offsetY: dy,
    });
    if (result !== undefined) {
      if (result?.catch) result.catch(() => {});
      return result !== false;
    }
  } catch (_) {}

  // Very old Univer builds can miss the facade command. Wheel events still
  // enter Univer's own pixel-scroll pipeline, so this fallback remains smooth
  // and never falls back to row/column stepping.
  const center = appViewportCenter();
  dispatchSheetWheel(dx, dy, clientX || center.x, clientY || center.y);
  return true;
}

function flushPendingScroll() {
  if (scrollFrame) cancelAnimationFrame(scrollFrame);
  scrollFrame = 0;
  const dx = pendingScrollX;
  const dy = pendingScrollY;
  pendingScrollX = 0;
  pendingScrollY = 0;
  if (dx || dy) applyRelativeScroll(dx, dy);
}

function queueRelativeScroll(deltaX, deltaY) {
  pendingScrollX += Number(deltaX) || 0;
  pendingScrollY += Number(deltaY) || 0;
  if (scrollFrame) return;
  scrollFrame = requestAnimationFrame(() => {
    scrollFrame = 0;
    const dx = pendingScrollX;
    const dy = pendingScrollY;
    pendingScrollX = 0;
    pendingScrollY = 0;
    applyRelativeScroll(dx, dy);
  });
}

function zoomAroundPoint(value, clientX, clientY, emit = false) {
  const sheet = activeSheet();
  if (!sheet?.zoom) return null;
  const oldZoom = clampZoom(sheet.getZoom?.() || 1);
  const newZoom = clampZoom(value);
  if (Math.abs(newZoom - oldZoom) < 0.0005) return oldZoom;

  const point = appContentPoint(clientX, clientY);
  const applied = setActiveZoom(newZoom, false);
  if (applied == null) return null;

  const ratio = applied / oldZoom;
  queueRelativeScroll(point.x * (ratio - 1), point.y * (ratio - 1));
  if (emit) {
    flushPendingScroll();
    emitState(true);
  }
  return applied;
}

function zoomAroundViewportCenter(value, emit = false) {
  const center = appViewportCenter();
  return zoomAroundPoint(value, center.x, center.y, emit);
}

function installViewerToolbar() {
  const sheetButton = document.getElementById('ff-sheet-button');
  const menu = document.getElementById('ff-sheet-menu');
  const zoomOut = document.getElementById('ff-zoom-out');
  const zoomValue = document.getElementById('ff-zoom-value');
  const zoomIn = document.getElementById('ff-zoom-in');

  sheetButton?.addEventListener('click', (event) => {
    event.stopPropagation();
    if (sheetButton.disabled) return;
    sheetMenuVisible = !sheetMenuVisible;
    menu?.classList.toggle('ff-hidden', !sheetMenuVisible);
    sheetButton.setAttribute('aria-expanded', sheetMenuVisible ? 'true' : 'false');
  });
  zoomOut?.addEventListener('click', () => {
    const current = activeSheet()?.getZoom?.() || 1;
    zoomAroundViewportCenter(current - 0.1, true);
  });
  zoomIn?.addEventListener('click', () => {
    const current = activeSheet()?.getZoom?.() || 1;
    zoomAroundViewportCenter(current + 0.1, true);
  });
  zoomValue?.addEventListener('click', () => zoomAroundViewportCenter(1, true));

  document.addEventListener('click', (event) => {
    if (!sheetMenuVisible) return;
    if (menu?.contains(event.target) || sheetButton?.contains(event.target)) return;
    closeSheetMenu();
  });
}

function forceEndEditing() {
  const focused = document.activeElement;
  const app = document.getElementById('app');
  if (focused && app?.contains(focused)) {
    try { focused.blur?.(); } catch (_) {}
  }
  try { void activeWorkbook?.endEditingAsync?.(false); } catch (_) {}
}

function installFocusGuards() {
  const app = document.getElementById('app');
  if (!app) return;

  document.addEventListener('focusin', (event) => {
    if (!app.contains(event.target)) return;
    forceEndEditing();
  }, true);

  const suppress = (event) => {
    if (!app.contains(event.target)) return;
    if (event.cancelable) event.preventDefault();
    event.stopImmediatePropagation();
    forceEndEditing();
  };
  document.addEventListener('beforeinput', suppress, true);
  document.addEventListener('dblclick', suppress, true);
  document.addEventListener('contextmenu', suppress, true);
  document.addEventListener('selectstart', suppress, true);
  document.addEventListener('dragstart', suppress, true);
}

function touchDistance(touches) {
  if (!touches || touches.length < 2) return 0;
  const dx = touches[0].clientX - touches[1].clientX;
  const dy = touches[0].clientY - touches[1].clientY;
  return Math.hypot(dx, dy);
}

function stopMomentum() {
  if (momentumFrame) cancelAnimationFrame(momentumFrame);
  momentumFrame = 0;
}

function beginPan(touch) {
  if (!touch) return null;
  return {
    lastX: touch.clientX,
    lastY: touch.clientY,
    lastTime: performance.now(),
    velocityX: 0,
    velocityY: 0,
  };
}

function beginPinch(touches) {
  const distance = touchDistance(touches);
  const sheet = activeSheet();
  if (!sheet || distance <= 0) return null;
  const center = touchCenter(touches);
  const zoom = clampZoom(sheet.getZoom?.() || 1);
  return {
    distance,
    initialZoom: zoom,
    currentZoom: zoom,
    centerX: center.x,
    centerY: center.y,
  };
}

function updatePinch(touches) {
  if (!pinchState) pinchState = beginPinch(touches);
  if (!pinchState) return;

  const distance = touchDistance(touches);
  if (distance <= 0) return;
  const center = touchCenter(touches);
  const newZoom = clampZoom(pinchState.initialZoom * distance / pinchState.distance);
  const oldZoom = pinchState.currentZoom;
  const oldPoint = appContentPoint(pinchState.centerX, pinchState.centerY);
  const newPoint = appContentPoint(center.x, center.y);

  if (Math.abs(newZoom - oldZoom) >= 0.0005) {
    const applied = setActiveZoom(newZoom, false);
    if (applied != null) {
      const ratio = applied / oldZoom;
      // Zoom itself is top-left anchored. Compensate the scroll so the sheet
      // coordinate originally under the fingers stays under the moving pinch
      // centre, just like UIScrollView/Quick Look.
      queueRelativeScroll(
        oldPoint.x * ratio - newPoint.x,
        oldPoint.y * ratio - newPoint.y
      );
      pinchState.currentZoom = applied;
    }
  } else {
    // Two-finger translation without a meaningful scale change should still
    // move the sheet with the fingers instead of feeling stuck.
    queueRelativeScroll(oldPoint.x - newPoint.x, oldPoint.y - newPoint.y);
  }
  pinchState.centerX = center.x;
  pinchState.centerY = center.y;
}

function installViewerGestures() {
  const app = document.getElementById('app');
  if (!app) return;

  const consume = (event) => {
    if (event.cancelable) event.preventDefault();
    event.stopImmediatePropagation();
  };

  app.addEventListener('touchstart', (event) => {
    stopMomentum();
    flushPendingScroll();
    forceEndEditing();

    if (event.touches.length >= 2) {
      pinchState = beginPinch(event.touches);
      panState = null;
      consume(event);
      return;
    }

    if (event.touches.length === 1) {
      panState = beginPan(event.touches[0]);
      pinchState = null;
      consume(event);
    }
  }, { capture: true, passive: false });

  app.addEventListener('touchmove', (event) => {
    forceEndEditing();

    if (event.touches.length >= 2) {
      updatePinch(event.touches);
      panState = null;
      consume(event);
      return;
    }

    if (event.touches.length === 1 && panState) {
      const touch = event.touches[0];
      const now = performance.now();
      const dx = panState.lastX - touch.clientX;
      const dy = panState.lastY - touch.clientY;
      const dt = Math.max(8, now - panState.lastTime);
      panState.velocityX = panState.velocityX * 0.62 + (dx / dt * 16) * 0.38;
      panState.velocityY = panState.velocityY * 0.62 + (dy / dt * 16) * 0.38;
      panState.lastX = touch.clientX;
      panState.lastY = touch.clientY;
      panState.lastTime = now;

      // Pixel deltas go straight into Univer's relative-scroll pipeline. Do
      // not use scrollToCell here: that is exactly what caused one-row/one-col
      // stepping in the previous viewer implementation.
      queueRelativeScroll(dx, dy);
      consume(event);
    }
  }, { capture: true, passive: false });

  const finish = (event) => {
    forceEndEditing();

    if (pinchState && event.touches.length < 2) {
      flushPendingScroll();
      pinchState = null;
      emitState(true);
      if (event.touches.length === 1) {
        // Seamlessly continue as a one-finger pan when one finger is lifted
        // after a pinch; iOS viewers do not require a fresh touch-down.
        panState = beginPan(event.touches[0]);
      } else {
        panState = null;
      }
      consume(event);
      return;
    }

    if (panState && event.touches.length === 0) {
      flushPendingScroll();
      const final = panState;
      panState = null;
      emitState(true);

      if (Math.abs(final.velocityX) > 0.7 || Math.abs(final.velocityY) > 0.7) {
        let vx = final.velocityX;
        let vy = final.velocityY;
        const coast = () => {
          vx *= 0.92;
          vy *= 0.92;
          if (Math.abs(vx) < 0.18 && Math.abs(vy) < 0.18) {
            momentumFrame = 0;
            emitState(true);
            return;
          }
          applyRelativeScroll(vx, vy);
          momentumFrame = requestAnimationFrame(coast);
        };
        momentumFrame = requestAnimationFrame(coast);
      }
      consume(event);
    }
  };

  app.addEventListener('touchend', finish, { capture: true, passive: false });
  app.addEventListener('touchcancel', finish, { capture: true, passive: false });
}

function captureState() {
  try {
    if (!activeWorkbook) return null;
    const sheet = activeSheet();
    if (!sheet) return null;
    const scroll = sheet.getScrollState?.() || {};
    return {
      sheetId: sheetId(sheet),
      zoom: Number(sheet.getZoom?.() || 1),
      row: Number(scroll.sheetViewStartRow || 0),
      column: Number(scroll.sheetViewStartColumn || 0),
      offsetX: Number(scroll.offsetX || 0),
      offsetY: Number(scroll.offsetY || 0),
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

function restoreExactScroll(sheet, state) {
  const unitId = activeWorkbook?.getId?.() || activeWorkbook?.id;
  const subUnitId = sheetId(sheet);
  if (!unitId || !subUnitId) return false;
  try {
    const result = univerAPI?.syncExecuteCommand?.('sheet.command.scroll-view', {
      unitId,
      sheetId: subUnitId,
      sheetViewStartRow: Math.max(0, Number(state.row) || 0),
      sheetViewStartColumn: Math.max(0, Number(state.column) || 0),
      offsetX: Number(state.offsetX) || 0,
      offsetY: Number(state.offsetY) || 0,
      duration: 0,
    });
    return result !== false && result !== undefined;
  } catch (_) {
    return false;
  }
}

function restoreState(state) {
  if (!state || !activeWorkbook) return;
  setTimeout(async () => {
    try {
      const sheets = activeWorkbook.getSheets?.() || [];
      const sheet = sheets.find((item) => sheetId(item) === state.sheetId) || sheets[0];
      if (!sheet) return;
      activeWorkbook.setActiveSheet?.(sheet);
      await enforceViewerMode();
      if (Number.isFinite(state.zoom)) setActiveZoom(state.zoom, false);
      if (!restoreExactScroll(sheet, state) &&
          Number.isFinite(state.row) && Number.isFinite(state.column)) {
        sheet.scrollToCell?.(Math.max(0, state.row | 0), Math.max(0, state.column | 0), 0);
      }
      refreshSheetHUD();
      updateZoomHUD();
      emitState(true);
    } catch (_) {}
  }, 180);
}

async function openDocument(payload = {}) {
  currentDocumentName = payload.name || '电子表格';
  setStatus(`正在打开 ${currentDocumentName}…`);
  try {
    if (!window.XLSX?.read) throw new Error('SheetJS 解析器未加载。');

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
    await enforceViewerMode();
    refreshSheetHUD();
    updateZoomHUD();
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

// WKWebView cannot bridge a Promise returned by evaluateJavaScript. Keep this
// synchronous wrapper as the native entry point and run parsing asynchronously.
function openDocumentForNative(payload = {}) {
  void openDocument(payload);
  return null;
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
        formulaBar: false,
        footer: false,
        contextMenu: false,
        disableAutoFocus: true,
      })],
    });
    univerAPI = result.univerAPI;
    window.FFSpreadsheet = { open: openDocumentForNative, captureState };
    installViewerToolbar();
    installFocusGuards();
    installViewerGestures();
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
  stopMomentum();
  flushPendingScroll();
  pinchState = null;
  panState = null;
});

boot();
