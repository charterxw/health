export function watchMobileViewport(browser = window) {
  const style = browser.document.documentElement.style
  const viewport = browser.visualViewport
  const mobile = browser.matchMedia('(max-width: 1000px)')
  const update = () => {
    const field = browser.document.activeElement
    const editing = /^(INPUT|TEXTAREA)$/.test(field?.tagName || '') || field?.isContentEditable
    const layoutHeight = browser.document.documentElement.clientHeight || browser.innerHeight
    // In standalone iOS, visualViewport may be shorter than the app window even
    // without a keyboard. It must not set the permanent size of the app frame.
    if (mobile.matches && editing && viewport?.scale === 1 && layoutHeight - viewport.height > 80) {
      style.setProperty('--keyboard-viewport-height', `${Math.round(viewport.height)}px`)
    } else style.removeProperty('--keyboard-viewport-height')
  }
  update()
  viewport?.addEventListener('resize', update)
  browser.addEventListener('resize', update)
  browser.document.addEventListener('focusin', update)
  browser.document.addEventListener('focusout', update)
  mobile.addEventListener('change', update)
  return () => {
    viewport?.removeEventListener('resize', update)
    browser.removeEventListener('resize', update)
    browser.document.removeEventListener('focusin', update)
    browser.document.removeEventListener('focusout', update)
    mobile.removeEventListener('change', update)
    style.removeProperty('--keyboard-viewport-height')
  }
}
