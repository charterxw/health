import { useEffect, useState } from 'react'
import { getSessionReview, generateSessionReview } from '../api/client'

export default function useSessionReview(session, serverSaved, visible) {
  const key = JSON.stringify([session.id, session.ended_at, session.exercises])
  const [state, setState] = useState(null)
  const [attempt, setAttempt] = useState(0)
  useEffect(() => {
    if (!serverSaved || !visible || session.status !== 'completed') return
    let live = true, timer
    const controller = new AbortController()
    const started = Date.now()
    async function load(first = false) {
      try {
        let data = await getSessionReview(session.id, controller.signal)
        if (live && first && (data.status === 'idle' || attempt > 0 && data.status === 'error')) data = await generateSessionReview(session.id, controller.signal)
        if (!live) return
        setState({ key, data })
        if (data.status === 'pending' && Date.now() - started < 185000) timer = setTimeout(() => load(), 3000)
      } catch (error) {
        if (live && error.name !== 'AbortError') setState({ key, error: true })
      }
    }
    load(true)
    return () => { live = false; controller.abort(); clearTimeout(timer) }
  }, [key, serverSaved, visible, attempt])
  const current = state?.key === key ? state : null
  return { data: current?.data, error: current?.error, retry: () => setAttempt(n => n + 1) }
}
