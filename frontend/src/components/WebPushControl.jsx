import { useEffect, useState } from 'react'
import { pushStatus, enablePush, disablePush, showTestNotification } from '../training/webPush'
import '../training/webPush.css'

export default function WebPushControl() {
  const [state, setState] = useState('checking')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [tested, setTested] = useState(false)
  useEffect(() => {
    let alive = true
    const update = () => pushStatus().then(value => { if (alive) setState(value) }).catch(() => { if (alive) setState('error') })
    update()
    window.addEventListener('focus', update)
    return () => { alive = false; window.removeEventListener('focus', update) }
  }, [])
  async function toggle() {
    setBusy(true); setError('')
    try {
      if (state === 'on') { await disablePush(); setState('off') }
      else { await enablePush(); setState('on') }
    } catch (failure) { setError(failure.message || '设置暂未完成，请重试。') }
    finally { setBusy(false) }
  }
  async function testNotification() {
    setBusy(true); setError(''); setTested(false)
    try { await showTestNotification(); setTested(true) }
    catch { setError('无法显示测试通知，请检查系统通知权限。') }
    finally { setBusy(false) }
  }
  return <section className="st-webpush" aria-label="训练报告通知">
    <div><strong>报告更新通知</strong><p>{state === 'on' ? '本机已订阅。今日观察生成后，主屏幕版 Health 会提醒你。' : state === 'unsupported' ? '在 Safari 中选「分享 → 添加到主屏幕」，再从主屏幕打开 Health，在设置里开启通知。' : state === 'denied' ? '通知权限已关闭，请在 iPhone 设置 → 通知 → Health 中开启。' : state === 'checking' ? '正在检查通知设置…' : '开启后，收到今日观察的更新提醒。'}</p></div>
    {!['unsupported', 'denied', 'checking'].includes(state) && <button type="button" disabled={busy} onClick={toggle}>{busy ? '设置中…' : state === 'on' ? '关闭通知' : '开启通知'}</button>}
    {state === 'on' && <button type="button" disabled={busy} onClick={testNotification}>测试本机通知</button>}
    {state === 'on' && tested && <p role="status">已请求显示测试通知。若没有横幅，请检查通知中心、专注模式和通知摘要。</p>}
    {error && <p className="st-webpush-error" role="alert">{error}</p>}
  </section>
}
