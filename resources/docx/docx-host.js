(() => {
  'use strict';
  const viewport=document.getElementById('viewport');
  const doc=document.getElementById('doc');
  const state=document.getElementById('state');
  const search=document.getElementById('search');
  const count=document.getElementById('count');
  let zoom=100,hits=[],hit=-1;

  const native=(type,extra={})=>{try{window.webkit?.messageHandlers?.ffDocx?.postMessage({type,...extra});}catch(_){}};
  const setZoom=(v)=>{zoom=Math.max(50,Math.min(250,Math.round(v/10)*10));doc.style.zoom=String(zoom/100);doc.style.width=`${10000/zoom}%`;document.getElementById('zoom').textContent=`${zoom}%`;};
  const clearHits=()=>{document.querySelectorAll('mark.ff-hit').forEach(m=>{const p=m.parentNode;if(!p)return;p.replaceChild(document.createTextNode(m.textContent||''),m);p.normalize();});hits=[];hit=-1;count.textContent='';};
  const buildHits=(q)=>{clearHits();if(!q)return;const lower=q.toLocaleLowerCase();const walker=document.createTreeWalker(doc,NodeFilter.SHOW_TEXT,{acceptNode(n){const p=n.parentElement;if(!p||['SCRIPT','STYLE'].includes(p.tagName))return NodeFilter.FILTER_REJECT;return (n.nodeValue||'').toLocaleLowerCase().includes(lower)?NodeFilter.FILTER_ACCEPT:NodeFilter.FILTER_REJECT;}});const nodes=[];while(walker.nextNode())nodes.push(walker.currentNode);for(const node of nodes){const text=node.nodeValue||'',lo=text.toLocaleLowerCase();let pos=0,i=lo.indexOf(lower);if(i<0)continue;const f=document.createDocumentFragment();while(i>=0){if(i>pos)f.appendChild(document.createTextNode(text.slice(pos,i)));const m=document.createElement('mark');m.className='ff-hit';m.textContent=text.slice(i,i+q.length);f.appendChild(m);hits.push(m);pos=i+q.length;i=lo.indexOf(lower,pos);}if(pos<text.length)f.appendChild(document.createTextNode(text.slice(pos)));node.parentNode.replaceChild(f,node);}}
  const step=(dir,newQuery=false)=>{const q=search.value.trim();if(!q){clearHits();return;}if(newQuery||!hits.length)buildHits(q);if(!hits.length){count.textContent='0';return;}if(hit>=0)hits[hit].classList.remove('ff-current');hit=(hit+dir+hits.length)%hits.length;hits[hit].classList.add('ff-current');hits[hit].scrollIntoView({block:'center',inline:'nearest',behavior:'smooth'});count.textContent=`${hit+1}/${hits.length}`;};

  document.getElementById('minus').onclick=()=>setZoom(zoom-10);
  document.getElementById('plus').onclick=()=>setZoom(zoom+10);
  document.getElementById('zoom').onclick=()=>setZoom(100);
  document.getElementById('prev').onclick=()=>step(-1);
  document.getElementById('next').onclick=()=>step(1);
  search.addEventListener('keydown',e=>{if(e.key==='Enter'){e.preventDefault();step(e.shiftKey?-1:1,true);}});
  search.addEventListener('search',()=>{if(!search.value)clearHits();});

  (async()=>{
    try{
      if(!window.docx?.renderAsync)throw new Error('DOCX 运行时未加载');
      const response=await fetch('document',{cache:'no-store'});
      if(!response.ok&&response.status)throw new Error(`读取文件失败：${response.status}`);
      const buffer=await response.arrayBuffer();
      if(!buffer.byteLength)throw new Error('文件为空');
      await window.docx.renderAsync(buffer,doc,null,{className:'docx',inWrapper:true,breakPages:true,renderHeaders:true,renderFooters:true,renderFootnotes:true,useBase64URL:true});
      state.classList.add('hidden');
      native('loaded');
    }catch(error){
      state.textContent=`Word 文档渲染失败：${error?.message||error}`;
      native('error',{message:String(error?.message||error)});
    }
  })();
})();
