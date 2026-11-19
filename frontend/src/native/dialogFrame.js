import { hasNativeCapability } from './bridge.js'

const frames = new WeakMap()
// Older UIKit hosts remove their navigation bar while a web sheet is open.
// Keep the covered page at the same screen position inside the enlarged WK view.
export function preserveDialogFrame(root, view) {
  if (!root || !hasNativeCapability('chrome-v1',view)) return () => {}
  const existing = frames.get(root)
  if (existing) { existing.count++; return () => release(root) }
  const state = { count:1, view, height:view.innerHeight, width:view.innerWidth,
    originalHeight:root.style.height, transform:root.style.transform, shift:0 }
  const overlay = hasNativeCapability('bottom-overlay-v1',view)
  state.update = () => {
    if (view.innerWidth !== state.width) return
    const growth = view.innerHeight-state.height
    if (growth < 0) return // A keyboard does not move the host's navigation origin.
    // Non-overlay hosts also reclaim tab-bar height; only their 44pt navigation
    // bar (32pt in landscape) moves the top edge. Overlay hosts reclaim just top.
    state.shift = overlay ? growth : Math.min(growth,state.width>state.height?32:44)
    root.style.height = `${state.height}px`
    root.style.transform = `translateY(${state.shift}px)${state.transform?' '+state.transform:''}`
  }
  frames.set(root,state)
  view.addEventListener('resize',state.update)
  return () => release(root)
}
function release(root) {
  const state=frames.get(root)
  if (!state || --state.count) return
  let attempts=0
  const finish=()=>{
    if(state.count)return
    state.update()
    if(state.shift>0 && attempts++<30 && state.view.requestAnimationFrame){state.view.requestAnimationFrame(finish);return}
    state.view.removeEventListener('resize',state.update)
    root.style.height=state.originalHeight;root.style.transform=state.transform
    frames.delete(root)
  }
  finish()
}
