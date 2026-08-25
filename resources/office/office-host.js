(() => {
  'use strict';

  const params = new URLSearchParams(location.search);
  const kind = params.get('kind') || 'unknown';
  const fileName = params.get('name') || 'document';
  const title = params.get('title') || fileName;
  const fileBytes = Number(params.get('bytes') || 0);
  const LARGE_WARNING_BYTES = 96 * 1024 * 1024;

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
    buffer: null, ppt: null, pptThumbHandles: new Map(), pptThumbObserver: null,
    pptSearchResults: [], pptSearchIndex: -1, pptHighlight: null,
    workbook: null, sheetIndex: 0, sheetSearchHits: [], sheetSearchIndex: -1,
    zoom: 100, fit: true, genericQuery: '',
  };

  function native(type, extra = {}) {
    try { window.webkit?.messageHandlers?.ffOffice?.postMessage({ type, ...extra }); } catch (_) {}
  }
  function formatBytes(bytes) {
    if (!Number.isFinite(bytes) || bytes <= 0) return '';
    const units = ['B','KB','MB','GB']; let value = bytes, unit = 0;
    while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit++; }
    return `${value >= 10 || unit === 0 ? value.toFixed(0) : value.toFixed(1)} ${units[unit]}`;
  }
  function kindLabel() { return kind === 'word' ? 'Word' : kind === 'ppt' ? 'PowerPoint' : kind === 'sheet' ? 'Spreadsheet' : 'Office'; }
  function setLoading(text) { const detail = el('loading-detail'); if (detail) detail.textContent = text; }
  function setMeta(detail = '') {
    const bits = [kindLabel()]; if (fileBytes > 0) bits.push(formatBytes(fileBytes)); if (detail) bits.push(detail);
    el('doc-meta').textContent = bits.join(' · ');
  }
  function loadScript(name) {
    return new Promise((resolve, reject) => {
      const script = document.createElement('script'); script.src = `assets/${name}`; script.async = true;
      script.onload = resolve; script.onerror = () => reject(new Error(`无法加载 Office 运行时：${name}`));
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
  function clearContent() { content.innerHTML = ''; }
  function showError(error) {
    clearContent();
    const message = error instanceof Error ? error.message : String(error || '未知错误');
    const card = document.createElement('div'); card.className = 'state-card';
    card.innerHTML = '<div class="error-icon">⚠︎</div><strong>Office 渲染失败</strong><p></p><div class="action-row"><button class="action-button" id="fallback-now">系统快速查看</button><button class="action-button secondary" id="retry-now">重新尝试</button></div>';
    card.querySelector('p').textContent = message; content.appendChild(card);
    card.querySelector('#fallback-now').onclick = () => native('fallback');
    card.querySelector('#retry-now').onclick = () => location.reload();
    native('error', { message });
  }
  function showLargeWarning() {
    clearContent();
    const card = document.createElement('div'); card.className = 'state-card';
    card.innerHTML = `<div class="error-icon">◫</div><strong>这是一个较大的办公文件</strong><p>文件大小 ${formatBytes(fileBytes)}。网页渲染需要在内存中展开文档，继续可能占用较多内存。</p><div class="action-row"><button class="action-button" id="continue-large">继续渲染</button><button class="action-button secondary" id="fallback-large">系统快速查看</button></div>`;
    content.appendChild(card);
    card.querySelector('#fallback-large').onclick = () => native('fallback');
    card.querySelector('#continue-large').onclick = async () => {
      clearContent(); const wait = document.createElement('div'); wait.className = 'state-card';
      wait.innerHTML = '<div class="spinner"></div><strong>正在打开办公文件…</strong><span id="loading-detail">读取文件</span>'; content.appendChild(wait);
      try { await render(); } catch (error) { showError(error); }
    };
  }

  function setupCommonToolbar() {
    toolRow.classList.remove('hidden');
    el('fullscreen-button').onclick = () => native('fullscreen');
    el('zoom-out').onclick = () => setZoom(state.zoom - 10);
    el('zoom-in').onclick = () => setZoom(state.zoom + 10);
    el('zoom-label').onclick = () => setZoom(100);
    el('fit-button').onclick = () => toggleFit();
    el('search-next').onclick = () => searchStep(1);
    el('search-prev').onclick = () => searchStep(-1);
    searchInput.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') { event.preventDefault(); searchStep(event.shiftKey ? -1 : 1, true); }
    });
    searchInput.addEventListener('search', () => { if (!searchInput.value) clearSearch(); });
  }
  async function setZoom(value) {
    state.zoom = Math.max(40, Math.min(300, Math.round(value / 10) * 10));
    zoomLabel.textContent = `${state.zoom}%`;
    if (kind === 'ppt' && state.ppt) {
      state.fit = false; await state.ppt.setFitMode('none'); await state.ppt.setZoom(state.zoom); el('fit-button').textContent = '适合'; return;
    }
    const root = kind === 'word' ? document.querySelector('.docx-root') : document.querySelector('.sheet-root');
    if (root) { state.fit = false; root.style.zoom = String(state.zoom / 100); root.style.width = `${10000 / state.zoom}%`; el('fit-button').textContent = '适合'; }
  }
  async function toggleFit() {
    state.fit = !state.fit;
    if (kind === 'ppt' && state.ppt) {
      if (state.fit) { await state.ppt.setFitMode('contain'); state.zoom = 100; zoomLabel.textContent = '适合'; el('fit-button').textContent = '100%'; }
      else { await state.ppt.setFitMode('none'); await state.ppt.setZoom(100); state.zoom = 100; zoomLabel.textContent = '100%'; el('fit-button').textContent = '适合'; }
      return;
    }
    const root = kind === 'word' ? document.querySelector('.docx-root') : document.querySelector('.sheet-root');
    if (!root) return; root.style.zoom = ''; root.style.width = ''; state.zoom = 100; zoomLabel.textContent = '100%'; el('fit-button').textContent = state.fit ? '100%' : '适合';
  }

  function clearSearchMarks() {
    document.querySelectorAll('mark.search-mark').forEach((mark) => { const parent = mark.parentNode; parent.replaceChild(document.createTextNode(mark.textContent || ''), mark); parent.normalize(); });
  }
  function markText(root, query) {
    clearSearchMarks(); if (!query) return [];
    const hits = [], lower = query.toLocaleLowerCase();
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, { acceptNode(node) {
      const parent = node.parentElement;
      if (!parent || ['SCRIPT','STYLE','TEXTAREA','INPUT'].includes(parent.tagName)) return NodeFilter.FILTER_REJECT;
      return node.nodeValue && node.nodeValue.toLocaleLowerCase().includes(lower) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
    }});
    const nodes = []; while (walker.nextNode()) nodes.push(walker.currentNode);
    for (const textNode of nodes) {
      const text = textNode.nodeValue || '', textLower = text.toLocaleLowerCase(); let cursor = 0, index = textLower.indexOf(lower);
      if (index < 0) continue; const fragment = document.createDocumentFragment();
      while (index >= 0) {
        if (index > cursor) fragment.appendChild(document.createTextNode(text.slice(cursor,index)));
        const mark = document.createElement('mark'); mark.className = 'search-mark'; mark.textContent = text.slice(index,index + query.length); fragment.appendChild(mark); hits.push(mark);
        cursor = index + query.length; index = textLower.indexOf(lower,cursor);
      }
      if (cursor < text.length) fragment.appendChild(document.createTextNode(text.slice(cursor)));
      textNode.parentNode.replaceChild(fragment,textNode);
    }
    return hits;
  }
  function updateSearchCount(index,total) { searchCount.textContent = total > 0 ? `${index + 1}/${total}` : ''; }
  function clearSearch() {
    state.genericQuery = ''; state.sheetSearchHits = []; state.sheetSearchIndex = -1;
    if (state.ppt) { state.pptSearchResults = []; state.pptSearchIndex = -1; state.ppt.clearSearchHighlights?.(); state.pptHighlight?.dispose?.(); state.pptHighlight = null; }
    clearSearchMarks(); updateSearchCount(0,0);
  }
  async function searchStep(direction, forceNew = false) {
    const query = searchInput.value.trim(); if (!query) { clearSearch(); return; }
    if (kind === 'ppt' && state.ppt) {
      if (forceNew || state.genericQuery !== query || state.pptSearchResults.length === 0) {
        state.genericQuery = query; state.ppt.clearSearchHighlights?.(); state.pptHighlight?.dispose?.(); state.pptHighlight = null;
        state.pptSearchResults = state.ppt.searchText(query) || []; state.pptSearchIndex = direction < 0 ? state.pptSearchResults.length : -1;
      }
      if (!state.pptSearchResults.length) { updateSearchCount(0,0); return; }
      state.pptSearchIndex = (state.pptSearchIndex + direction + state.pptSearchResults.length) % state.pptSearchResults.length;
      const match = state.pptSearchResults[state.pptSearchIndex]; state.pptHighlight?.dispose?.(); state.pptHighlight = await state.ppt.highlightSearchResult(match);
      updateSearchCount(state.pptSearchIndex,state.pptSearchResults.length); return;
    }
    const root = kind === 'word' ? document.querySelector('.docx-root') : document.querySelector('.sheet-root'); if (!root) return;
    if (forceNew || state.genericQuery !== query || state.sheetSearchHits.length === 0) {
      state.genericQuery = query; state.sheetSearchHits = markText(root,query); state.sheetSearchIndex = direction < 0 ? state.sheetSearchHits.length : -1;
    }
    if (!state.sheetSearchHits.length) { updateSearchCount(0,0); return; }
    state.sheetSearchIndex = (state.sheetSearchIndex + direction + state.sheetSearchHits.length) % state.sheetSearchHits.length;
    state.sheetSearchHits[state.sheetSearchIndex].scrollIntoView({behavior:'smooth',block:'center',inline:'center'});
    updateSearchCount(state.sheetSearchIndex,state.sheetSearchHits.length);
  }

  async function renderWord(buffer) {
    setLoading('加载 Word 渲染器'); await loadScript('jszip.min.js'); await loadScript('docx-preview.min.js');
    if (!window.docx?.renderAsync) throw new Error('docx-preview 初始化失败');
    clearContent(); const root = document.createElement('div'); root.className = 'docx-root'; content.appendChild(root);
    await window.docx.renderAsync(buffer, root, root, {
      inWrapper:true, hideWrapperOnPrint:false, ignoreWidth:false, ignoreHeight:false, ignoreFonts:false,
      breakPages:true, debug:false, experimental:false, renderHeaders:true, renderFooters:true,
      renderFootnotes:true, renderEndnotes:true, ignoreLastRenderedPageBreak:false, useBase64URL:true,
      renderChanges:true, renderComments:true, renderAltChunks:false,
    });
    setupCommonToolbar(); setMeta(`${root.querySelectorAll('section.docx').length || 1} 页`); native('loaded',{detail:'word'});
  }

  function buildPptThumbnails() {
    pptThumbs.innerHTML = ''; pptThumbs.classList.remove('hidden'); const count = state.ppt?.slideCount || 0;
    for (let index = 0; index < count; index++) {
      const item = document.createElement('button'); item.className = 'ppt-thumb'; item.dataset.index = String(index); item.title = `第 ${index + 1} 页`;
      const number = document.createElement('span'); number.className = 'ppt-thumb-number'; number.textContent = String(index + 1); item.appendChild(number);
      item.onclick = () => state.ppt.goToSlide(index,{behavior:'smooth',block:'start'}); pptThumbs.appendChild(item);
    }
    state.pptThumbObserver?.disconnect?.();
    state.pptThumbObserver = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        const target = entry.target, index = Number(target.dataset.index); if (!Number.isFinite(index)) continue;
        if (entry.isIntersecting) {
          if (!state.pptThumbHandles.has(index)) { try { const handle = state.ppt.renderThumbnailToContainer(index,target,{width:112}); if (handle) state.pptThumbHandles.set(index,handle); } catch (_) {} }
        } else {
          const handle = state.pptThumbHandles.get(index); if (handle) { handle.dispose?.(); state.pptThumbHandles.delete(index); [...target.children].forEach((child) => { if (!child.classList.contains('ppt-thumb-number')) child.remove(); }); }
        }
      }
    }, {root:pptThumbs,rootMargin:'180px'});
    pptThumbs.querySelectorAll('.ppt-thumb').forEach((node) => state.pptThumbObserver.observe(node));
  }
  function updatePptActive(index) {
    const count = state.ppt?.slideCount || 0; el('ppt-page').textContent = count ? `${index + 1} / ${count}` : '0 / 0';
    pptThumbs.querySelectorAll('.ppt-thumb').forEach((thumb) => thumb.classList.toggle('active',Number(thumb.dataset.index) === index));
    pptThumbs.querySelector(`.ppt-thumb[data-index="${index}"]`)?.scrollIntoView({block:'nearest',inline:'nearest'});
  }
  async function renderPpt(buffer) {
    setLoading('加载 PowerPoint 渲染器');
    const runtime = await import(new URL('assets/pptx-renderer.browser.es.js',document.baseURI).href);
    if (!runtime?.PptxViewer) throw new Error('pptx-renderer 初始化失败');
    clearContent(); const root = document.createElement('div'); root.className = 'ppt-root'; content.appendChild(root);
    state.ppt = await runtime.PptxViewer.open(buffer,root,{
      renderMode:'list', zipLimits:runtime.RECOMMENDED_ZIP_LIMITS, lazySlides:true, lazyMedia:true, pdfjs:false,
      listOptions:{windowed:true,batchSize:4,initialSlides:4,overscanViewport:1.5},
      onSlideChange:(index) => updatePptActive(index),
      onSlideError:(index,error) => native('error',{message:`第 ${index + 1} 页渲染失败：${error?.message || error}`}),
    });
    pptNav.classList.remove('hidden'); setupCommonToolbar(); buildPptThumbnails(); updatePptActive(state.ppt.currentSlideIndex || 0);
    el('ppt-prev').onclick = () => state.ppt.goToSlide(Math.max(0,state.ppt.currentSlideIndex - 1),{behavior:'smooth'});
    el('ppt-next').onclick = () => state.ppt.goToSlide(Math.min(state.ppt.slideCount - 1,state.ppt.currentSlideIndex + 1),{behavior:'smooth'});
    setMeta(`${state.ppt.slideCount} 页`); native('loaded',{detail:`ppt:${state.ppt.slideCount}`});
  }

  function renderSheetTabs() {
    sheetTabs.innerHTML = ''; const names = state.workbook?.SheetNames || [];
    names.forEach((name,index) => { const button = document.createElement('button'); button.className = `sheet-tab${index === state.sheetIndex ? ' active' : ''}`; button.textContent = name; button.onclick = () => renderSheet(index); sheetTabs.appendChild(button); });
    sheetTabs.classList.toggle('hidden',names.length <= 1);
  }
  function renderSheet(index) {
    state.sheetIndex = Math.max(0,Math.min(index,state.workbook.SheetNames.length - 1)); const name = state.workbook.SheetNames[state.sheetIndex]; const worksheet = state.workbook.Sheets[name];
    clearSearch(); clearContent(); const root = document.createElement('div'); root.className = 'sheet-root'; const scroll = document.createElement('div'); scroll.className = 'sheet-scroll';
    scroll.innerHTML = window.XLSX.utils.sheet_to_html(worksheet,{id:'ff-sheet-table',editable:false,header:'',footer:''}) || '<div class="state-card"><strong>空工作表</strong></div>';
    root.appendChild(scroll); content.appendChild(root); renderSheetTabs(); setupCommonToolbar(); setMeta(`${state.workbook.SheetNames.length} 个工作表 · ${worksheet['!ref'] || '空表'}`);
  }
  async function renderSpreadsheet(buffer) {
    setLoading('加载表格渲染器'); await loadScript('xlsx.full.min.js'); if (!window.XLSX?.read) throw new Error('SheetJS 初始化失败');
    state.workbook = window.XLSX.read(buffer,{type:'array',cellDates:true,cellNF:true,cellText:false});
    if (!state.workbook?.SheetNames?.length) throw new Error('工作簿中没有可显示的工作表');
    renderSheet(0); native('loaded',{detail:`sheet:${state.workbook.SheetNames.length}`});
  }
  async function render() {
    setMeta(); state.buffer = await loadDocumentBuffer();
    if (kind === 'word') return renderWord(state.buffer);
    if (kind === 'ppt') return renderPpt(state.buffer);
    if (kind === 'sheet') return renderSpreadsheet(state.buffer);
    throw new Error(`该 Office 类型暂未启用专用渲染器：${fileName}`);
  }
  async function bootstrap() {
    el('doc-title').textContent = title; el('fullscreen-button').onclick = () => native('fullscreen'); setMeta();
    if (fileBytes >= LARGE_WARNING_BYTES) { showLargeWarning(); return; }
    try { await render(); } catch (error) { showError(error); }
  }

  window.addEventListener('error',(event) => { if (event?.error) native('error',{message:event.error.message || String(event.error)}); });
  window.addEventListener('unhandledrejection',(event) => { const reason = event?.reason; native('error',{message:reason?.message || String(reason || 'Promise rejection')}); });
  window.addEventListener('beforeunload',() => { state.pptThumbObserver?.disconnect?.(); state.pptThumbHandles.forEach((handle) => handle?.dispose?.()); state.pptHighlight?.dispose?.(); state.ppt?.dispose?.(); });
  bootstrap();
})();
