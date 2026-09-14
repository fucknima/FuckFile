(() => {
  'use strict';

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
  let baseWidth = 0;
  let baseHeight = 0;
  let mutating = false;
  let measureToken = 0;

  function numericZoom(value) {
    const n = Number.parseFloat(String(value || ''));
    return Number.isFinite(n) && n > 0 ? n : currentZoom;
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
    mutating = false;
    applyTransform();
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
  }

  const observer = new MutationObserver((records) => {
    let contentChanged = false;
    let styleChanged = false;
    for (const record of records) {
      if (record.type === 'childList') contentChanged = true;
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
    applyTransform();
  });

  // If the renderer already touched the host between the previous script's
  // boot() call and this script executing, consume it immediately.
  consumeInlineZoom();
  scheduleMeasure();
})();
