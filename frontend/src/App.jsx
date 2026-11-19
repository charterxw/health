import { useState, useEffect, useRef } from 'react'
import HealthShell from './components/HealthShell'
import Dashboard from './components/Dashboard'
import StrengthTraining from './components/StrengthTraining'
import SleepTab from './components/SleepTab'
import Login from './components/Login'
import { getAppAuthStatus, getAuthStatus, getIntegrationStatus, logoutApp, removeWebPushSubscription } from './api/client'
import { hasPendingTraining, clearHealthCache } from './training/privacy'
import './shell.css'
import { publishNativeWorkout, isNativeHealth, publishNativeChrome } from './native/bridge'

const VALID = ['dashboard', 'strength', 'workout', 'sleep']

export default function App() {
  const [isAppAuthed, setIsAppAuthed] = useState(null)
  const [activeTab, setActiveTab] = useState(
    () => (VALID.includes(window.location.hash.slice(1)) ? window.location.hash.slice(1) : 'dashboard')
  )
  const [authed, setAuthed] = useState(null)
  const [integrations, setIntegrations] = useState(null)
  const [homeTrainingRequest, setHomeTrainingRequest] = useState(null)
  const [signOutError, setSignOutError] = useState('')
  const [signingOut, setSigningOut] = useState(false)
  const headerRef = useRef(null)

  const signOut = async () => {
    if (signingOut) return
    if (hasPendingTraining()) { setSignOutError('训练尚未同步，请联网完成同步后再退出。'); return }
    setSigningOut(true)
    try {
      const subscriptionId = localStorage.getItem('health-webpush-subscription-v1')
      if (subscriptionId) {
        await removeWebPushSubscription(subscriptionId)
        const registration = await navigator.serviceWorker?.getRegistration('/')
        const subscription = await registration?.pushManager.getSubscription()
        if (subscription) await subscription.unsubscribe()
      }
      await logoutApp()
      window.dispatchEvent(new Event('health-session-ended'))
      clearHealthCache()
      if (isNativeHealth()) publishNativeWorkout(null, true)
      setSignOutError(''); setIsAppAuthed(false)
    } catch (_) { setSignOutError('未能完成退出，请联网后重试。') }
    finally { setSigningOut(false) }
  }

  useEffect(() => {
    if (!isAppAuthed) publishNativeChrome({ protocolVersion: 1, authenticated: false, tab: activeTab,
      screen: 'home', title: 'Health', workoutID: null, googleConnected: null, webDialogOpen: false })
  }, [isAppAuthed, activeTab])

  useEffect(() => {
    if (!isAppAuthed || signingOut || !headerRef.current) return
    const header = headerRef.current
    const resize = () => { if (header.isConnected) document.documentElement.style.setProperty('--app-header-height', `${header.getBoundingClientRect().height}px`) }
    const observer = new ResizeObserver(resize)
    observer.observe(header)
    resize()
    return () => observer.disconnect()
  }, [isAppAuthed, signingOut])

  useEffect(() => {
    const handleUnauthorized = () => { if (isNativeHealth()) publishNativeWorkout(null, true); setIsAppAuthed(false) }
    window.addEventListener('unauthorized', handleUnauthorized)
    return () => window.removeEventListener('unauthorized', handleUnauthorized)
  }, [])

  useEffect(() => {
    getAppAuthStatus()
      .then(d => setIsAppAuthed(Boolean(d.authenticated)))
      .catch(() => setIsAppAuthed(false))
  }, [])

  useEffect(() => {
    const media = window.matchMedia('(prefers-color-scheme: dark)')
    const apply = () => document.documentElement.classList.toggle('dark', media.matches)
    apply()
    media.addEventListener('change', apply)
    return () => media.removeEventListener('change', apply)
  }, [])

  useEffect(() => {
    if (!isAppAuthed) return;
    getAuthStatus().then(d => setAuthed(d.authenticated)).catch(() => setAuthed(false))
    getIntegrationStatus().then(setIntegrations).catch(() => setIntegrations(null))
  }, [isAppAuthed])

  useEffect(() => {
    window.location.hash = activeTab
  }, [activeTab])

  // Respond to browser back/forward and external hash changes
  useEffect(() => {
    const onHashChange = () => {
      const next = window.location.hash.slice(1)
      if (VALID.includes(next)) setActiveTab(next)
    }
    window.addEventListener('hashchange', onHashChange)
    return () => window.removeEventListener('hashchange', onHashChange)
  }, [])

  if (isAppAuthed === null) {
    return <div className="min-h-screen flex items-center justify-center"><div className="w-7 h-7 border-2 border-[var(--text-secondary)] border-t-transparent rounded-full animate-spin" /></div>
  }

  if (!isAppAuthed) {
    return <Login onLoginSuccess={() => setIsAppAuthed(true)} />
  }
  if (signingOut) return <div className="min-h-screen flex items-center justify-center" role="status">正在退出…</div>

  return (
    <HealthShell activeTab={activeTab} setActiveTab={setActiveTab} authed={authed}
      integrations={integrations} headerRef={headerRef}
      onSignOut={signOut} signOutError={signOutError}>
      <div hidden={activeTab !== 'dashboard'}><Dashboard active={activeTab === 'dashboard'}
        onSleep={() => setActiveTab('sleep')} onTraining={request => { setHomeTrainingRequest({ ...request, nonce: Date.now() }); setActiveTab('strength') }} /></div>
      <StrengthTraining active={activeTab === 'strength'} showRecords={activeTab === 'workout'}
        homeRequest={homeTrainingRequest}
        onOpenTraining={() => setActiveTab('strength')} onReturnToRecords={() => setActiveTab('workout')} />
      {activeTab === 'sleep' && <SleepTab />}
    </HealthShell>
  )
}
