import { Ream } from 'reamkit';
import { toMarkdown as odfToMarkdown } from '@mdgate/odf';
import { toMarkdown as rtfToMarkdown } from '@mdgate/rtf';
import { toMarkdown as pagesToMarkdown } from '@mdgate/pages';
import { toMarkdown as numbersToMarkdown } from '@mdgate/numbers';
import { toMarkdown as keynoteToMarkdown } from '@mdgate/keynote';
import { toMarkdown as wpsToMarkdown } from '@mdgate/wps';
import { marked } from 'marked';
import DOMPurify from 'dompurify';

const MIN_ZOOM = 0.35;
const MAX_ZOOM = 4.0;
const VISUAL_WORD = new Set(['doc', 'docx', 'docm', 'dot', 'dotx', 'dotm']);
const VISUAL_PRESENTATION = new Set([
  'ppt', 'pptx', 'pptm', 'pps', 'ppsx', 'ppsm', 'pot', 'potx', 'potm',
]);
const ODF = new Set(['odt', 'odp', 'ods', 'odg', 'fodt', 'fodp', 'fods', 'ott', 'otp', 'ots']);
const IWORK_PAGES = new Set(['pages']);
const IWORK_NUMBERS = new Set(['numbers']);
const IWORK_KEYNOTE = new Set(['key']);
const WPS = new Set(['wps', 'wpt', 'et', 'ett', 'dps', 'dpt']);

let zoom = 1;
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

function updateZoomHUD() {
  const label = document.getElementById('ff-zoom-value');
  if (label) label.textContent = `${Math.round(zoom * 100)}%`;
}

function setZoom(next, anchor = null, emit = false) {
  const view = viewport();
  const surface = host();
  if (!view || !surface) return zoom;

  const oldZoom = zoom;
  const newZoom = clampZoom(next);
  if (Math.abs(newZoom - oldZoom) < 0.0005) return zoom;

  let anchorX = view.clientWidth / 2;
  let anchorY = view.clientHeight / 2;
  if (anchor && Number.isFinite(anchor.x) && Number.isFinite(anchor.y)) {
    anchorX = anchor.x;
    anchorY = anchor.y;
  }
  const contentX = (view.scrollLeft + anchorX) / oldZoom;
  const contentY = (view.scrollTop + anchorY) / oldZoom;

  zoom = newZoom;
  surface.style.zoom = String(newZoom);
  updateZoomHUD();

  view.scrollLeft = Math.max(0, contentX * newZoom - anchorX);
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
  };
}

function emitState(force = false) {
  const state = captureState();
  const encoded = JSON.stringify(state);
  if (!force && encoded === lastStateJSON) return;
  lastStateJSON = encoded;
  bridge({ type: 'state', state });
}

function restoreState(state) {
  const view = viewport();
  if (!view || !state) return;
  if (Number.isFinite(state.zoom)) {
    zoom = clampZoom(state.zoom);
    host().style.zoom = String(zoom);
    updateZoomHUD();
  }
  requestAnimationFrame(() => requestAnimationFrame(() => {
    if (Number.isFinite(state.scrollX)) view.scrollLeft = Math.max(0, state.scrollX);
    if (Number.isFinite(state.scrollY)) view.scrollTop = Math.max(0, state.scrollY);
    emitState(true);
  }));
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

function cleanGeneratedDocument(markup) {
  const parsed = new DOMParser().parseFromString(String(markup || ''), 'text/html');
  for (const node of parsed.querySelectorAll('script, object, embed, form, input, textarea, button, video, audio')) node.remove();
  for (const node of parsed.querySelectorAll('meta[http-equiv="Content-Security-Policy"]')) node.remove();

  const csp = parsed.createElement('meta');
  csp.setAttribute('http-equiv', 'Content-Security-Policy');
  csp.setAttribute('content', "default-src 'none'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src 'none'; object-src 'none'; frame-src 'none'; connect-src 'none'");
  parsed.head.prepend(csp);

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
    html,body{margin:0;padding:0;background:#fff;color:#1c1c1e;font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",Arial,sans-serif;}
    article{box-sizing:border-box;width:min(920px,100%);min-height:100vh;margin:0 auto;padding:30px 32px 48px;line-height:1.58;overflow-wrap:anywhere;}
    h1,h2,h3,h4{line-height:1.28;margin-top:1.35em} table{width:100%;border-collapse:collapse;margin:14px 0;font-size:13px}th,td{border:1px solid rgba(60,60,67,.28);padding:7px 8px;vertical-align:top}pre{overflow:auto;padding:12px;border-radius:8px;background:#f2f2f7}code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}img{max-width:100%;height:auto}a{color:#007aff}
    @media(prefers-color-scheme:dark){html,body{background:#1c1c1e;color:#f2f2f7}pre{background:#2c2c2e}a{color:#64a8ff}}
  </style></head><body><article>${rendered}</article></body></html>`;
}

function sizeFrame(frame) {
  try {
    const doc = frame.contentDocument;
    if (!doc) return;
    const root = doc.documentElement;
    const body = doc.body;
    root.style.overflow = 'visible';
    body.style.overflow = 'visible';
    const width = Math.max(root.scrollWidth, body.scrollWidth, viewport()?.clientWidth || 320);
    frame.style.width = `${Math.max(1, width)}px`;
    requestAnimationFrame(() => {
      const height = Math.max(root.scrollHeight, body.scrollHeight, viewport()?.clientHeight || 480);
      frame.style.height = `${Math.max(1, height)}px`;
    });
  } catch (_) {}
}

function mountDocument(markup, state) {
  const surface = host();
  if (!surface) throw new Error('文档显示区域不存在。');
  surface.textContent = '';
  surface.style.zoom = String(zoom);
  activeFrame = null;

  const frame = document.createElement('iframe');
  frame.setAttribute('sandbox', 'allow-same-origin');
  frame.setAttribute('scrolling', 'no');
  frame.setAttribute('title', currentName);
  frame.style.display = 'block';
  frame.style.border = '0';
  frame.style.margin = '0 auto';
  frame.style.background = '#fff';
  // The rendered document is visual content. Making the frame transparent to
  // hit testing lets the parent iOS-style scroll surface keep native one-finger
  // inertia and receive two-finger pinch gestures instead of trapping touches
  // inside a non-scrolling iframe. Link taps are recovered by explicit hit
  // testing in installViewerGestures().
  frame.style.pointerEvents = 'none';
  frame.style.width = `${Math.max(320, viewport()?.clientWidth || 320)}px`;
  frame.style.height = `${Math.max(480, viewport()?.clientHeight || 480)}px`;
  frame.addEventListener('load', () => {
    activeFrame = frame;
    sizeFrame(frame);
    setTimeout(() => sizeFrame(frame), 80);
    setTimeout(() => sizeFrame(frame), 320);
    restoreState(state);
  }, { once: true });
  frame.srcdoc = cleanGeneratedDocument(markup);
  surface.appendChild(frame);
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
  if (VISUAL_WORD.has(ext) || VISUAL_PRESENTATION.has(ext)) {
    const parsed = Ream.parse(bytes);
    const htmlBytes = await parsed.convert('html');
    const html = new TextDecoder('utf-8').decode(htmlBytes);
    setFormatLabel(labelForExtension(ext, false));
    mountDocument(html, state);
    return 'visual';
  }

  const markdown = await structuredMarkdown(bytes, ext);
  setFormatLabel(labelForExtension(ext, true));
  mountDocument(markdownDocument(markdown), state);
  return 'structured';
}

async function openDocument(payload = {}) {
  const generation = ++renderGeneration;
  currentName = payload.name || '办公文档';
  currentExtension = extensionOf(currentName);
  zoom = clampZoom(Number(payload.state?.zoom || 1));
  updateZoomHUD();
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
  document.getElementById('ff-zoom-out')?.addEventListener('click', () => setZoom(zoom - 0.1, null, true));
  document.getElementById('ff-zoom-in')?.addEventListener('click', () => setZoom(zoom + 0.1, null, true));
  document.getElementById('ff-zoom-value')?.addEventListener('click', () => setZoom(1, null, true));
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

function installViewerGestures() {
  const view = viewport();
  if (!view) return;

  view.addEventListener('touchstart', (event) => {
    if (event.touches.length !== 2) return;
    const distance = touchDistance(event.touches);
    if (!(distance > 0)) return;
    const center = touchCenter(event.touches, view.getBoundingClientRect());
    pinch = {
      distance,
      zoom,
      contentX: (view.scrollLeft + center.x) / zoom,
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
    zoom = next;
    host().style.zoom = String(next);
    updateZoomHUD();
    view.scrollLeft = Math.max(0, pinch.contentX * next - center.x);
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
  view.addEventListener('scroll', () => emitState(false), { passive: true });
  view.addEventListener('click', (event) => {
    if (openRenderedLinkAtPoint(event.clientX, event.clientY)) {
      event.preventDefault();
      event.stopPropagation();
    }
  }, true);
}

function boot() {
  try {
    window.FFOffice = { open: openDocumentForNative, captureState };
    installToolbar();
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
