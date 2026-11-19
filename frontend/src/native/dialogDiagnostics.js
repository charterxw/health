import { hasNativeCapability } from './bridge.js'

// Temporary geometry-only capture for the physical WKWebView discrepancy.
export function observeDialogGeometry(doc = document) {
  const view=doc.defaultView
  if(!hasNativeCapability('chrome-v1',view))return()=>{}
  const started=view.performance.now(),samples=[]
  const cycle=view.crypto.randomUUID()
  let done=false
  const rect=n=>n?.getBoundingClientRect()
  const capture=stage=>{
    const root=doc.getElementById('root'),page=doc.querySelector('.health-page-content')
    const r=rect(root),p=rect(page),h=rect(doc.querySelector('.home-heading'))
    let translate=null
    try{translate=new view.DOMMatrixReadOnly(view.getComputedStyle(root).transform).m42}catch{}
    const v=view.visualViewport
    samples.push({stage,elapsed_ms:Math.min(120000,Math.round(view.performance.now()-started)),inner_height:view.innerHeight,inner_width:view.innerWidth,
      outer_height:view.outerHeight,client_height:doc.documentElement.clientHeight,visual_height:v?.height??null,
      visual_offset_top:v?.offsetTop??null,visual_page_top:v?.pageTop??null,visual_scale:v?.scale??null,
      root_top:r?.top??null,root_height:r?.height??null,root_translate_y:translate,
      page_top:p?.top??null,page_height:p?.height??null,heading_top:h?.top??null,
      scroll_top:page?.scrollTop??null,window_scroll_y:view.scrollY})
    if(samples.length>24)samples.splice(1,1)
  }
  const send=()=>{
    const request=view.fetch?.bind(view)||globalThis.fetch
    request('/api/ui/layout-diagnostics',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json'},
      keepalive:true,body:JSON.stringify({build:'dialog-diagnostics-20261118',cycle,
        native_chrome:true,bottom_overlay:hasNativeCapability('bottom-overlay-v1',view),samples})}).catch(()=>{})
  }
  capture('before')
  const resize=()=>{if(!done)capture('resize')}
  view.addEventListener('resize',resize);view.visualViewport?.addEventListener('resize',resize)
  const timers=[100,500,1500].map(delay=>view.setTimeout(()=>{if(!done){capture('settled');send()}},delay))
  return()=>{
    done=true;capture('closing');timers.forEach(t=>view.clearTimeout(t))
    view.removeEventListener('resize',resize);view.visualViewport?.removeEventListener('resize',resize)
    view.setTimeout(()=>{capture('closed');send()},200)
  }
}
