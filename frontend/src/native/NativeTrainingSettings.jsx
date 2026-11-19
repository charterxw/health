import { useEffect, useState } from 'react'
import { nativeRequest } from './bridge'
import './native.css'

export default function NativeTrainingSettings() {
  const [status, setStatus] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  useEffect(() => {
    let alive = true
    const update = () => nativeRequest('status').then(value => { if (alive) setStatus(value) }).catch(() => { if (alive) setError('暂时无法读取设置，请重新打开。') })
    update(); window.addEventListener('health-native-resume', update)
    return () => { alive = false; window.removeEventListener('health-native-resume', update) }
  }, [])
  async function change(type, values) {
    setBusy(true); setError('')
    try { setStatus(await nativeRequest(type, values)) }
    catch (failure) { setError(failure.message) }
    finally { setBusy(false) }
  }
  return <div className="health-native-settings">
    <section><div><strong>训练实况</strong><p>{status?.activitiesAllowed === false ? '请在 iPhone 设置 → Health 训练中允许实时活动。' : '在锁屏和灵动岛查看训练进度、时长和休息倒计时。'}</p></div>
      <button className="st-secondary" disabled={busy || !status} onClick={() => change('setLiveActivities', { enabled: !status.liveActivitiesEnabled })}>{status?.liveActivitiesEnabled ? '关闭实况' : '开启实况'}</button></section>
    <section><div><strong>组间休息提醒</strong><p>{!status ? '正在读取设置…' : status.notificationPermission === 'denied' ? '通知权限已关闭，请在 iPhone 系统设置中开启。' : status.restRemindersEnabled ? '已开启 · 由手机本地提醒，锁屏和断网也可用。' : '完成一组后，在休息结束时提醒你。'}</p></div>
      <button className="st-secondary" disabled={busy || !status || status.notificationPermission === 'denied'} onClick={() => change(status.restRemindersEnabled ? 'disableRestReminders' : 'enableRestReminders')}>{status?.restRemindersEnabled ? '关闭提醒' : '开启提醒'}</button></section>
    <section><div><strong>报告更新通知</strong><p>继续由主屏幕网站版 Health 发送。通知订阅保留在原网站中。</p></div></section>
    {status?.activityError && <p className="st-muted" role="status">{status.activityError}</p>}
    {status?.reminderError && <p className="st-muted" role="status">{status.reminderError}</p>}
    {error && <p className="st-error" role="alert">{error}</p>}
  </div>
}
