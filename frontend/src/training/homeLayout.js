// Measure usable app space; ignore temporary keyboard/native chrome changes
// while a sheet covers the page so opening a tile never refits its background.
export function watchHomeLayout(node) {
  const page = node?.closest('.health-page-content')
  if (!page) return () => {}
  const view = node.ownerDocument.defaultView
  const measure = () => {
    if (node.ownerDocument.querySelector('.st-modal-backdrop')) return
    const style = view.getComputedStyle(page)
    const height = page.clientHeight - (parseFloat(style.paddingTop) || 0) - (parseFloat(style.paddingBottom) || 0)
    if (height > 0) {
      node.style.setProperty('--home-available-height', `${height}px`)
      node.style.setProperty('--home-fit', `${Math.max(0,Math.min(1,(height-620)/100))}`)
    }
  }
  const observer = view.ResizeObserver ? new view.ResizeObserver(measure) : null
  measure()
  observer?.observe(page)
  view.addEventListener('resize', measure)
  return () => { observer?.disconnect(); view.removeEventListener('resize', measure) }
}
