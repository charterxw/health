import { createServer } from 'node:http'
import { readFile, access } from 'node:fs/promises'
import { startSession } from '../../frontend/src/training/strength.js'

const dist = new URL('../../frontend/dist/', import.meta.url)
const index = new URL('index.html', dist)
await access(index)

const exercise = { id: 'pulldown', name: '单手下拉', muscles: ['背部'], equipment: '绳索', load_mode: 'external' }
const template = { id: 'back', name: '背部力量训练', exercises: [{ exercise_id: exercise.id, set_count: 4, rest_seconds: 90, unit: 'lb', target_reps: 8 }] }
const runs = new Map()

const dateOffset = offset => {
  const date = new Date()
  date.setDate(date.getDate() + offset)
  return date.toISOString().slice(0, 10)
}
const observations = [
  { id: 41, date: dateOffset(0), time_slot: 'morning', title: '早间睡眠分析', report: {
    status: 'finding', findings: [{ headline: '昨夜睡眠比近期平均多了 36 分钟',
      body: '实际睡眠 7 小时 30 分钟，主要来自更长的睡眠窗口。',
      evidence: ['昨夜：实际睡眠 450 分钟', '此前 7 晚平均：414 分钟'], confidence: 'medium' }],
  } },
  { id: 42, date: dateOffset(0), time_slot: 'evening', title: '晚间健康分析', report: {
    status: 'finding', as_of: '21:00', findings: [{ headline: '全天活动接近近期水平',
      body: '记录了 6,240 步和 22 分钟活动。结合昨夜睡眠看，今天的静息心率也接近近期水平。',
      evidence: ['今日：6,240 步、活动 22 分钟、静息心率 59 次/分钟'], confidence: 'medium' }],
  } },
]
const weekly = { id: 43, date: dateOffset(-1), time_slot: 'weekly', title: '每周观察', report: {
  status: 'unchanged', summary: '过去一周记录了六晚主睡眠，平均时长与此前数周接近。', findings: [],
  period: { start: dateOffset(-7), end: dateOffset(-1) },
  trend: [402, 419, null, 395, 448, 420, 432].map((minutes, index) => ({ date: dateOffset(index - 7), minutes })),
} }

function newRun() {
  const session = startSession(template, [exercise])
  for (const set of session.exercises[0].sets) Object.assign(set, { weight: 50, reps: 8 })
  return { authenticated: false, record: { session, version: 1 } }
}

function json(response, value, status = 200) {
  response.writeHead(status, { 'Content-Type': 'application/json' }).end(JSON.stringify(value))
}

async function readJSON(request) {
  const chunks = []
  for await (const chunk of request) chunks.push(chunk)
  return JSON.parse(Buffer.concat(chunks).toString())
}

async function handle(request, response) {
  response.setHeader('Cache-Control', 'no-store')
  const { pathname } = new URL(request.url, 'http://127.0.0.1')
  const page = /^\/(fixture|retry)\/([a-f0-9-]{36})$/.exec(pathname)
  if (page) {
    const [, mode, id] = page
    const first = !runs.has(id)
    if (first) runs.set(id, newRun())
    if (first && mode === 'retry') return response.writeHead(503).end('Service Unavailable')
    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Set-Cookie': `health-test=${id}; Path=/; HttpOnly; SameSite=Strict` })
    return response.end(await readFile(index))
  }
  const asset = /^\/assets\/[a-zA-Z0-9_.-]+\.(js|css)$/.exec(pathname)
  if (asset) {
    const file = await readFile(new URL(pathname.slice(1), dist))
    return response.writeHead(200, { 'Content-Type': asset[1] === 'js' ? 'text/javascript' : 'text/css' }).end(file)
  }

  const id = /(?:^|;\s*)health-test=([a-f0-9-]{36})/.exec(request.headers.cookie || '')?.[1]
  const run = runs.get(id)
  if (!run) return json(response, { detail: 'Unknown test session' }, 404)
  if (pathname === '/api/auth/app-status') return json(response, { authenticated: run.authenticated })
  if (pathname === '/api/auth/app-login' && request.method === 'POST') {
    const { username, password } = await readJSON(request)
    run.authenticated = username === 'test' && password === 'sample-password'
    return json(response, { authenticated: run.authenticated }, run.authenticated ? 200 : 401)
  }
  if (!run.authenticated) return json(response, { detail: 'Please sign in' }, 401)
  switch (pathname) {
    case '/api/auth/status': return json(response, { authenticated: true })
    case '/api/integrations/status': return json(response, {})
    case '/api/strength/catalog': return json(response, { exercises: [exercise], templates: [{ template, version: 1 }] })
    case '/api/strength/sessions': return json(response, [run.record])
    case '/api/strength/session-deletions':
    case '/api/workouts/training':
    case '/api/workouts/training/archive':
    case '/api/workouts/exercises': return json(response, [])
    case '/api/insights/today': return json(response, observations)
    case '/api/insights/weekly': return json(response, weekly)
    case '/api/insights/archive': return json(response, [...observations, weekly, {
      id: 40, date: dateOffset(-3), time_slot: 'training', title: '训练分析', content: '保留的训练分析。',
    }])
    case '/api/sleep/history': return json(response, [])
    case '/api/workouts/archive': return json(response, { training: [], exercises: [] })
    case '/api/health/history': {
      const date = new Date()
      date.setDate(date.getDate() - 1)
      return json(response, [{ date: date.toISOString().slice(0, 10), steps: 7048, calories_burned: 280,
        active_minutes: 25, distance_km: 5.2, sleep_hours: 7.4, hrv: 47, resting_hr: 60 }])
    }
    case '/api/health/today':
      return json(response, { date: new Date().toISOString().slice(0, 10), steps: 6240, calories_burned: 310,
        active_minutes: 22, distance_km: 4.8, sleep_hours: 7.5, hrv: 49, resting_hr: 59 })
    case `/api/strength/sessions/${run.record.session.id}/physiology`:
      return json(response, { status: 'pending', metrics: {}, heart_rate: null })
    case `/api/strength/sessions/${run.record.session.id}`:
      if (request.method === 'PUT') {
        const { session, expected_version: version } = await readJSON(request)
        if (version !== run.record.version) return json(response, { detail: 'Version conflict' }, 409)
        run.record = { session, version: version + 1 }
      }
      return json(response, run.record)
    default: return json(response, { detail: 'Unknown fixture route' }, 404)
  }
}

createServer((request, response) => {
  handle(request, response).catch(error => {
    console.error(error.message)
    if (response.headersSent) response.end()
    else json(response, { detail: 'Fixture error' }, 500)
  })
}).listen(43189, '127.0.0.1', () => console.log('Health UI fixtures ready on 127.0.0.1:43189'))
