import { useRef, useState } from 'react'

export default function TrainingNumberInput({ value, decimal = false, onValueChange, onActivate, ...props }) {
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState('')
  const firstTap = useRef(false)

  return <input {...props} type="text" inputMode={decimal ? 'decimal' : 'numeric'}
    autoComplete="off" autoCorrect="off" spellCheck={false}
    value={editing ? draft : value ?? ''}
    onPointerDown={e => { firstTap.current = document.activeElement !== e.currentTarget }}
    onFocus={e => {
      setDraft(String(value ?? '')); setEditing(true)
      onActivate?.()
      e.currentTarget.select()
    }}
    onClick={e => {
      // Touch selection can replace the focus selection before click is fired.
      if (firstTap.current) e.currentTarget.select()
      firstTap.current = false
    }}
    onChange={e => {
      const text = e.target.value
      if (!(decimal ? /^\d*(?:[.,]\d*)?$/ : /^\d*$/).test(text)) return
      const normalized = text.replace(',', '.')
      if (onValueChange(normalized === '.' ? '' : normalized) === false) return
      setDraft(text)
    }}
    onKeyDown={e=>{if(e.key!=='Enter')return;e.preventDefault();const row=e.currentTarget.closest('.st-set-row');const inputs=row?[...row.querySelectorAll('input:not(:disabled)')]:[];const next=inputs[inputs.indexOf(e.currentTarget)+1];if(next)next.focus();else e.currentTarget.blur()}}
    onBlur={() => { setEditing(false); firstTap.current = false }} />
}
