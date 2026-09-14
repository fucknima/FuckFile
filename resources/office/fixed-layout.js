(() => {
  'use strict';

  const MIN_ZOOM = 0.25;
  const MAX_ZOOM = 4;
  const view = document.getElementById('ff-viewport');
  const host = document.getElementById('ff-document-host');
  if (!view || !host) return;

  // The original viewer used CSS `zoom`. WebKit is allowed to recompute layout
  // for `zoom`, so Word text can wrap differently at 35% than it did at 100%.
  // Keep the document laid out once at its authored size and only scale the
  // resulting canvas with a compositor transform. This is the same interaction
  // model as a PDF/Quick Look page: pan/zoom changes the camera, not the text.
  const stage = document.createElement('div');
  stage.id = 'ff-fixed-layout-stage';
  stage.style.position = 'relative';
  stage.style.minWidth = '100%';
  stage.style.minHeight = '100%';
  stage.style.boxSizing = 'border-box';
  host.parentNode.insertBefore(stage, host);
  stage.appendChild(host);

  host.style.position = 'absolute';
  host.style.left = '0';
  host.style.top = '0';
  host.style.transformOrigin = '0 0';

  let currentZoom = 1;
  let lastNotifiedZoom = 0;
  let baseWidth = 0;
  let baseHeight = 0;
  let mutating = false;
  let measureToken = 0;
  // Fresh documents open fitted to the viewport width (no horizontal
  // clipping). Any explicit user zoom leaves this mode for good.
  let autoFit = true;

  function clampZoom(value) {
    const n = Number(value);
    if (!Number.isFinite(n)) return 1;
    return Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, n));
  }

  function numericZoom(value) {
    const n = Number.parseFloat(String(value || ''));
    return Number.isFinite(n) && n > 0 ? clampZoom(n) : currentZoom;
  }

  function notifyZoomChanged() {
    if (Math.abs(currentZoom - lastNotifiedZoom) < 0.0005) return;
    lastNotifiedZoom = currentZoom;
    try {
      window.dispatchEvent(new CustomEvent('ffofficezoom', {
        detail: { zoom: currentZoom, autoFit },
      }));
    } catch (_) {}
  }

  function fittedZoom() {
    const width = view.clientWidth || 0;
    if (!(width > 0) || !(baseWidth > 0)) return currentZoom;
    return clampZoom(Math.min(1, width / baseWidth));
  }

  function extent() {
    const old = host.style.transform;
    host.style.transform = 'none';
    const rootRect = host.getBoundingClientRect();
    let right = Math.max(host.scrollWidth || 0, host.offsetWidth || 0);
    let bottom = Math.max(host.scrollHeight || 0, host.offsetHeight || 0);
    for (const node of host.querySelectorAll('*')) {
      if (!node.getBoundingClientRect) continue;
      const rect = node.getBoundingClientRect();
      if (!Number.isFinite(rect.right) || !Number.isFinite(rect.bottom)) continue;
      right = Math.max(right, rect.right - rootRect.left);
      bottom = Math.max(bottom, rect.bottom - rootRect.top);
    }
    host.style.transform = old;
    return {
      width: Math.max(1, Math.ceil(right + 2)),
      height: Math.max(1, Math.ceil(bottom + 2)),
    };
  }

  function applyTransform() {
    if (!(baseWidth > 0) || !(baseHeight > 0)) return;
    const scaledWidth = baseWidth * currentZoom;
    const scaledHeight = baseHeight * currentZoom;

    // Deliberately do not horizontally reflow or resize the document when the
    // phone is narrower. The authored page remains intact and becomes scrollable.
    host.style.transform = `scale(${currentZoom})`;
    // Center the canvas when it is narrower than the viewport (zoomed below
    // fit); entry.js mirrors this offset in its zoom anchoring.
    host.style.left = scaledWidth < view.clientWidth
        ? `${Math.round((view.clientWidth - scaledWidth) / 2)}px` : '0';
    stage.style.width = `${Math.max(view.clientWidth, scaledWidth)}px`;
    stage.style.height = `${Math.max(view.clientHeight, scaledHeight)}px`;
  }

  function freezeLayout() {
    if (!host.childElementCount) return;
    mutating = true;
    host.style.zoom = '';
    host.style.transform = 'none';
    host.style.width = 'max-content';
    host.style.height = 'auto';

    const size = extent();
    baseWidth = Math.max(size.width, view.clientWidth);
    baseHeight = Math.max(size.height, view.clientHeight);
    host.style.width = `${baseWidth}px`;
    host.style.height = `${baseHeight}px`;
    if (autoFit) currentZoom = fittedZoom();
    mutating = false;
    applyTransform();
    notifyZoomChanged();
  }

  function scheduleMeasure() {
    const token = ++measureToken;
    requestAnimationFrame(() => requestAnimationFrame(() => {
      if (token !== measureToken) return;
      freezeLayout();
      setTimeout(() => {
        if (token === measureToken) freezeLayout();
      }, 120);
    }));
  }

  function consumeInlineZoom() {
    if (mutating) return;
    const inline = host.style.zoom;
    if (!inline) return;
    currentZoom = numericZoom(inline);
    mutating = true;
    host.style.zoom = '';
    mutating = false;
    applyTransform();
    notifyZoomChanged();
  }

  // Search highlighting rewrites text nodes into <mark class="ff-hit"> and
  // back; that decoration never changes the document size, so it must not
  // trigger a full re-measure on every find step.
  function isSearchDecoration(record) {
    const added = record.addedNodes || [];
    const removed = record.removedNodes || [];
    if (!added.length && !removed.length) return false;
    for (const list of [added, removed]) {
      for (let i = 0; i < list.length; i += 1) {
        const node = list[i];
        if (!node) continue;
        if (node.nodeType === 3) continue;
        if (node.nodeType === 1 && node.classList && node.classList.contains('ff-hit')) continue;
        return false;
      }
    }
    return true;
  }

  const observer = new MutationObserver((records) => {
    let contentChanged = false;
    let styleChanged = false;
    for (const record of records) {
      if (record.type === 'childList') {
        if (!isSearchDecoration(record)) contentChanged = true;
      }
      if (record.type === 'attributes' && record.target === host && record.attributeName === 'style')
        styleChanged = true;
    }
    if (styleChanged) consumeInlineZoom();
    if (contentChanged) scheduleMeasure();
  });
  observer.observe(host, { childList: true, subtree: true, attributes: true, attributeFilter: ['style'] });

  // Images and generated drawing layers can settle after the initial renderer
  // promise. Re-measure without changing their intrinsic layout.
  host.addEventListener('load', (event) => {
    if (event.target && event.target !== host) scheduleMeasure();
  }, true);

  window.addEventListener('resize', () => {
    if (!(baseWidth > 0)) return;
    if (autoFit) scheduleMeasure();
    else applyTransform();
  });

  // entry.js drives the HUD/state from this: the shim can change zoom on its
  // own while auto-fitting, and user zoom must switch auto-fit off.
  window.FFOfficeLayout = {
    setAutoFit(value) {
      const next = !!value;
      if (next === autoFit) return;
      autoFit = next;
      if (autoFit) scheduleMeasure();
    },
    isAutoFit() { return autoFit; },
  };

  // If the renderer already touched the host between the previous script's
  // boot() call and this script executing, consume it immediately.
  consumeInlineZoom();
  scheduleMeasure();
})();
