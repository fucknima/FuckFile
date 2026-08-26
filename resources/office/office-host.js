(() => {
  'use strict';

  const params = new URLSearchParams(location.search);
  const kind = params.get('kind') || 'unknown';
  const fileName = params.get('name') || 'document';
  const title = params.get('title') || fileName;
  const fileBytes = Number(params.get('bytes') || 0);
  const LARGE_WARNING_BYTES = 96 * 1024 * 1024;
  const MAX_SHEET_SEARCH_HITS = 100000;

  let restoreState = {};
  try {
    const raw = params.get('restore');
    if (raw) restoreState = JSON.parse(raw) || {};
  } catch (_) { restoreState = {}; }

  const el = (id) => document.getElementById(id);
  const content = el('content');
  const toolRow = el('tool-row');
  const sheetTabs = el('sheet-tabs');
  const pptThumbs = el('ppt-thumbs');
  const pptNav = el('ppt-nav');
  const searchInput = el('search-input');
  const searchCount = el('search-count');
  const zoomLabel = el('zoom-label');

  const state = {
    buffer: null,
    ppt: null,
    pptThumbHandles: new Map(),
    pptThumbObserver: null,
    pptSearchResults: [],
    pptSearchIndex: -1,
    pptHighlight: null,
    workbook: null,
    sheetIndex: 0,
    sheetView: null,
    sheetPositions: new Map(),
    sheetSearchHits: [],
    sheetSearchIndex: -1,
    sheetSearchTruncated: false,
    genericHits: [],
    genericIndex: -1,
    genericQuery: '',
    zoom: Number.isFinite(Number(restoreState.zoom)) ? Number(restoreState.zoom) : 100,
    fit: restoreState.fit === true,
    toolbarReady: false,
    persistTimer: 0,
    memoryWarning: false,
  };

  function native(type, extra = {}) {
    try { window.webkit?.messageHandlers?.ffOffice?.postMessage({ type, ...extra }); } catch (_) {}
  }

  function formatBytes(bytes) {
    if (!Number.isFinite(bytes) || bytes <= 0) return '';
    const units = ['B','KB','MB','GB'];
    let value = bytes, unit = 0;
    while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit++; }
    return `${value >= 10 || unit === 0 ? value.toFixed(0) : value.toFixed(1)} ${units[unit]}`;
  }

  function kindLabel() {
    return kind === 'word' ? 'Word' : kind === 'ppt' ? 'PowerPoint' :
      kind === 'sheet' ? 'Spreadsheet' : 'Office';
  }

  function setLoading(text) {
    const detail = el('loading-detail');
    if (detail) detail.textContent = text;
  }

  function setMeta(detail = '') {
    const bits = [kindLabel()];
    if (fileBytes > 0) bits.push(formatBytes(fileBytes));
    if (detail) bits.push(detail);
    el('doc-meta').textContent = bits.join(' · ');
  }

  function loadScript(name) {
    return new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = `assets/${name}`;
      script.async = true;
      script.onload = resolve;
      script.onerror = () => reject(new Error(`无法加载 Office 运行时：${name}`));
      document.head.appendChild(script);
    });
  }

  async function loadDocumentBuffer() {
    setLoading('正在读取文件');
    const response = await fetch('document', { cache:'no-store' });
    if (!response.ok && response.status) throw new Error(`读取文件失败：${response.status}`);
    const buffer = await response.arrayBuffer();
    if (!buffer || buffer.byteLength === 0) throw new Error('文件为空或读取失败');
    return buffer;
  }

  function clearContent() {
    state.sheetView?.dispose?.();
    state.sheetView = null;
    content.innerHTML = '';
  }

  function showError(error) {
    clearContent();
    const message = error instanceof Error ? error.message : String(error || '未知错误');
    const card = document.createElement('div');
    card.className = 'state-card';
    card.innerHTML = '<div class="error-icon">⚠︎</div><strong>Office 渲染失败</strong><p></p><div class="action-row"><button class="action-button" id="fallback-now">系统快速查看</button><button class="action-button secondary" id="retry-now">重新尝试</button></div>';
    card.querySelector('p').textContent = message;
    content.appendChild(card);
    card.querySelector('#fallback-now').onclick = () => native('fallback');
    card.querySelector('#retry-now').onclick = () => location.reload();
    native('error', { message });
  }

  function showLargeWarning() {
    clearContent();
    const card = document.createElement('div');
    card.className = 'state-card';
    card.innerHTML = `<div class="error-icon">◫</div><strong>这是一个较大的办公文件</strong><p>文件大小 ${formatBytes(fileBytes)}。已通过原生 ZIP 结构安全检查，但网页渲染仍会占用较多内存。</p><div class="action-row"><button class="action-button" id="continue-large">继续渲染</button><button class="action-button secondary" id="fallback-large">系统快速查看</button></div>`;
    content.appendChild(card);
    card.querySelector('#fallback-large').onclick = () => native('fallback');
    card.querySelector('#continue-large').onclick = async () => {
      clearContent();
      const wait = document.createElement('div');
      wait.className = 'state-card';
      wait.innerHTML = '<div class="spinner"></div><strong>正在打开办公文件…</strong><span id="loading-detail">读取文件</span>';
      content.appendChild(wait);
      try { await render(); } catch (error) { showError(error); }
    };
  }

  function snapshotState() {
    const common = { kind, zoom:state.zoom, fit:state.fit };
    if (kind === 'word') {
      common.scrollTop = content.scrollTop || 0;
    } else if (kind === 'ppt' && state.ppt) {
      common.slideIndex = Number(state.ppt.currentSlideIndex || 0);
    } else if (kind === 'sheet') {
      common.sheetIndex = state.sheetIndex;
      if (state.sheetView) {
        const position = state.sheetView.position();
        common.sheetScrollTop = position.top;
        common.sheetScrollLeft = position.left;
      }
    }
    return common;
  }

  function persistStateNow() {
    clearTimeout(state.persistTimer);
    state.persistTimer = 0;
    native('state', { state:snapshotState() });
  }

  function schedulePersist() {
    clearTimeout(state.persistTimer);
    state.persistTimer = setTimeout(persistStateNow, 450);
  }

  function setupCommonToolbar() {
    toolRow.classList.remove('hidden');
    if (state.toolbarReady) return;
    state.toolbarReady = true;
    el('fullscreen-button').onclick = () => native('fullscreen');
    el('zoom-out').onclick = () => setZoom(state.zoom - 10);
    el('zoom-in').onclick = () => setZoom(state.zoom + 10);
    el('zoom-label').onclick = () => setZoom(100);
    el('fit-button').onclick = () => toggleFit();
    el('search-next').onclick = () => searchStep(1);
    el('search-prev').onclick = () => searchStep(-1);
    searchInput.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') {
        event.preventDefault();
        searchStep(event.shiftKey ? -1 : 1, true);
      }
    });
    searchInput.addEventListener('search', () => { if (!searchInput.value) clearSearch(); });
    content.addEventListener('scroll', () => { if (kind === 'word') schedulePersist(); }, {passive:true});
  }

  async function setZoom(value) {
    state.zoom = Math.max(40, Math.min(300, Math.round(value / 10) * 10));
    state.fit = false;
    zoomLabel.textContent = `${state.zoom}%`;
    el('fit-button').textContent = '适合';
    if (kind === 'ppt' && state.ppt) {
      await state.ppt.setFitMode('none');
      await state.ppt.setZoom(state.zoom);
      schedulePersist();
      return;
    }
    if (kind === 'sheet' && state.sheetView) {
      state.sheetView.setScale(state.zoom / 100);
      schedulePersist();
      return;
    }
    const root = document.querySelector('.docx-root');
    if (root) {
      root.style.zoom = String(state.zoom / 100);
      root.style.width = `${10000 / state.zoom}%`;
      schedulePersist();
    }
  }

  async function toggleFit() {
    state.fit = !state.fit;
    if (kind === 'ppt' && state.ppt) {
      if (state.fit) {
        await state.ppt.setFitMode('contain');
        state.zoom = 100;
        zoomLabel.textContent = '适合';
        el('fit-button').textContent = '100%';
      } else {
        await state.ppt.setFitMode('none');
        await state.ppt.setZoom(100);
        state.zoom = 100;
        zoomLabel.textContent = '100%';
        el('fit-button').textContent = '适合';
      }
      schedulePersist();
      return;
    }
    if (kind === 'sheet' && state.sheetView) {
      if (state.fit) {
        const scale = state.sheetView.fitScale();
        state.zoom = Math.round(scale * 100);
        state.sheetView.setScale(scale);
        zoomLabel.textContent = '适合';
        el('fit-button').textContent = '100%';
      } else {
        state.zoom = 100;
        state.sheetView.setScale(1);
        zoomLabel.textContent = '100%';
        el('fit-button').textContent = '适合';
      }
      schedulePersist();
      return;
    }
    const root = document.querySelector('.docx-root');
    if (!root) return;
    if (state.fit) {
      root.style.zoom = '';
      root.style.width = '';
      state.zoom = 100;
      zoomLabel.textContent = '适合';
      el('fit-button').textContent = '100%';
    } else {
      root.style.zoom = '';
      root.style.width = '';
      state.zoom = 100;
      zoomLabel.textContent = '100%';
      el('fit-button').textContent = '适合';
    }
    schedulePersist();
  }

  function clearSearchMarks() {
    document.querySelectorAll('mark.search-mark').forEach((mark) => {
      const parent = mark.parentNode;
      if (!parent) return;
      parent.replaceChild(document.createTextNode(mark.textContent || ''), mark);
      parent.normalize();
    });
  }

  function markText(root, query) {
    clearSearchMarks();
    if (!query) return [];
    const hits = [], lower = query.toLocaleLowerCase();
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, { acceptNode(node) {
      const parent = node.parentElement;
      if (!parent || ['SCRIPT','STYLE','TEXTAREA','INPUT'].includes(parent.tagName)) return NodeFilter.FILTER_REJECT;
      return node.nodeValue && node.nodeValue.toLocaleLowerCase().includes(lower)
        ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
    }});
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    for (const textNode of nodes) {
      const text = textNode.nodeValue || '';
      const textLower = text.toLocaleLowerCase();
      let cursor = 0, index = textLower.indexOf(lower);
      if (index < 0) continue;
      const fragment = document.createDocumentFragment();
      while (index >= 0) {
        if (index > cursor) fragment.appendChild(document.createTextNode(text.slice(cursor,index)));
        const mark = document.createElement('mark');
        mark.className = 'search-mark';
        mark.textContent = text.slice(index,index + query.length);
        fragment.appendChild(mark);
        hits.push(mark);
        cursor = index + query.length;
        index = textLower.indexOf(lower,cursor);
      }
      if (cursor < text.length) fragment.appendChild(document.createTextNode(text.slice(cursor)));
      textNode.parentNode.replaceChild(fragment,textNode);
    }
    return hits;
  }

  function updateSearchCount(index,total,truncated = false) {
    if (total <= 0) searchCount.textContent = '';
    else searchCount.textContent = `${index + 1}/${total}${truncated ? '+' : ''}`;
  }

  function clearSearch() {
    state.genericQuery = '';
    state.genericHits = [];
    state.genericIndex = -1;
    state.sheetSearchHits = [];
    state.sheetSearchIndex = -1;
    state.sheetSearchTruncated = false;
    state.sheetView?.setSearchFocus?.(null);
    if (state.ppt) {
      state.pptSearchResults = [];
      state.pptSearchIndex = -1;
      state.ppt.clearSearchHighlights?.();
      state.pptHighlight?.dispose?.();
      state.pptHighlight = null;
    }
    clearSearchMarks();
    updateSearchCount(0,0);
  }

  function sheetSearch(query) {
    const worksheet = state.workbook?.Sheets?.[state.workbook.SheetNames[state.sheetIndex]];
    if (!worksheet) return [];
    const lower = query.toLocaleLowerCase();
    const hits = [];
    state.sheetSearchTruncated = false;
    for (const address of Object.keys(worksheet)) {
      if (!address || address[0] === '!') continue;
      const cell = worksheet[address];
      if (!cell) continue;
      let display = cell.w;
      if (display == null) {
        try { display = window.XLSX.utils.format_cell(cell); }
        catch (_) { display = cell.v == null ? '' : String(cell.v); }
      }
      const formula = cell.f ? `=${cell.f}` : '';
      if (`${display ?? ''}\n${formula}`.toLocaleLowerCase().includes(lower)) {
        try {
          const pos = window.XLSX.utils.decode_cell(address);
          hits.push({r:pos.r,c:pos.c});
        } catch (_) {}
        if (hits.length >= MAX_SHEET_SEARCH_HITS) {
          state.sheetSearchTruncated = true;
          break;
        }
      }
    }
    return hits;
  }

  async function searchStep(direction, forceNew = false) {
    const query = searchInput.value.trim();
    if (!query) { clearSearch(); return; }

    if (kind === 'ppt' && state.ppt) {
      if (forceNew || state.genericQuery !== query || state.pptSearchResults.length === 0) {
        state.genericQuery = query;
        state.ppt.clearSearchHighlights?.();
        state.pptHighlight?.dispose?.();
        state.pptHighlight = null;
        state.pptSearchResults = state.ppt.searchText(query) || [];
        state.pptSearchIndex = direction < 0 ? state.pptSearchResults.length : -1;
      }
      if (!state.pptSearchResults.length) { updateSearchCount(0,0); return; }
      state.pptSearchIndex = (state.pptSearchIndex + direction + state.pptSearchResults.length) % state.pptSearchResults.length;
      const match = state.pptSearchResults[state.pptSearchIndex];
      state.pptHighlight?.dispose?.();
      state.pptHighlight = await state.ppt.highlightSearchResult(match);
      updateSearchCount(state.pptSearchIndex,state.pptSearchResults.length);
      return;
    }

    if (kind === 'sheet' && state.sheetView) {
      if (forceNew || state.genericQuery !== query || state.sheetSearchHits.length === 0) {
        state.genericQuery = query;
        state.sheetSearchHits = sheetSearch(query);
        state.sheetSearchIndex = direction < 0 ? state.sheetSearchHits.length : -1;
      }
      if (!state.sheetSearchHits.length) { updateSearchCount(0,0); return; }
      state.sheetSearchIndex = (state.sheetSearchIndex + direction + state.sheetSearchHits.length) % state.sheetSearchHits.length;
      const hit = state.sheetSearchHits[state.sheetSearchIndex];
      state.sheetView.focusCell(hit.r,hit.c);
      updateSearchCount(state.sheetSearchIndex,state.sheetSearchHits.length,state.sheetSearchTruncated);
      return;
    }

    const root = document.querySelector('.docx-root');
    if (!root) return;
    if (forceNew || state.genericQuery !== query || state.genericHits.length === 0) {
      state.genericQuery = query;
      state.genericHits = markText(root,query);
      state.genericIndex = direction < 0 ? state.genericHits.length : -1;
    }
    if (!state.genericHits.length) { updateSearchCount(0,0); return; }
    state.genericIndex = (state.genericIndex + direction + state.genericHits.length) % state.genericHits.length;
    state.genericHits[state.genericIndex].scrollIntoView({behavior:'smooth',block:'center',inline:'center'});
    updateSearchCount(state.genericIndex,state.genericHits.length);
  }

  async function renderWord(buffer) {
    setLoading('加载 Word 渲染器');
    await loadScript('jszip.min.js');
    await loadScript('docx-preview.min.js');
    if (!window.docx?.renderAsync) throw new Error('docx-preview 初始化失败');
    clearContent();
    const root = document.createElement('div');
    root.className = 'docx-root';
    content.appendChild(root);
    await window.docx.renderAsync(buffer, root, root, {
      inWrapper:true, hideWrapperOnPrint:false, ignoreWidth:false, ignoreHeight:false, ignoreFonts:false,
      breakPages:true, debug:false, experimental:false, renderHeaders:true, renderFooters:true,
      renderFootnotes:true, renderEndnotes:true, ignoreLastRenderedPageBreak:false, useBase64URL:true,
      renderChanges:true, renderComments:true, renderAltChunks:false,
    });
    setupCommonToolbar();
    state.zoom = Math.max(40, Math.min(300, Number(restoreState.zoom) || 100));
    state.fit = restoreState.fit === true;
    if (!state.fit && state.zoom !== 100) await setZoom(state.zoom);
    else { zoomLabel.textContent = state.fit ? '适合' : `${state.zoom}%`; el('fit-button').textContent = state.fit ? '100%' : '适合'; }
    requestAnimationFrame(() => {
      const top = Number(restoreState.scrollTop || 0);
      if (Number.isFinite(top) && top > 0) content.scrollTop = top;
    });
    setMeta(`${root.querySelectorAll('section.docx').length || 1} 页`);
    native('loaded',{detail:'word'});
  }

  function buildPptThumbnails() {
    pptThumbs.innerHTML = '';
    pptThumbs.classList.remove('hidden');
    const count = state.ppt?.slideCount || 0;
    for (let index = 0; index < count; index++) {
      const item = document.createElement('button');
      item.className = 'ppt-thumb';
      item.dataset.index = String(index);
      item.title = `第 ${index + 1} 页`;
      const number = document.createElement('span');
      number.className = 'ppt-thumb-number';
      number.textContent = String(index + 1);
      item.appendChild(number);
      item.onclick = () => state.ppt.goToSlide(index,{behavior:'smooth',block:'start'});
      pptThumbs.appendChild(item);
    }
    state.pptThumbObserver?.disconnect?.();
    state.pptThumbObserver = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        const target = entry.target;
        const index = Number(target.dataset.index);
        if (!Number.isFinite(index)) continue;
        if (entry.isIntersecting) {
          if (!state.pptThumbHandles.has(index)) {
            try {
              const handle = state.ppt.renderThumbnailToContainer(index,target,{width:112});
              if (handle) state.pptThumbHandles.set(index,handle);
            } catch (_) {}
          }
        } else {
          const handle = state.pptThumbHandles.get(index);
          if (handle) {
            handle.dispose?.();
            state.pptThumbHandles.delete(index);
            [...target.children].forEach((child) => {
              if (!child.classList.contains('ppt-thumb-number')) child.remove();
            });
          }
        }
      }
    }, {root:pptThumbs,rootMargin:'180px'});
    pptThumbs.querySelectorAll('.ppt-thumb').forEach((node) => state.pptThumbObserver.observe(node));
  }

  function updatePptActive(index) {
    const count = state.ppt?.slideCount || 0;
    el('ppt-page').textContent = count ? `${index + 1} / ${count}` : '0 / 0';
    pptThumbs.querySelectorAll('.ppt-thumb').forEach((thumb) =>
      thumb.classList.toggle('active',Number(thumb.dataset.index) === index));
    pptThumbs.querySelector(`.ppt-thumb[data-index="${index}"]`)?.scrollIntoView({block:'nearest',inline:'nearest'});
    schedulePersist();
  }

  async function renderPpt(buffer) {
    setLoading('加载 PowerPoint 渲染器');
    const runtime = await import(new URL('assets/pptx-renderer.browser.es.js',document.baseURI).href);
    if (!runtime?.PptxViewer) throw new Error('pptx-renderer 初始化失败');
    clearContent();
    const root = document.createElement('div');
    root.className = 'ppt-root';
    content.appendChild(root);
    state.ppt = await runtime.PptxViewer.open(buffer,root,{
      renderMode:'list', zipLimits:runtime.RECOMMENDED_ZIP_LIMITS, lazySlides:true, lazyMedia:true, pdfjs:false,
      listOptions:{windowed:true,batchSize:4,initialSlides:4,overscanViewport:1.5},
      onSlideChange:(index) => updatePptActive(index),
      onSlideError:(index,error) => native('error',{message:`第 ${index + 1} 页渲染失败：${error?.message || error}`}),
    });
    pptNav.classList.remove('hidden');
    setupCommonToolbar();
    buildPptThumbnails();
    el('ppt-prev').onclick = () => state.ppt.goToSlide(Math.max(0,state.ppt.currentSlideIndex - 1),{behavior:'smooth'});
    el('ppt-next').onclick = () => state.ppt.goToSlide(Math.min(state.ppt.slideCount - 1,state.ppt.currentSlideIndex + 1),{behavior:'smooth'});

    const targetSlide = Math.max(0, Math.min(state.ppt.slideCount - 1, Number(restoreState.slideIndex || 0)));
    if (targetSlide > 0) await state.ppt.goToSlide(targetSlide,{behavior:'auto',block:'start'});
    state.zoom = Math.max(40, Math.min(300, Number(restoreState.zoom) || 100));
    state.fit = restoreState.fit === true;
    if (state.fit) {
      await state.ppt.setFitMode('contain');
      zoomLabel.textContent = '适合';
      el('fit-button').textContent = '100%';
    } else if (state.zoom !== 100) {
      await state.ppt.setFitMode('none');
      await state.ppt.setZoom(state.zoom);
      zoomLabel.textContent = `${state.zoom}%`;
      el('fit-button').textContent = '适合';
    }
    updatePptActive(state.ppt.currentSlideIndex || targetSlide);
    setMeta(`${state.ppt.slideCount} 页`);
    native('loaded',{detail:`ppt:${state.ppt.slideCount}`});
  }

  function rowHeight(worksheet, row) {
    const info = worksheet['!rows']?.[row];
    if (info?.hidden) return 0;
    if (Number.isFinite(info?.hpx) && info.hpx > 0) return Math.max(12,info.hpx);
    if (Number.isFinite(info?.hpt) && info.hpt > 0) return Math.max(12,info.hpt * 96 / 72);
    return 23;
  }

  function columnWidth(worksheet, column) {
    const info = worksheet['!cols']?.[column];
    if (info?.hidden) return 0;
    if (Number.isFinite(info?.wpx) && info.wpx > 0) return Math.max(28,info.wpx);
    if (Number.isFinite(info?.wch) && info.wch > 0) return Math.max(28,Math.round(info.wch * 7 + 12));
    if (Number.isFinite(info?.width) && info.width > 0) return Math.max(28,Math.round(info.width * 7 + 12));
    return 96;
  }

  function formattedCell(cell) {
    if (!cell) return '';
    if (cell.w != null) return String(cell.w);
    try { return String(window.XLSX.utils.format_cell(cell) ?? ''); }
    catch (_) { return cell.v == null ? '' : String(cell.v); }
  }

  class VirtualSheet {
    constructor(worksheet, root) {
      this.worksheet = worksheet;
      this.root = root;
      this.disposed = false;
      this.frame = 0;
      this.scale = 1;
      this.searchFocus = null;
      this.merges = Array.isArray(worksheet['!merges']) ? worksheet['!merges'] : [];
      const ref = worksheet['!ref'];
      if (!ref) {
        this.empty = true;
        root.innerHTML = '<div class="state-card"><strong>空工作表</strong><p>该工作表没有已使用单元格。</p></div>';
        return;
      }
      let decoded;
      try { decoded = window.XLSX.utils.decode_range(ref); }
      catch (_) { throw new Error(`工作表范围无效：${ref}`); }
      this.range = decoded;
      this.rowCount = decoded.e.r - decoded.s.r + 1;
      this.colCount = decoded.e.c - decoded.s.c + 1;
      if (this.rowCount <= 0 || this.colCount <= 0 || this.rowCount > 1048576 || this.colCount > 16384)
        throw new Error(`工作表尺寸异常：${this.rowCount}×${this.colCount}`);

      this.rowSizes = new Float32Array(this.rowCount);
      this.rowOffsets = new Float64Array(this.rowCount + 1);
      for (let i = 0; i < this.rowCount; i++) {
        const size = rowHeight(worksheet, decoded.s.r + i);
        this.rowSizes[i] = size;
        this.rowOffsets[i + 1] = this.rowOffsets[i] + size;
      }
      this.colSizes = new Float32Array(this.colCount);
      this.colOffsets = new Float64Array(this.colCount + 1);
      for (let i = 0; i < this.colCount; i++) {
        const size = columnWidth(worksheet, decoded.s.c + i);
        this.colSizes[i] = size;
        this.colOffsets[i + 1] = this.colOffsets[i] + size;
      }

      this.viewport = document.createElement('div');
      this.viewport.className = 'sheet-viewport';
      this.canvas = document.createElement('div');
      this.canvas.className = 'sheet-canvas';
      this.layer = document.createElement('div');
      this.layer.className = 'sheet-cell-layer';
      this.canvas.appendChild(this.layer);
      this.viewport.appendChild(this.canvas);
      root.appendChild(this.viewport);
      this.onScroll = () => {
        this.requestRender();
        const position = this.position();
        state.sheetPositions.set(state.sheetIndex, position);
        schedulePersist();
      };
      this.viewport.addEventListener('scroll',this.onScroll,{passive:true});
      this.onResize = () => this.requestRender();
      window.addEventListener('resize',this.onResize,{passive:true});
      this.updateCanvasSize();
      this.requestRender();
    }

    dispose() {
      this.disposed = true;
      if (this.frame) cancelAnimationFrame(this.frame);
      this.viewport?.removeEventListener('scroll',this.onScroll);
      window.removeEventListener('resize',this.onResize);
      this.layer?.replaceChildren();
      this.rowSizes = null;
      this.rowOffsets = null;
      this.colSizes = null;
      this.colOffsets = null;
    }

    position() {
      return {top:this.viewport?.scrollTop || 0,left:this.viewport?.scrollLeft || 0};
    }

    setPosition(left,top) {
      if (!this.viewport) return;
      if (Number.isFinite(left)) this.viewport.scrollLeft = Math.max(0,left);
      if (Number.isFinite(top)) this.viewport.scrollTop = Math.max(0,top);
      this.requestRender();
    }

    setScale(scale) {
      if (!Number.isFinite(scale)) return;
      const old = this.scale || 1;
      const centerX = (this.viewport.scrollLeft + this.viewport.clientWidth / 2) / old;
      const centerY = (this.viewport.scrollTop + this.viewport.clientHeight / 2) / old;
      this.scale = Math.max(0.1,Math.min(3,scale));
      this.updateCanvasSize();
      this.viewport.scrollLeft = Math.max(0,centerX * this.scale - this.viewport.clientWidth / 2);
      this.viewport.scrollTop = Math.max(0,centerY * this.scale - this.viewport.clientHeight / 2);
      this.requestRender();
    }

    fitScale() {
      if (!this.viewport || !this.colOffsets) return 1;
      const width = this.colOffsets[this.colCount];
      if (!width) return 1;
      return Math.max(0.1,Math.min(1,(this.viewport.clientWidth - 2) / width));
    }

    updateCanvasSize() {
      if (this.empty || !this.canvas) return;
      this.canvas.style.width = `${Math.max(1,this.colOffsets[this.colCount] * this.scale)}px`;
      this.canvas.style.height = `${Math.max(1,this.rowOffsets[this.rowCount] * this.scale)}px`;
    }

    indexForOffset(offsets,sizes,value) {
      let lo = 0, hi = sizes.length;
      while (lo < hi) {
        const mid = (lo + hi) >> 1;
        if (offsets[mid + 1] <= value) lo = mid + 1;
        else hi = mid;
      }
      while (lo < sizes.length && sizes[lo] === 0) lo++;
      return Math.min(Math.max(0,lo),Math.max(0,sizes.length - 1));
    }

    requestRender() {
      if (this.disposed || this.empty || this.frame) return;
      this.frame = requestAnimationFrame(() => {
        this.frame = 0;
        this.renderViewport();
      });
    }

    activeMerges(firstRow,lastRow,firstCol,lastCol) {
      const r0 = this.range.s.r + firstRow, r1 = this.range.s.r + lastRow;
      const c0 = this.range.s.c + firstCol, c1 = this.range.s.c + lastCol;
      return this.merges.filter((merge) => merge && merge.s && merge.e &&
        merge.e.r >= r0 && merge.s.r <= r1 && merge.e.c >= c0 && merge.s.c <= c1);
    }

    mergeAt(merges,row,col) {
      for (const merge of merges)
        if (row >= merge.s.r && row <= merge.e.r && col >= merge.s.c && col <= merge.e.c)
          return merge;
      return null;
    }

    cellNode(row,col,merge = null) {
      const rr = row - this.range.s.r;
      const cc = col - this.range.s.c;
      if (rr < 0 || cc < 0 || rr >= this.rowCount || cc >= this.colCount) return null;
      let endRow = rr, endCol = cc;
      if (merge) {
        endRow = Math.min(this.rowCount - 1,merge.e.r - this.range.s.r);
        endCol = Math.min(this.colCount - 1,merge.e.c - this.range.s.c);
      }
      const width = (this.colOffsets[endCol + 1] - this.colOffsets[cc]) * this.scale;
      const height = (this.rowOffsets[endRow + 1] - this.rowOffsets[rr]) * this.scale;
      if (width <= 0 || height <= 0) return null;

      const address = window.XLSX.utils.encode_cell({r:row,c:col});
      const cell = this.worksheet[address];
      const node = document.createElement('div');
      node.className = 'sheet-cell';
      if (cell?.f) node.classList.add('formula');
      if (cell?.t === 'n' || cell?.t === 'd') node.classList.add('number');
      if (cell?.t === 'b') node.classList.add('boolean');
      if (this.searchFocus && this.searchFocus.r === row && this.searchFocus.c === col)
        node.classList.add('search-current');
      node.dataset.address = address;
      node.style.left = `${this.colOffsets[cc] * this.scale}px`;
      node.style.top = `${this.rowOffsets[rr] * this.scale}px`;
      node.style.width = `${width}px`;
      node.style.height = `${height}px`;
      node.style.fontSize = `${12 * Math.max(0.75,Math.min(1.5,this.scale))}px`;
      node.textContent = formattedCell(cell);
      if (cell?.f) node.title = `${address} · =${cell.f}`;
      else if (cell?.v != null) node.title = `${address} · ${String(cell.v)}`;
      else node.title = address;
      return node;
    }

    renderViewport() {
      if (this.disposed || this.empty || !this.viewport || !this.layer) return;
      const scale = this.scale || 1;
      const top = this.viewport.scrollTop / scale;
      const left = this.viewport.scrollLeft / scale;
      const bottom = (this.viewport.scrollTop + this.viewport.clientHeight) / scale;
      const right = (this.viewport.scrollLeft + this.viewport.clientWidth) / scale;
      let firstRow = this.indexForOffset(this.rowOffsets,this.rowSizes,Math.max(0,top - 140));
      let firstCol = this.indexForOffset(this.colOffsets,this.colSizes,Math.max(0,left - 220));
      let lastRow = firstRow;
      while (lastRow + 1 < this.rowCount && this.rowOffsets[lastRow] < bottom + 180) lastRow++;
      let lastCol = firstCol;
      while (lastCol + 1 < this.colCount && this.colOffsets[lastCol] < right + 260) lastCol++;
      const merges = this.activeMerges(firstRow,lastRow,firstCol,lastCol);
      const fragment = document.createDocumentFragment();
      const rendered = new Set();

      for (let rr = firstRow; rr <= lastRow; rr++) {
        if (this.rowSizes[rr] === 0) continue;
        const row = this.range.s.r + rr;
        for (let cc = firstCol; cc <= lastCol; cc++) {
          if (this.colSizes[cc] === 0) continue;
          const col = this.range.s.c + cc;
          const merge = this.mergeAt(merges,row,col);
          if (merge && (row !== merge.s.r || col !== merge.s.c)) continue;
          const key = `${row}:${col}`;
          if (rendered.has(key)) continue;
          const node = this.cellNode(row,col,merge);
          if (node) fragment.appendChild(node);
          rendered.add(key);
        }
      }
      // A merged cell can begin just outside the overscanned viewport while its
      // span is visible. Render that top-left node explicitly so it never appears
      // as a blank hole during horizontal/vertical scrolling.
      for (const merge of merges) {
        const key = `${merge.s.r}:${merge.s.c}`;
        if (rendered.has(key)) continue;
        const node = this.cellNode(merge.s.r,merge.s.c,merge);
        if (node) fragment.appendChild(node);
        rendered.add(key);
      }
      this.layer.replaceChildren(fragment);
    }

    setSearchFocus(value) {
      this.searchFocus = value;
      this.requestRender();
    }

    focusCell(row,col) {
      if (!this.range) return;
      const rr = Math.max(0,Math.min(this.rowCount - 1,row - this.range.s.r));
      const cc = Math.max(0,Math.min(this.colCount - 1,col - this.range.s.c));
      this.searchFocus = {r:row,c:col};
      const targetTop = this.rowOffsets[rr] * this.scale;
      const targetLeft = this.colOffsets[cc] * this.scale;
      const targetBottom = this.rowOffsets[rr + 1] * this.scale;
      const targetRight = this.colOffsets[cc + 1] * this.scale;
      if (targetTop < this.viewport.scrollTop || targetBottom > this.viewport.scrollTop + this.viewport.clientHeight)
        this.viewport.scrollTop = Math.max(0,targetTop - this.viewport.clientHeight / 3);
      if (targetLeft < this.viewport.scrollLeft || targetRight > this.viewport.scrollLeft + this.viewport.clientWidth)
        this.viewport.scrollLeft = Math.max(0,targetLeft - this.viewport.clientWidth / 3);
      this.requestRender();
    }
  }

  function renderSheetTabs() {
    sheetTabs.innerHTML = '';
    const names = state.workbook?.SheetNames || [];
    names.forEach((name,index) => {
      const button = document.createElement('button');
      button.className = `sheet-tab${index === state.sheetIndex ? ' active' : ''}`;
      button.textContent = name;
      button.onclick = () => renderSheet(index);
      sheetTabs.appendChild(button);
    });
    sheetTabs.classList.toggle('hidden',names.length <= 1);
  }

  function renderSheet(index, initial = false) {
    if (!state.workbook?.SheetNames?.length) return;
    if (state.sheetView) state.sheetPositions.set(state.sheetIndex,state.sheetView.position());
    state.sheetIndex = Math.max(0,Math.min(index,state.workbook.SheetNames.length - 1));
    const name = state.workbook.SheetNames[state.sheetIndex];
    const worksheet = state.workbook.Sheets[name];
    clearSearch();
    clearContent();
    const root = document.createElement('div');
    root.className = 'sheet-root';
    content.appendChild(root);
    state.sheetView = new VirtualSheet(worksheet,root);
    renderSheetTabs();
    setupCommonToolbar();

    let targetScale = Math.max(0.4,Math.min(3,(Number(state.zoom) || 100) / 100));
    if (initial && restoreState.fit === true && !state.sheetView.empty) {
      targetScale = state.sheetView.fitScale();
      state.fit = true;
      state.zoom = Math.round(targetScale * 100);
      zoomLabel.textContent = '适合';
      el('fit-button').textContent = '100%';
    } else {
      state.fit = false;
      state.zoom = Math.round(targetScale * 100);
      zoomLabel.textContent = `${state.zoom}%`;
      el('fit-button').textContent = '适合';
    }
    state.sheetView.setScale(targetScale);

    const saved = state.sheetPositions.get(state.sheetIndex);
    const left = saved?.left ?? (initial ? Number(restoreState.sheetScrollLeft || 0) : 0);
    const top = saved?.top ?? (initial ? Number(restoreState.sheetScrollTop || 0) : 0);
    requestAnimationFrame(() => state.sheetView?.setPosition(left,top));
    setMeta(`${state.workbook.SheetNames.length} 个工作表 · ${worksheet['!ref'] || '空表'}`);
    schedulePersist();
  }

  async function renderSpreadsheet(buffer) {
    setLoading('加载表格渲染器');
    await loadScript('xlsx.full.min.js');
    if (!window.XLSX?.read) throw new Error('SheetJS 初始化失败');
    state.workbook = window.XLSX.read(buffer,{
      type:'array', cellDates:true, cellNF:true, cellText:true, cellStyles:true,
      dense:false, WTF:false,
    });
    if (!state.workbook?.SheetNames?.length) throw new Error('工作簿中没有可显示的工作表');
    state.sheetIndex = Math.max(0,Math.min(state.workbook.SheetNames.length - 1,
      Number(restoreState.sheetIndex || 0)));
    state.zoom = Math.max(40,Math.min(300,Number(restoreState.zoom) || 100));
    renderSheet(state.sheetIndex,true);
    native('loaded',{detail:`sheet:${state.workbook.SheetNames.length}`});
  }

  async function render() {
    setMeta();
    state.buffer = await loadDocumentBuffer();
    try {
      if (kind === 'word') await renderWord(state.buffer);
      else if (kind === 'ppt') await renderPpt(state.buffer);
      else if (kind === 'sheet') await renderSpreadsheet(state.buffer);
      else throw new Error(`该 Office 类型暂未启用专用渲染器：${fileName}`);
    } finally {
      // Renderers own the objects they need after initialization. Drop our raw
      // ArrayBuffer reference so a second full copy cannot survive indefinitely.
      state.buffer = null;
    }
  }

  async function bootstrap() {
    el('doc-title').textContent = title;
    el('fullscreen-button').onclick = () => native('fullscreen');
    setMeta();
    if (fileBytes >= LARGE_WARNING_BYTES) { showLargeWarning(); return; }
    try { await render(); } catch (error) { showError(error); }
  }

  window.ffOfficeMemoryWarning = () => {
    state.memoryWarning = true;
    state.buffer = null;
    clearSearchMarks();
    state.genericHits = [];
    state.sheetSearchHits = [];
    state.pptSearchResults = [];
    state.pptHighlight?.dispose?.();
    state.pptHighlight = null;
    for (const [index,handle] of state.pptThumbHandles) {
      handle?.dispose?.();
      const target = pptThumbs.querySelector(`.ppt-thumb[data-index="${index}"]`);
      if (target) [...target.children].forEach((child) => {
        if (!child.classList.contains('ppt-thumb-number')) child.remove();
      });
    }
    state.pptThumbHandles.clear();
    native('memoryWarning',{kind});
  };

  window.addEventListener('error',(event) => {
    if (event?.error) native('error',{message:event.error.message || String(event.error)});
  });
  window.addEventListener('unhandledrejection',(event) => {
    const reason = event?.reason;
    native('error',{message:reason?.message || String(reason || 'Promise rejection')});
  });
  window.addEventListener('pagehide',persistStateNow);
  window.addEventListener('beforeunload',() => {
    persistStateNow();
    state.sheetView?.dispose?.();
    state.pptThumbObserver?.disconnect?.();
    state.pptThumbHandles.forEach((handle) => handle?.dispose?.());
    state.pptHighlight?.dispose?.();
    state.ppt?.dispose?.();
    state.buffer = null;
    state.workbook = null;
  });

  bootstrap();
})();
