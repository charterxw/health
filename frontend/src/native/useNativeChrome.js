import { useEffect } from 'react'
import { hasNativeCapability, publishNativeChrome } from './bridge'

export default function useNativeChrome(state) {
  const key = JSON.stringify(state)
  useEffect(() => {
    if (!hasNativeCapability('chrome-v1')) return
    let last
    const update = (force = false) => {
      const chrome = { ...JSON.parse(key), webDialogOpen: Boolean(document.querySelector('.st-modal-backdrop, [aria-modal="true"]')) }
      if (hasNativeCapability('bottom-overlay-v1')) chrome.bottomOverlay = true
      const value = JSON.stringify(chrome)
      if (value === last && !force) return
      last = value
      publishNativeChrome(chrome, force)
    }
    const resume = () => update(true)
    update()
    const observer = new MutationObserver(() => update())
    observer.observe(document.body, { childList: true, subtree: true })
    window.addEventListener('health-native-resume', resume)
    return () => { observer.disconnect(); window.removeEventListener('health-native-resume', resume) }
  }, [key])
}
