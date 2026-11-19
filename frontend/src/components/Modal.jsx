import { useEffect, useLayoutEffect, useId, useRef } from 'react'
import { createPortal } from 'react-dom'
import HealthIcon from './HealthIcon'
import '../training/strength.css'
import { lockDialogBackground } from '../training/dialogScroll'
import { observeDialogGeometry } from '../native/dialogDiagnostics'

const useBrowserLayoutEffect = typeof window === 'undefined' ? useEffect : useLayoutEffect

export default function Modal({ title, children, onClose, wide = false, centered = false }) {
  const titleId = useId()
  const ref = useRef(null)
  const closeRef = useRef(onClose)
  closeRef.current = onClose
  useBrowserLayoutEffect(() => {
    const previous = document.activeElement
    const stopObserving = observeDialogGeometry()
    const unlock = lockDialogBackground()
    // A small visible target avoids Safari trying to reveal the entire sheet.
    ref.current?.querySelector('[aria-label="关闭"]')?.focus({ preventScroll: true })
    const keydown = e => {
      if (e.key === 'Escape') closeRef.current()
      if (e.key !== 'Tab') return
      const nodes = [...ref.current.querySelectorAll('button, a[href], input, select, textarea, [tabindex="0"]')].filter(n => !n.disabled)
      const first = nodes[0], last = nodes[nodes.length - 1]
      if (e.shiftKey && (document.activeElement === first || document.activeElement === ref.current)) { e.preventDefault(); last?.focus() }
      else if (!e.shiftKey && (document.activeElement === last || document.activeElement === ref.current)) { e.preventDefault(); first?.focus() }
    }
    document.addEventListener('keydown', keydown)
    return () => { stopObserving(); unlock(); document.removeEventListener('keydown', keydown); if (previous?.isConnected) previous.focus({ preventScroll: true }) }
  }, [])
  return createPortal(<div className={`st-modal-backdrop${centered ? ' is-centered' : ''}`} onClick={onClose}>
    <section ref={ref} tabIndex={-1} role="dialog" aria-modal="true" aria-labelledby={titleId} className={`st-modal ${wide ? 'wide' : ''}`} onClick={e => e.stopPropagation()}>
      <header><h2 id={titleId}>{title}</h2><button className="st-icon-button" onClick={onClose} aria-label="关闭"><HealthIcon name="close" size={20} /></button></header>
      {children}
    </section>
  </div>, document.body)
}

