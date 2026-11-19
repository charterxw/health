import test from 'node:test'
import assert from 'node:assert/strict'
import { watchMobileViewport } from '../src/training/viewport.js'

test('normal standalone viewport differences do not constrain the frame; only an open keyboard changes height', () => {
  const values = new Map()
  const document = Object.assign(new EventTarget(), {
    activeElement: null,
    documentElement: { clientHeight: 852, style: {
      setProperty: (key, value) => values.set(key, value),
      removeProperty: key => values.delete(key),
    } },
  })
  const browser = Object.assign(new EventTarget(), {
    innerHeight: 852, document,
    visualViewport: Object.assign(new EventTarget(), { height: 790, scale: 1 }),
  })
  const mobile = Object.assign(new EventTarget(), { matches: true })
  browser.matchMedia = () => mobile
  const key = '--keyboard-viewport-height'
  const stop = watchMobileViewport(browser)
  assert.equal(values.has(key), false)
  browser.visualViewport.height = 730
  browser.visualViewport.dispatchEvent(new Event('resize'))
  assert.equal(values.has(key), false)
  document.activeElement = { tagName: 'INPUT' }
  browser.visualViewport.height = 390
  document.dispatchEvent(new Event('focusin'))
  assert.equal(values.get(key), '390px')
  browser.visualViewport.height = 195; browser.visualViewport.scale = 2
  browser.visualViewport.dispatchEvent(new Event('resize'))
  assert.equal(values.has(key), false)
  browser.visualViewport.scale = 1; browser.visualViewport.height = 390
  browser.dispatchEvent(new Event('resize'))
  assert.equal(values.get(key), '390px')
  document.activeElement = null
  document.dispatchEvent(new Event('focusout'))
  assert.equal(values.has(key), false)
  document.activeElement = { tagName: 'TEXTAREA' }
  document.dispatchEvent(new Event('focusin'))
  assert.equal(values.get(key), '390px')
  mobile.matches = false
  mobile.dispatchEvent(new Event('change'))
  assert.equal(values.has(key), false)
  mobile.matches = true
  mobile.dispatchEvent(new Event('change'))
  assert.equal(values.get(key), '390px')
  stop()
  document.dispatchEvent(new Event('focusin'))
  browser.visualViewport.dispatchEvent(new Event('resize'))
  browser.dispatchEvent(new Event('resize'))
  mobile.dispatchEvent(new Event('change'))
  assert.equal(values.has(key), false)
})
