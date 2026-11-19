import { useEffect, useRef, useState } from 'react'
import { getWorkoutPhysiology, refreshWorkoutPhysiology, selectWorkoutHeartSource } from '../api/client'

// Poll our cache only while this report is visible. The server owns cloud retries.
export default function useWorkoutPhysiology(session, serverSaved, visible) {
  const key = `${session.id}:${session.started_at}:${session.ended_at}`
  const [result, setResult] = useState(null)
  const [intent, setIntent] = useState(null)
  const consumed = useRef(null)
  const appVisit = useRef(null)
  const data = result?.key === key ? result.data : null
  const error = result?.key === key ? result.error : ''
  const busy = result?.key === key && result.busy

  useEffect(() => {
    if (!serverSaved || !visible) return
    let stopped = false, timer, controller, generation = 0
    let cached = result?.key === key ? result.data : null
    async function read() {
      if (stopped || document.visibilityState === 'hidden') return
      controller?.abort()
      const requestController = new AbortController()
      const ticket = ++generation
      controller = requestController
      const timeout = setTimeout(() => requestController.abort(), 20000)
      setResult({ key, data: cached, error: '', busy: true })
      try {
        let next
        if (intent?.key === key && consumed.current !== intent) {
          consumed.current = intent
          next = intent.source
            ? await selectWorkoutHeartSource(session.id, intent.source, requestController.signal)
            : await refreshWorkoutPhysiology(session.id, requestController.signal)
        } else next = await getWorkoutPhysiology(session.id, requestController.signal)
        if (stopped || ticket !== generation || requestController.signal.aborted) return
        cached = next
        setResult({ key, data: next, error: '', busy: false })
      } catch (error) {
        if (stopped || ticket !== generation || document.visibilityState === 'hidden') return
        setResult({ key, data: cached, error: error.status === 401 ? '请重新登录后查看。' : '暂时无法读取报告，稍后会自动重试。', busy: false })
      } finally {
        clearTimeout(timeout)
        if (!stopped && ticket === generation && document.visibilityState !== 'hidden') timer = setTimeout(read, cached?.status === 'ready' && !cached.syncing ? 60000 : 15000)
      }
    }
    function onVisibility() {
      clearTimeout(timer)
      if (document.visibilityState === 'hidden') {
        if (appVisit.current?.key === key) appVisit.current.left = true
        generation++; controller?.abort()
      } else if (appVisit.current?.key === key && appVisit.current.left) {
        appVisit.current = null
        setIntent({ key })
      } else read()
    }
    read()
    document.addEventListener('visibilitychange', onVisibility)
    window.addEventListener('pageshow', onVisibility)
    return () => {
      stopped = true
      clearTimeout(timer)
      controller?.abort()
      document.removeEventListener('visibilitychange', onVisibility)
      window.removeEventListener('pageshow', onVisibility)
    }
    // result is the cache, not a trigger for another request.
  }, [key, serverSaved, visible, intent])

  return {
    data, error, busy,
    refresh: () => setIntent({ key }),
    selectSource: source => setIntent({ key, source }),
    openGoogleHealth: () => { appVisit.current = { key, left: false } },
  }
}
