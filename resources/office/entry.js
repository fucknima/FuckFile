import { Ream } from 'reamkit';
import { renderAsync as renderDocxPreview } from 'docx-preview';
import { toMarkdown as odfToMarkdown } from '@mdgate/odf';
import { toMarkdown as rtfToMarkdown } from '@mdgate/rtf';
import { toMarkdown as pagesToMarkdown } from '@mdgate/pages';
import { toMarkdown as numbersToMarkdown } from '@mdgate/numbers';
import { toMarkdown as keynoteToMarkdown } from '@mdgate/keynote';
import { toMarkdown as wpsToMarkdown } from '@mdgate/wps';
import { marked } from 'marked';
import DOMPurify from 'dompurify';

const MIN_ZOOM = 0.25;
const MAX_ZOOM = 4.0;
const LEGACY_WORD = new Set(['doc', 'dot']);
const OOXML_WORD = new Set(['docx', 'docm', 'dotx', 'dotm']);
const VISUAL_WORD = new Set([...LEGACY_WORD, ...OOXML_WORD]);
const VISUAL_PRESENTATION = new Set([
  'ppt', 'pptx', 'pptm', 'pps', 'ppsx', 'ppsm', 'pot', 'potx', 'potm',
]);
const ODF = new Set(['odt', 'odp', 'ods', 'odg', 'fodt', 'fodp', 'fods', 'ott', 'otp', 'ots']);
const IWORK_PAGES = new Set(['pages']);
const IWORK_NUMBERS = new Set(['numbers']);
const IWORK_KEYNOTE = new Set(['key']);
const WPS = new Set(['wps', 'wpt', 'et', 'ett', 'dps', 'dpt']);

let zoom = 1;
let autoFitActive = true;
let currentName = '办公文档';
let currentExtension = '';
let lastStateJSON = '';
let stateTimer = 0;
let pinch = null;
let renderGeneration = 0;
let activeFrame = null;

function bridge(message) {
  try { window.webkit?.messageHandlers?.ffOffice?.postMessage(message); } catch (_) {}
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

function clampZoom(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) return 1;
  return Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, numeric));
}

function viewport() { return document.getElementById('ff-viewport'); }
function host() { return document.getElementById('ff-document-host'); }

function layoutControl() {
  return window.FFOfficeLayout || null;
}

// The shim centers a canvas that is narrower than the viewport by shifting
// #ff-document-host; zoom anchoring has to subtract/add that shift.
function layoutOffsetX() {
  const offset = Number.parseFloat(host()?.style.left);
  return Number.isFinite(offset) ? offset : 0;
}

function centeredOffsetFor(value) {
  const view = viewport();
  const surface = host();
  const base = surface?.offsetWidth || 0;
  if (!view || !(base > 0)) return 0;
  const scaled = base * value;
  return scaled < view.clientWidth ? Math.round((view.clientWidth - scaled) / 2) : 0;
}

// Called only from user zoom gestures/buttons: the shim must stop re-fitting
// the document once the user has chosen a zoom of their own.
function disableAutoFit() {
  autoFitActive = false;
  layoutControl()?.setAutoFit(false);
}

function updateZoomHUD() {
  const label = document.getElementById('ff-zoom-value');
  if (label) label.textContent = `${Math.round(zoom * 100)}%`;
}

function applyZoom(value) {
  zoom = clampZoom(value);
  const surface = host();
  if (surface) surface.style.zoom = String(zoom);
  updateZoomHUD();
}

function setZoom(next, anchor = null, emit = false) {
  const view = viewport();
  const surface = host();
  if (!view || !surface) return zoom;
  cancelPendingScrollRestore();

  const oldZoom = zoom;
  const newZoom = clampZoom(next);
  if (Math.abs(newZoom - oldZoom) < 0.0005) return zoom;

  let anchorX = view.clientWidth / 2;
  let anchorY = view.clientHeight / 2;
  if (anchor && Number.isFinite(anchor.x) && Number.isFinite(anchor.y)) {
    anchorX = anchor.x;
    anchorY = anchor.y;
  }
  const contentX = (view.scrollLeft + anchorX - layoutOffsetX()) / oldZoom;
  const contentY = (view.scrollTop + anchorY) / oldZoom;

  applyZoom(newZoom);
  view.scrollLeft = Math.max(0, contentX * newZoom - anchorX + centeredOffsetFor(newZoom));
  view.scrollTop = Math.max(0, contentY * newZoom - anchorY);
  if (emit) emitState(true);
  return zoom;
}

function captureState() {
  const view = viewport();
  return {
    zoom,
    scrollX: Number(view?.scrollLeft || 0),
    scrollY: Number(view?.scrollTop || 0),
    autoFit: autoFitActive,
  };
}

function emitState(force = false) {
  const state = captureState();
  const encoded = JSON.stringify(state);
  if (!force && encoded === lastStateJSON) return;
  lastStateJSON = encoded;
  bridge({ type: 'state', state });
}

// Scrolling fires at display rate and every state message crosses the native
// bridge; one message per 150 ms is plenty for resume-position accuracy.
let scrollEmitTimer = 0;
function emitStateThrottled() {
  if (scrollEmitTimer) return;
  scrollEmitTimer = window.setTimeout(() => {
    scrollEmitTimer = 0;
    emitState(false);
  }, 150);
}

let restoreScrollToken = 0;

function cancelPendingScrollRestore() {
  restoreScrollToken += 1;
}

function restoreState(state) {
  const view = viewport();
  if (!view || !state) return;
  // While auto-fit is active the shim chooses the zoom from the measured
  // document; replaying a stale zoom would fight the fit.
  if (!autoFitActive && Number.isFinite(Number(state.zoom))) applyZoom(Number(state.zoom));

  // Images and drawings settle after the first layout, so an immediate scroll
  // restore can clamp to the top. Re-apply once the document has settled;
  // any user touch/scroll cancels the deferred pass so reading is never
  // yanked back.
  const token = ++restoreScrollToken;
  const applyScroll = () => {
    if (token !== restoreScrollToken) return;
    if (Number.isFinite(Number(state.scrollX))) view.scrollLeft = Math.max(0, Number(state.scrollX));
    if (Number.isFinite(Number(state.scrollY))) view.scrollTop = Math.max(0, Number(state.scrollY));
    emitState(true);
  };
  requestAnimationFrame(() => requestAnimationFrame(applyScroll));
  window.setTimeout(applyScroll, 450);
  window.setTimeout(applyScroll, 1200);
}

function fitToWidth() {
  cancelPendingScrollRestore();
  autoFitActive = true;
  layoutControl()?.setAutoFit(true);
}

// ---- In-document search -------------------------------------------------
// Hits are wrapped in <mark> nodes. Styles are inline because the search must
// also work for iframe-rendered documents (PPT/RTF/ODF), where host.css does
// not apply.

let searchHits = [];
let searchHitIndex = -1;
let searchQuery = '';

function searchRoot() {
  const frameBody = activeFrame?.contentDocument?.body;
  return frameBody || host();
}

function updateSearchCount() {
  const label = document.getElementById('ff-search-count');
  if (!label) return;
  if (searchHitIndex >= 0 && searchHits.length)
    label.textContent = `${searchHitIndex + 1}/${searchHits.length}`;
  else if (searchHits.length)
    label.textContent = String(searchHits.length);
  else
    label.textContent = searchQuery ? '0' : '';
}

function clearSearchHits() {
  for (const mark of searchHits) {
    const parent = mark.parentNode;
    if (!parent) continue;
    const doc = mark.ownerDocument || document;
    parent.replaceChild(doc.createTextNode(mark.textContent || ''), mark);
    parent.normalize();
  }
  searchHits = [];
  searchHitIndex = -1;
  searchQuery = '';
  updateSearchCount();
}

function buildSearchHits(query) {
  clearSearchHits();
  const root = searchRoot();
  if (!root || !query) return;
  searchQuery = query;
  const lower = query.toLocaleLowerCase();
  const doc = root.ownerDocument || document;
  const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      const parent = node.parentElement;
      if (!parent) return NodeFilter.FILTER_REJECT;
      const tag = parent.tagName;
      if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT')
        return NodeFilter.FILTER_REJECT;
      return String(node.nodeValue || '').toLocaleLowerCase().includes(lower)
        ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
    },
  });
  const nodes = [];
  while (walker.nextNode()) nodes.push(walker.currentNode);
  for (const node of nodes) {
    const text = String(node.nodeValue || '');
    const lowered = text.toLocaleLowerCase();
    let position = 0;
    let index = lowered.indexOf(lower);
    if (index < 0) continue;
    const fragment = doc.createDocumentFragment();
    while (index >= 0) {
      if (index > position) fragment.appendChild(doc.createTextNode(text.slice(position, index)));
      const mark = doc.createElement('mark');
      mark.className = 'ff-hit';
      mark.textContent = text.slice(index, index + query.length);
      mark.style.background = '#ffd60a';
      mark.style.color = '#111';
      mark.style.borderRadius = '2px';
      fragment.appendChild(mark);
      searchHits.push(mark);
      position = index + query.length;
      index = lowered.indexOf(lower, position);
    }
    if (position < text.length) fragment.appendChild(doc.createTextNode(text.slice(position)));
    node.parentNode?.replaceChild(fragment, node);
  }
  searchHitIndex = -1;
  updateSearchCount();
}

function searchHitRect(mark) {
  const rect = mark.getBoundingClientRect();
  const frame = activeFrame;
  const frameDoc = frame?.contentDocument;
  if (frame && frameDoc && frameDoc.contains(mark)) {
    // Inside an iframe: map into the parent viewport through the frame box,
    // which already carries the fixed-layout scale.
    const frameRect = frame.getBoundingClientRect();
    const scale = frame.clientWidth ? frameRect.width / frame.clientWidth : 1;
    return {
      left: frameRect.left + rect.left * scale,
      top: frameRect.top + rect.top * scale,
      width: rect.width * scale,
      height: rect.height * scale,
    };
  }
  return rect;
}

function scrollToSearchHit(mark) {
  const view = viewport();
  if (!view) return;
  const rect = searchHitRect(mark);
  const viewRect = view.getBoundingClientRect();
  view.scrollTop = Math.max(0, view.scrollTop + rect.top - viewRect.top - view.clientHeight * 0.3);
  view.scrollLeft = Math.max(0, view.scrollLeft + rect.left - viewRect.left - view.clientWidth * 0.2);
}

function stepSearch(direction) {
  const input = document.getElementById('ff-search-input');
  const query = String(input?.value || '').trim();
  if (!query) { clearSearchHits(); return; }
  if (!searchHits.length || searchQuery !== query) buildSearchHits(query);
  if (!searchHits.length) { updateSearchCount(); return; }
  const previous = searchHits[searchHitIndex];
  if (previous) {
    previous.style.outline = 'none';
    previous.style.outlineOffset = '0';
  }
  searchHitIndex = (searchHitIndex + direction + searchHits.length) % searchHits.length;
  const mark = searchHits[searchHitIndex];
  mark.style.outline = '2px solid #ff9f0a';
  mark.style.outlineOffset = '1px';
  scrollToSearchHit(mark);
  updateSearchCount();
  emitState(true);
}

function setSearchBarVisible(visible) {
  const bar = document.getElementById('ff-searchbar');
  const input = document.getElementById('ff-search-input');
  if (!bar) return;
  bar.classList.toggle('ff-hidden', !visible);
  if (visible) {
    try { input?.focus(); input?.select?.(); } catch (_) {}
    return;
  }
  clearSearchHits();
  if (input) input.value = '';
  try { input?.blur(); } catch (_) {}
}

function installSearch() {
  const toggle = document.getElementById('ff-search-toggle');
  const input = document.getElementById('ff-search-input');
  if (!toggle || !input) return;

  toggle.addEventListener('click', () => setSearchBarVisible(true));
  document.getElementById('ff-search-close')?.addEventListener('click',
    () => setSearchBarVisible(false));
  document.getElementById('ff-search-prev')?.addEventListener('click', () => {
    stepSearch(-1);
    try { input.focus(); } catch (_) {}
  });
  document.getElementById('ff-search-next')?.addEventListener('click', () => {
    stepSearch(1);
    try { input.focus(); } catch (_) {}
  });
  input.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      stepSearch(event.shiftKey ? -1 : 1);
    } else if (event.key === 'Escape') {
      setSearchBarVisible(false);
    }
  });
  input.addEventListener('search', () => { if (!input.value) clearSearchHits(); });
}

function extensionOf(name) {
  const clean = String(name || '').toLowerCase().split(/[?#]/)[0];
  const dot = clean.lastIndexOf('.');
  return dot >= 0 ? clean.slice(dot + 1) : '';
}

function labelForExtension(ext, structured) {
  if (VISUAL_WORD.has(ext) || ext === 'rtf' || ext === 'rtfd' || ext === 'odt' || ext === 'pages' || ext === 'wps' || ext === 'wpt')
    return structured ? '文档 · 结构化预览' : 'Word · 布局预览';
  if (VISUAL_PRESENTATION.has(ext) || ext === 'odp' || ext === 'key' || ext === 'dps' || ext === 'dpt')
    return structured ? '演示文稿 · 结构化预览' : 'PowerPoint · 布局预览';
  if (ext === 'numbers' || ext === 'et' || ext === 'ett' || ext === 'fods')
    return '表格 · 结构化预览';
  return structured ? '办公文档 · 结构化预览' : '办公文档 · 布局预览';
}

function setFormatLabel(text) {
  const label = document.getElementById('ff-format-label');
  if (label) label.textContent = text;
}

function resetSurface(modeClass) {
  const surface = host();
  if (!surface) throw new Error('文档显示区域不存在。');
  clearSearchHits();
  surface.textContent = '';
  surface.classList.remove('ff-word-layout', 'ff-frame-layout');
  if (modeClass) surface.classList.add(modeClass);
  surface.style.zoom = String(zoom);
  activeFrame = null;
  return surface;
}

function cleanGeneratedDocument(markup) {
  const parsed = new DOMParser().parseFromString(String(markup || ''), 'text/html');
  for (const node of parsed.querySelectorAll('script, object, embed, form, input, textarea, button, video, audio')) node.remove();
  for (const node of parsed.querySelectorAll('meta[http-equiv="Content-Security-Policy"]')) node.remove();

  const csp = parsed.createElement('meta');
  csp.setAttribute('http-equiv', 'Content-Security-Policy');
  csp.setAttribute('content', "default-src 'none'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src 'none'; object-src 'none'; frame-src 'none'; connect-src 'none'");
  parsed.head.prepend(csp);

  const guard = parsed.createElement('style');
  guard.textContent = 'html,body{overflow:visible!important}';
  parsed.head.append(guard);

  return DOMPurify.sanitize('<!doctype html>\n' + parsed.documentElement.outerHTML, {
    WHOLE_DOCUMENT: true,
    ADD_TAGS: ['style'],
    ADD_ATTR: ['xmlns', 'viewBox'],
    FORBID_TAGS: ['script', 'object', 'embed', 'form', 'input', 'textarea', 'button', 'video', 'audio'],
    FORBID_ATTR: ['srcset'],
  });
}

function markdownDocument(markdown) {
  const rendered = DOMPurify.sanitize(marked.parse(String(markdown || ''), {
    gfm: true,
    breaks: false,
  }), {
    FORBID_TAGS: ['script', 'iframe', 'object', 'embed', 'form', 'input', 'textarea', 'button'],
    FORBID_ATTR: ['srcset'],
  });
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>
    html,body{margin:0;padding:0;background:#fff;color:#1c1c1e;font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",Arial,sans-serif;overflow:visible}
    article{box-sizing:border-box;width:min(920px,100%);min-height:100vh;margin:0;padding:30px 32px 48px;line-height:1.58;overflow-wrap:anywhere;}
    h1,h2,h3,h4{line-height:1.28;margin-top:1.35em} table{width:100%;border-collapse:collapse;margin:14px 0;font-size:13px}th,td{border:1px solid rgba(60,60,67,.28);padding:7px 8px;vertical-align:top}pre{overflow:auto;padding:12px;border-radius:8px;background:#f2f2f7}code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}img{max-width:100%;height:auto}a{color:#007aff}
    @media(prefers-color-scheme:dark){html,body{background:#1c1c1e;color:#f2f2f7}pre{background:#2c2c2e}a{color:#64a8ff}}
  </style></head><body><article>${rendered}</article></body></html>`;
}

function relaxFrameClipping(doc) {
  const win = doc.defaultView;
  if (!win || !doc.body) return;
  const articles = doc.querySelectorAll('article');
  for (const article of articles) {
    article.style.setProperty('margin-left', '0', 'important');
    article.style.setProperty('margin-right', '0', 'important');
  }
  for (const node of doc.querySelectorAll('body *')) {
    if (!(node instanceof win.HTMLElement) && !(node instanceof win.SVGElement)) continue;
    const style = win.getComputedStyle(node);
    const clippedX = style.overflowX === 'hidden' || style.overflowX === 'clip';
    if (clippedX && node.scrollWidth > node.clientWidth + 1)
      node.style.setProperty('overflow-x', 'visible', 'important');
  }
}

function measuredDocumentSize(doc) {
  const root = doc.documentElement;
  const body = doc.body;
  let maxRight = Math.max(root?.scrollWidth || 0, body?.scrollWidth || 0);
  let maxBottom = Math.max(root?.scrollHeight || 0, body?.scrollHeight || 0);
  if (body) {
    const nodes = [body, ...body.querySelectorAll('*')];
    for (const node of nodes) {
      if (!node.getBoundingClientRect) continue;
      const rect = node.getBoundingClientRect();
      if (!Number.isFinite(rect.right) || !Number.isFinite(rect.bottom)) continue;
      maxRight = Math.max(maxRight, rect.right + (doc.defaultView?.scrollX || 0));
      maxBottom = Math.max(maxBottom, rect.bottom + (doc.defaultView?.scrollY || 0));
    }
  }
  return {
    width: Math.ceil(Math.max(1, maxRight + 2)),
    height: Math.ceil(Math.max(1, maxBottom + 2)),
  };
}

function sizeFrame(frame) {
  try {
    const doc = frame.contentDocument;
    if (!doc?.documentElement || !doc.body) return;
    doc.documentElement.style.overflow = 'visible';
    doc.body.style.overflow = 'visible';
    relaxFrameClipping(doc);
    const size = measuredDocumentSize(doc);
    frame.style.width = `${size.width}px`;
    frame.style.height = `${Math.max(size.height, viewport()?.clientHeight || 480)}px`;
  } catch (_) {}
}

function mountDocument(markup, state) {
  const surface = resetSurface('ff-frame-layout');

  const frame = document.createElement('iframe');
  frame.setAttribute('sandbox', 'allow-same-origin');
  frame.setAttribute('scrolling', 'no');
  frame.setAttribute('title', currentName);
  frame.style.display = 'block';
  frame.style.border = '0';
  frame.style.margin = '0 auto';
  frame.style.background = '#fff';
  // Keep all touches on the parent scroll surface. The rendered iframe is
  // visual content only; links are recovered by explicit hit testing below.
  frame.style.pointerEvents = 'none';
  frame.style.width = `${Math.max(320, viewport()?.clientWidth || 320)}px`;
  frame.style.height = `${Math.max(480, viewport()?.clientHeight || 480)}px`;
  frame.addEventListener('load', () => {
    activeFrame = frame;
    const doc = frame.contentDocument;
    if (doc) {
      for (const image of doc.images || [])
        image.addEventListener('load', () => sizeFrame(frame), { once: true });
    }
    sizeFrame(frame);
    requestAnimationFrame(() => {
      sizeFrame(frame);
      setTimeout(() => {
        sizeFrame(frame);
        restoreState(state);
      }, 80);
    });
    setTimeout(() => sizeFrame(frame), 320);
  }, { once: true });
  frame.srcdoc = cleanGeneratedDocument(markup);
  surface.appendChild(frame);
}

async function mountWordDocument(bytes, ext, state) {
  const surface = resetSurface('ff-word-layout');
  const container = document.createElement('div');
  container.className = 'ff-word-render';
  surface.appendChild(container);

  let docxBytes = bytes;
  let mode = 'word-docx-layout';
  if (LEGACY_WORD.has(ext)) {
    // Ream's HTML output is deliberately flowed and can drop/fold page
    // geometry. Legacy .doc/.dot is therefore normalized to OOXML first and
    // rendered by the same paginated DOCX engine used elsewhere in FuckFile.
    setStatus(`正在转换旧版 Word 文档（${currentName}）…`);
    const parsed = Ream.parse(bytes);
    docxBytes = await parsed.convert('docx');
    mode = 'legacy-word-docx-layout';
  }

  await renderDocxPreview(docxBytes, container, null, {
    className: 'ffdocx',
    inWrapper: true,
    breakPages: true,
    renderHeaders: true,
    renderFooters: true,
    renderFootnotes: true,
    useBase64URL: true,
    ignoreLastRenderedPageBreak: false,
  });

  setFormatLabel(LEGACY_WORD.has(ext) ? 'Word · 兼容布局预览' : 'Word · 布局预览');
  requestAnimationFrame(() => requestAnimationFrame(() => restoreState(state)));
  return mode;
}

async function structuredMarkdown(bytes, ext) {
  if (ext === 'rtf' || ext === 'rtfd') return rtfToMarkdown(bytes);
  if (ODF.has(ext)) return odfToMarkdown(bytes);
  if (IWORK_PAGES.has(ext)) return pagesToMarkdown(bytes);
  if (IWORK_NUMBERS.has(ext)) return numbersToMarkdown(bytes);
  if (IWORK_KEYNOTE.has(ext)) return keynoteToMarkdown(bytes);
  if (WPS.has(ext)) return wpsToMarkdown(bytes);
  throw new Error(`暂不支持 .${ext || '?'} 的离线解析。`);
}

async function renderBytes(bytes, ext, state) {
  if (VISUAL_WORD.has(ext)) return mountWordDocument(bytes, ext, state);

  if (VISUAL_PRESENTATION.has(ext)) {
    const parsed = Ream.parse(bytes);
    const htmlBytes = await parsed.convert('html');
    const html = new TextDecoder('utf-8').decode(htmlBytes);
    setFormatLabel(labelForExtension(ext, false));
    mountDocument(html, state);
    return 'visual-presentation';
  }

  const markdown = await structuredMarkdown(bytes, ext);
  setFormatLabel(labelForExtension(ext, true));
  mountDocument(markdownDocument(markdown), state);
  return 'structured';
}

async function openDocument(payload = {}) {
  const generation = ++renderGeneration;
  const restored = payload.state && typeof payload.state === 'object' ? payload.state : null;
  // A saved state written before the user ever zoomed keeps opening at
  // fit-width; only an explicit user zoom turns that off persistently.
  autoFitActive = !(restored && restored.autoFit === false);
  layoutControl()?.setAutoFit(autoFitActive);
  currentName = payload.name || '办公文档';
  currentExtension = extensionOf(currentName);
  zoom = clampZoom(Number(restored?.zoom || 1));
  updateZoomHUD();
  setSearchBarVisible(false);
  setStatus(`正在打开 ${currentName}…`);

  try {
    const response = await fetch('ffoffice:///document', { cache: 'no-store' });
    if (response.status >= 400) throw new Error(`读取文件失败（${response.status}）`);
    const buffer = await response.arrayBuffer();
    if (!buffer.byteLength) throw new Error('文件为空或无法读取。');
    if (generation !== renderGeneration) return;

    const mode = await renderBytes(new Uint8Array(buffer), currentExtension, payload.state || null);
    if (generation !== renderGeneration) return;
    hideStatus();
    bridge({ type: 'loaded', mode, extension: currentExtension });
    emitState(true);
  } catch (error) {
    if (generation !== renderGeneration) return;
    const message = error?.message || String(error || '未知错误');
    setStatus(message, true);
    bridge({ type: 'error', message, extension: currentExtension });
  }
}

// evaluateJavaScript cannot bridge a Promise. Native calls this synchronous
// wrapper; the async renderer continues internally and reports through ffOffice.
function openDocumentForNative(payload = {}) {
  void openDocument(payload);
  return null;
}

function installToolbar() {
  document.getElementById('ff-zoom-out')?.addEventListener('click', () => {
    disableAutoFit();
    setZoom(zoom - 0.1, null, true);
  });
  document.getElementById('ff-zoom-in')?.addEventListener('click', () => {
    disableAutoFit();
    setZoom(zoom + 0.1, null, true);
  });
  document.getElementById('ff-zoom-value')?.addEventListener('click', () => {
    disableAutoFit();
    setZoom(1, null, true);
  });
}

function touchCenter(touches, rect) {
  return {
    x: ((touches[0].clientX + touches[1].clientX) / 2) - rect.left,
    y: ((touches[0].clientY + touches[1].clientY) / 2) - rect.top,
  };
}

function touchDistance(touches) {
  const dx = touches[0].clientX - touches[1].clientX;
  const dy = touches[0].clientY - touches[1].clientY;
  return Math.hypot(dx, dy);
}

function openRenderedLinkAtPoint(clientX, clientY) {
  const frame = activeFrame;
  const view = viewport();
  if (!frame || !view) return false;
  try {
    const rect = frame.getBoundingClientRect();
    if (clientX < rect.left || clientX > rect.right || clientY < rect.top || clientY > rect.bottom)
      return false;
    const doc = frame.contentDocument;
    if (!doc) return false;
    const localX = (clientX - rect.left) / zoom;
    const localY = (clientY - rect.top) / zoom;
    const element = doc.elementFromPoint(localX, localY);
    const link = element?.closest?.('a[href]');
    if (!link) return false;
    const href = link.getAttribute('href') || '';
    if (href.startsWith('#')) {
      const target = doc.getElementById(href.slice(1));
      if (!target) return true;
      const targetRect = target.getBoundingClientRect();
      view.scrollTop = Math.max(0, view.scrollTop + targetRect.top * zoom - 12);
      emitState(true);
      return true;
    }
    if (/^https?:/i.test(href)) {
      bridge({ type: 'link', url: href });
      return true;
    }
  } catch (_) {}
  return false;
}

function openDirectLink(event) {
  if (activeFrame) return false;
  const view = viewport();
  const target = event.target;
  const link = target?.closest?.('a[href]');
  if (!view || !link) return false;
  const href = link.getAttribute('href') || '';
  if (href.startsWith('#')) {
    const destination = document.getElementById(href.slice(1));
    if (destination) {
      const viewRect = view.getBoundingClientRect();
      const rect = destination.getBoundingClientRect();
      view.scrollTop = Math.max(0, view.scrollTop + rect.top - viewRect.top - 12);
      emitState(true);
    }
    return true;
  }
  if (/^https?:/i.test(href)) {
    bridge({ type: 'link', url: href });
    return true;
  }
  return false;
}

function installViewerGestures() {
  const view = viewport();
  if (!view) return;

  view.addEventListener('touchstart', (event) => {
    if (event.touches.length !== 2) return;
    const distance = touchDistance(event.touches);
    if (!(distance > 0)) return;
    disableAutoFit();
    const center = touchCenter(event.touches, view.getBoundingClientRect());
    pinch = {
      distance,
      zoom,
      contentX: (view.scrollLeft + center.x - layoutOffsetX()) / zoom,
      contentY: (view.scrollTop + center.y) / zoom,
    };
    if (event.cancelable) event.preventDefault();
  }, { passive: false, capture: true });

  view.addEventListener('touchmove', (event) => {
    if (!pinch || event.touches.length !== 2) return;
    const distance = touchDistance(event.touches);
    if (!(distance > 0)) return;
    const center = touchCenter(event.touches, view.getBoundingClientRect());
    const next = clampZoom(pinch.zoom * distance / pinch.distance);
    applyZoom(next);
    view.scrollLeft = Math.max(0, pinch.contentX * next - center.x + centeredOffsetFor(next));
    view.scrollTop = Math.max(0, pinch.contentY * next - center.y);
    if (event.cancelable) event.preventDefault();
  }, { passive: false, capture: true });

  const finish = (event) => {
    if (!pinch) return;
    if (event.touches.length >= 2) return;
    pinch = null;
    emitState(true);
  };
  view.addEventListener('touchend', finish, { passive: true, capture: true });
  view.addEventListener('touchcancel', finish, { passive: true, capture: true });
  view.addEventListener('touchstart', cancelPendingScrollRestore, { passive: true, capture: true });
  view.addEventListener('wheel', cancelPendingScrollRestore, { passive: true, capture: true });
  view.addEventListener('scroll', emitStateThrottled, { passive: true });
  view.addEventListener('click', (event) => {
    if (openDirectLink(event) || openRenderedLinkAtPoint(event.clientX, event.clientY)) {
      event.preventDefault();
      event.stopPropagation();
    }
  }, true);
}

function boot() {
  try {
    window.FFOffice = { open: openDocumentForNative, captureState, fit: fitToWidth };
    window.addEventListener('ffofficezoom', (event) => {
      const detail = event?.detail;
      if (!detail || !Number.isFinite(Number(detail.zoom))) return;
      zoom = clampZoom(Number(detail.zoom));
      updateZoomHUD();
      if (detail.autoFit) emitState(false);
    });
    installToolbar();
    installSearch();
    installViewerGestures();
    stateTimer = window.setInterval(() => emitState(false), 1200);
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) emitState(true);
    });
    bridge({ type: 'ready' });
  } catch (error) {
    const message = error?.message || String(error || '办公文档阅读器初始化失败');
    setStatus(message, true);
    bridge({ type: 'error', message });
  }
}

window.addEventListener('beforeunload', () => {
  if (stateTimer) clearInterval(stateTimer);
  pinch = null;
  activeFrame = null;
});

boot();