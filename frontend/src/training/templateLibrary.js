import { MUSCLE_NAMES } from './muscles.js'

export const TEMPLATE_CATEGORIES = [
  ['all', '全部'], ['company', '公司'], ['home', '居家'], ['weekend', '周末'], ['posture', '体态'], ['other', '其他'],
]

export function templateCategory(template) {
  if (template.id.startsWith('posture-')) return 'posture'
  if (Number.isInteger(template.rotation_order) || template.id.startsWith('personal-company-')) return 'company'
  if (template.id.startsWith('personal-home-')) return 'home'
  if (template.id.startsWith('personal-weekend-')) return 'weekend'
  return 'other'
}

export function durationLabel(template) {
  const { duration_min: min, duration_max: max } = template
  if (min && max && min !== max) return `${min}–${max} 分钟`
  return min || max ? `${min || max} 分钟` : null
}

function roundNumber(template) {
  if (Number.isInteger(template.rotation_order)) return template.rotation_order
  const match = /^personal-(?:company|home)-([a-z])$/i.exec(template.id)
  return match ? match[1].toUpperCase().charCodeAt(0) - 65 : null
}

export function groupTemplates(records) {
  const groups = new Map()
  for (const record of records) {
    const template = record.template
    const category = templateCategory(template), round = roundNumber(template)
    const id = round == null ? category : `round-${round}`
    if (!groups.has(id)) {
      const letter = round == null ? null : round >= 0 && round < 26 ? String.fromCharCode(65 + round) : String(round + 1)
      groups.set(id, { id, round, letter, label: letter ? `${letter} 轮训练` : category === 'posture' ? '体态练习' : category === 'weekend' ? '周末补练' : category === 'home' ? '其他居家训练' : '其他模板', records: [] })
    }
    groups.get(id).records.push(record)
  }
  const order = group => group.id === 'posture' ? -1 : (group.round===4?1.5:group.round) ?? (group.id === 'weekend' ? 1000 : 1001)
  return [...groups.values()].sort((a, b) => order(a) - order(b))
    .map(group => {
      const locations = [...new Set(group.records.map(record => templateCategory(record.template)))].map(id => TEMPLATE_CATEGORIES.find(([key]) => key === id)?.[1]).filter(id => id !== '其他')
      const focus = [...new Set(group.records.flatMap(({ template }) => (template.name.split(/[｜|]/)[1] || '').split(/[·、/]/).map(text => text.trim()).filter(Boolean)))].join(' · ')
      return { ...group, focus, locations: locations.join(' + ') }
    })
}

export function filterTemplates(records, exercises, { query = '', category = 'all' } = {}) {
  const index = new Map(exercises.map(exercise => [exercise.id, exercise]))
  const terms = query.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean)
  return records.filter(({ template }) => {
    if (category !== 'all' && templateCategory(template) !== category) return false
    const names = template.exercises.flatMap(plan => {
      const exercise = index.get(plan.exercise_id)
      return exercise ? [exercise.name, ...(exercise.aliases || []), exercise.equipment,
        ...(exercise.muscles || []), ...(exercise.primary_muscles || []).map(id => MUSCLE_NAMES[id] || id)] : [plan.exercise_id]
    })
    const text = [template.name, template.description, TEMPLATE_CATEGORIES.find(([id]) => id === templateCategory(template))?.[1], ...names].filter(Boolean).join(' ').toLocaleLowerCase()
    return terms.every(term => /^[a-e]$/.test(term)
      ? roundNumber(template) != null ? roundNumber(template) === term.charCodeAt(0) - 97 : new RegExp(`(^|[^a-z])${term}($|[^a-z])`, 'i').test(template.name)
      : text.includes(term))
  })
}
