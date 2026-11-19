// Portalled dialogs must lock the app's actual scroller, not just the body.
import { preserveDialogFrame } from '../native/dialogFrame.js'
const locks = new WeakMap()
export function lockDialogBackground(doc = document) {
  const existing = locks.get(doc)
  if (existing) { existing.count++; return () => release(doc) }
  const view = doc.defaultView
  const root = doc.getElementById('root')
  const restoreFrame = preserveDialogFrame(root,view)
  const scrollers = [...doc.querySelectorAll('.health-page-content')]
  const positions = scrollers.map(node => ({ node, top: node.scrollTop, left: node.scrollLeft,
    overflow: node.style.overflowY, height: node.style.height, flex: node.style.flex,
    measuredHeight: node.clientHeight,
    children: [...node.children].map(child => ({ child, hidden: child.hidden })) }))
  const state = { count: 1, root, restoreFrame, inert: root?.inert, overflow: doc.body.style.overflow,
    positions, x: view.scrollX, y: view.scrollY }
  state.restore = () => {
    for (const { node, top, left, children } of positions) if (node.isConnected &&
      children.every(({ child, hidden }) => child.isConnected && child.hidden === hidden)) {
      node.scrollTop = top; node.scrollLeft = left
    }
    if (view.scrollX !== state.x || view.scrollY !== state.y) view.scrollTo(state.x, state.y)
  }
  locks.set(doc, state)
  doc.body.style.overflow = 'hidden'
  if (root) root.inert = true
  for (const { node, measuredHeight } of positions) {
    node.style.height = `${measuredHeight}px`
    node.style.flex = 'none'
    node.style.overflowY = 'hidden'
  }
  // Safari can scroll the background when focusing a portal or resizing chrome.
  for (const { node } of positions) node.addEventListener('scroll', state.restore)
  state.restore()
  return () => release(doc)
}
function release(doc) {
  const state = locks.get(doc)
  if (!state || --state.count) return
  locks.delete(doc)
  state.restoreFrame()
  doc.body.style.overflow = state.overflow
  if (state.root) state.root.inert = state.inert ?? false
  for (const { node, overflow, height, flex } of state.positions) {
    node.removeEventListener('scroll', state.restore)
    node.style.overflowY = overflow
    node.style.height = height
    node.style.flex = flex
  }
  state.restore()
  doc.defaultView.requestAnimationFrame?.(() => {
    if (!locks.has(doc)) state.restore()
  })
}
