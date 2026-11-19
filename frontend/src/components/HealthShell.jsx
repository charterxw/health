import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import Navigation, { pages } from './Navigation'
import HealthIcon from './HealthIcon'
import TrainingHeaderContext from './TrainingHeaderContext'
import Modal from './Modal'
import WebPushControl from './WebPushControl'
import NativeTrainingSettings from '../native/NativeTrainingSettings'
import { isNativeHealth, hasNativeCapability } from '../native/bridge'
import useNativeChrome from '../native/useNativeChrome'
import NativeScreenContext from '../native/NativeScreenContext'
import { watchMobileViewport } from '../training/viewport'

const useBrowserLayoutEffect = typeof window === 'undefined' ? useEffect : useLayoutEffect

export default function HealthShell({ activeTab, setActiveTab, authed, integrations, headerRef, onSignOut, signOutError, children }) {
  const page = pages.find(p => p.id === activeTab) || pages[0]
  const [trainingHeader, setTrainingHeader] = useState(null)
  const [settingsOpen, setSettingsOpen] = useState(() => !isNativeHealth() &&
    new URLSearchParams(globalThis.window?.location.search).get('notifications') === '1')
  const [trainingScreen, setTrainingScreen] = useState({ screen: 'home', title: '训练', workoutID: null })
  const contentRef = useRef(null)
  const detail = ['strength','workout'].includes(activeTab) ? trainingScreen : { screen: 'home', title: page.label, workoutID: null }
  useNativeChrome({ protocolVersion: 1, authenticated: true, tab: activeTab,
    ...detail, googleConnected: authed ?? null })
  useEffect(() => {
    if (!hasNativeCapability('chrome-v1')) return
    const action = event => {
      const value = event.detail
      if (value?.type === 'selectTab' && pages.some(page => page.id === value.tab)) setActiveTab(value.tab)
      if (value?.type === 'signOut') onSignOut?.()
    }
    window.addEventListener('health-native-action', action)
    return () => window.removeEventListener('health-native-action', action)
  }, [setActiveTab, onSignOut])
  useEffect(() => watchMobileViewport(), [])
  useBrowserLayoutEffect(() => { if (contentRef.current) contentRef.current.scrollTop = 0 }, [activeTab])

  return <NativeScreenContext.Provider value={setTrainingScreen}><TrainingHeaderContext.Provider value={trainingHeader}><div className="health-shell">
    <aside className="health-sidebar">
      <button className="health-brand" onClick={() => setActiveTab('dashboard')} aria-label="Health 总览">
        <span className="health-brand-mark"><HealthIcon size={24} /></span>
        <span><strong>Health</strong><small>健康与训练</small></span>
      </button>
      <Navigation activeTab={activeTab} setActiveTab={setActiveTab} />
      <div className="health-sidebar-footer">
        <span><i className={authed ? 'connected' : ''} />{authed ? 'Google Health 已连接' : authed === null ? '正在读取连接状态…' : 'Google Health 未连接'}</span>
        {integrations?.chatgpt && <small>{integrations.chatgpt.connected ? 'AI 观察已连接' : 'AI 观察未连接'}</small>}
      </div>
    </aside>
    <main className="health-workspace">
      <header ref={headerRef} className="health-page-header">
        <div><p className="health-eyebrow">{page.description}</p><h1>{page.label}</h1></div>
        <div className="health-header-tools">
          {authed === false && <a href="/api/auth/login" className="health-connect">连接 Google Health</a>}
          <button className="health-icon-button" title="设置" aria-label="设置" onClick={() => setSettingsOpen(true)}><HealthIcon name="settings" /></button>
          <button className="health-icon-button" title="刷新页面" aria-label="刷新页面" onClick={() => window.location.reload()}><HealthIcon name="refresh" /></button>
          <button className="health-icon-button" title="退出登录" aria-label="退出登录" onClick={onSignOut}><HealthIcon name="logout" /></button>
        </div>
      </header>
      <div className="health-training-header" ref={setTrainingHeader} />
      <div className="health-page-content" ref={contentRef}>{signOutError && <p className="home-status" role="alert">{signOutError}</p>}{children}</div>
    </main>
  </div>{settingsOpen && <Modal title="设置" onClose={() => setSettingsOpen(false)}>{isNativeHealth() ? <NativeTrainingSettings /> : <WebPushControl />}</Modal>}</TrainingHeaderContext.Provider></NativeScreenContext.Provider>
}
