import { useCallback, useEffect, useRef, useState } from 'react'
import {
  getStrengthCatalog, getStrengthSessions, getStrengthSession, saveStrengthSession, getTrainingArchive,
  getStrengthDeletions, deleteStrengthSession,
} from '../api/client'
import { STORE_KEY, CATALOG_KEY, DELETIONS_KEY, mergeRecords } from './strength'

function read(key, fallback) {
  try { return JSON.parse(localStorage.getItem(key)) || fallback } catch { return fallback }
}

export default function useStrengthStore() {
  const [records, setRecords] = useState(() => mergeRecords(read(STORE_KEY, {}), [], read(DELETIONS_KEY, [])))
  const [catalog, setCatalog] = useState(() => read(CATALOG_KEY, null))
  const [loading, setLoading] = useState(!catalog)
  const [ready, setReady] = useState(false)
  const [error, setError] = useState('')
  const [storageError, setStorageError] = useState('')
  const [syncing, setSyncing] = useState(false)
  const [deleting, setDeleting] = useState(null)
  const [imported, setImported] = useState(() => read('health-strength-imported-v1', []))
  const recordsRef = useRef(records)
  const running = useRef(false)
  const alive = useRef(true)
  const deletedIds = useRef(new Set(read(DELETIONS_KEY, [])))
  const deleteRunning = useRef(false)

  const commit = useCallback(update => {
    if (!alive.current) return
    const next = typeof update === 'function' ? update(recordsRef.current) : update
    recordsRef.current = next
    setRecords(next)
    try {
      localStorage.setItem(STORE_KEY, JSON.stringify(next))
      setStorageError('')
    } catch {
      setStorageError('本机存储不可用。请保持页面打开，并确认记录已保存到服务器。')
    }
  }, [])

  const forget = useCallback(ids => {
    ids.forEach(id => deletedIds.current.add(id))
    try { localStorage.setItem(DELETIONS_KEY, JSON.stringify([...deletedIds.current].sort())) } catch { /* The server retains deletion markers too. */ }
    commit(old => mergeRecords(old, [], deletedIds.current))
  }, [commit])

  const refresh = useCallback(async () => {
    const results = await Promise.allSettled([getStrengthCatalog(), getStrengthSessions(), getTrainingArchive(120), getStrengthDeletions()])
    if (!alive.current) return
    if (results[0].status === 'fulfilled') {
      setCatalog(results[0].value)
      try { localStorage.setItem(CATALOG_KEY, JSON.stringify(results[0].value)) } catch { /* Records have their own storage status. */ }
    }
    if (results[3].status === 'fulfilled') forget(results[3].value.map(row => row.id))
    if (results[1].status === 'fulfilled') commit(old => mergeRecords(old, results[1].value, deletedIds.current))
    if (results[2].status === 'fulfilled') {
      const data = results[2].value.filter(w => w.source !== 'local')
      setImported(data)
      try { localStorage.setItem('health-strength-imported-v1', JSON.stringify(data)) } catch { /* Optional history cache. */ }
    }
    const failed = [results[0], results[1], results[3]].find(r => r.status === 'rejected')
    setError(failed ? '暂时无法连接服务器，已有的本机记录仍可继续。' : '')
    setLoading(false)
    setReady(true)
  }, [commit, forget])

  const sync = useCallback(async () => {
    if (running.current || !navigator.onLine) return
    running.current = true
    setSyncing(true)
    try {
      // Serial saves make rapid edits and an unacknowledged retry safe.
      while (alive.current) {
        const record = Object.values(recordsRef.current).find(r => r.dirty && !r.blocked)
        if (!record) break
        const snapshot = JSON.stringify(record.session)
        const id = record.session.id
        try {
          const saved = await saveStrengthSession(record.session, record.version)
          if (!alive.current) break
          commit(old => {
            const current = old[id]
            if (!current || deletedIds.current.has(id)) return old
            const unchanged = JSON.stringify(current.session) === snapshot
            return { ...old, [id]: { ...current, version: saved.version, dirty: !unchanged, blocked: null } }
          })
          setError('')
        } catch (err) {
          if (!alive.current) break
          if (err.status === 410) { forget([id]); continue }
          if (!recordsRef.current[id]) continue
          if (err.status === 409 || err.status === 422) {
            let server = null
            if (err.status === 409) {
              try { server = await getStrengthSession(id) } catch { /* New unsynced sessions can have no server record. */ }
            }
            if (err.status === 422 && JSON.stringify(recordsRef.current[id].session) !== snapshot) continue
            commit(old => !old[id] || deletedIds.current.has(id) ? old : ({ ...old, [id]: { ...old[id], blocked: { message: err.message, server, status: err.status } } }))
          } else setError('尚未同步到服务器，记录已留在本机；联网后会自动重试。')
          break
        }
      }
    } finally {
      running.current = false
      if (alive.current) setSyncing(false)
    }
  }, [commit, forget])

  const remove = useCallback(async id => {
    if (deleteRunning.current) throw new Error('正在删除，请稍候。')
    const record = recordsRef.current[id]
    if (!record || deletedIds.current.has(id)) return
    if (!navigator.onLine) throw new Error('请联网后删除，记录仍保留。')
    if (record.dirty || record.blocked) throw new Error('请先将这场训练同步到服务器，再删除。')
    deleteRunning.current = true
    setDeleting(id)
    try {
      const deleted = await deleteStrengthSession(id, record.version)
      if (alive.current) { forget([deleted.id]); setError('') }
    } catch (err) {
      if (err.status === 410 || err.status === 404) { if (alive.current) forget([id]); return }
      if (err.uncertain) {
        try {
          const current = await getStrengthSession(id, 4000)
          if (alive.current) commit(old => mergeRecords(old, [current], deletedIds.current))
        } catch (confirmation) {
          if (confirmation.status === 404 || confirmation.status === 410) { if (alive.current) forget([id]); return }
        }
        throw new Error('暂未确认删除结果，记录暂时保留。请重试，已删除的记录不会重复删除。')
      }
      if (err.status === 409) refresh().catch(() => {})
      throw err
    } finally {
      deleteRunning.current = false
      if (alive.current) setDeleting(null)
    }
  }, [forget, refresh, commit])

  const load = useCallback(async id => {
    const record = await getStrengthSession(id)
    if (alive.current) commit(old => mergeRecords(old, [record], deletedIds.current))
  }, [commit])

  useEffect(() => {
    alive.current = true
    refresh()
    const online = () => { refresh(); sync() }
    const visible = () => { if (document.visibilityState !== 'hidden') refresh() }
    const storage = event => { if (event.key === DELETIONS_KEY) forget(read(DELETIONS_KEY, [])) }
    const sessionEnded = () => { alive.current = false }
    window.addEventListener('online', online)
    document.addEventListener('visibilitychange', visible)
    window.addEventListener('storage', storage)
    window.addEventListener('health-session-ended', sessionEnded)
    const retry = window.setInterval(sync, 15000)
    return () => { alive.current = false; window.removeEventListener('online', online); document.removeEventListener('visibilitychange', visible); window.removeEventListener('storage', storage); window.removeEventListener('health-session-ended', sessionEnded); clearInterval(retry) }
  }, [refresh, sync, forget])

  useEffect(() => {
    const timer = window.setTimeout(sync, 600)
    return () => clearTimeout(timer)
  }, [records, sync])

  useEffect(() => {
    if (alive.current && catalog) {
      try { localStorage.setItem(CATALOG_KEY, JSON.stringify(catalog)) } catch { /* Optional cache. */ }
    }
  }, [catalog])

  const put = useCallback(session => {
    if (deletedIds.current.has(session.id)) return
    commit(old => {
      const previous = old[session.id]
      return { ...old, [session.id]: { ...previous, session, version: previous?.version || 0, dirty: true,
        blocked: previous?.blocked?.status === 409 && !(session.status === 'discarded' && !previous.blocked.server) ? previous.blocked : null } }
    })
  }, [commit])

  const resolve = useCallback((id, useLocal) => {
    commit(old => {
      const record = old[id]
      if (!record || deletedIds.current.has(id)) return old
      const server = record.blocked?.server
      if (!server) return { ...old, [id]: { ...record, blocked: null } }
      // Keep the alternative copy in storage when the user resolves a conflict.
      return { ...old, [id]: useLocal
        ? { ...record, version: server.version, dirty: true, blocked: null, alternative: server.session }
        : { ...server, dirty: false, alternative: record.session } }
    })
  }, [commit])

  const history = Object.values(records).sort((a, b) => b.session.started_at.localeCompare(a.session.started_at))
  return { records, history, imported, catalog, setCatalog, loading, ready, error, storageError, syncing,
    put, refresh, sync, resolve, remove, load, deleting, deletedIds: deletedIds.current, active: history.find(r => r.session.status === 'active') }
}
