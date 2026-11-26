#!/usr/bin/env node
// Screenshots of the chat screen and both drawers at 390px in dark and light, against a running preview.
// Usage: node scripts/screenshots.mjs --url http://127.0.0.1:4173/ --out ../screenshots
import { mkdirSync } from 'node:fs'
import { resolve } from 'node:path'
import { chromium } from 'playwright-core'

function option(name, fallback) {
  const index = process.argv.indexOf(`--${name}`)
  return index >= 0 ? process.argv[index + 1] : fallback
}

const url = option('url', 'http://127.0.0.1:4173/')
const out = resolve(option('out', 'screenshots'))
mkdirSync(out, { recursive: true })

const browser = await chromium.launch({ channel: 'chrome', headless: true })
const problems = []

async function open(scheme, width) {
  const context = await browser.newContext({ viewport: { width, height: 844 }, deviceScaleFactor: 3, colorScheme: scheme, isMobile: true, hasTouch: true })
  const page = await context.newPage()
  await page.goto(url)
  await page.evaluate(() => localStorage.setItem('saturn.remoteToken', 'demo-token'))
  await page.goto(url)
  await page.getByRole('heading', { name: 'Hamburger menu for mobile', level: 1 }).waitFor()
  await page.waitForTimeout(400)
  return { context, page }
}

async function audit(page, label) {
  const result = await page.evaluate(() => {
    const overflow = document.documentElement.scrollWidth - window.innerWidth
    const small = []
    for (const element of document.querySelectorAll('button, a, input, textarea, [role="tab"]')) {
      const box = element.getBoundingClientRect()
      if (box.width === 0 || box.height === 0 || element.closest('[hidden]')) continue
      const hit = element.matches('.chip, .tab') ? { width: box.width, height: box.height + 12 } : box
      if (hit.height < 44 || (hit.width < 44 && !element.matches('textarea, input'))) small.push(`${element.tagName.toLowerCase()} "${element.getAttribute('aria-label') ?? element.textContent?.trim().slice(0, 30)}" ${Math.round(box.width)}×${Math.round(box.height)}`)
    }
    return { overflow, small }
  })
  if (result.overflow > 0) problems.push(`${label}: page scrolls sideways by ${result.overflow}px`)
  for (const item of result.small) problems.push(`${label}: small target ${item}`)
}

for (const scheme of ['dark', 'light']) {
  const { context, page } = await open(scheme, 390)
  await audit(page, `${scheme} chat`)
  await page.screenshot({ path: `${out}/chat-${scheme}.png` })
  await page.getByRole('button', { name: 'Open chats' }).click()
  await page.waitForTimeout(200)
  await audit(page, `${scheme} chats drawer`)
  await page.screenshot({ path: `${out}/chats-drawer-${scheme}.png` })
  await page.getByRole('button', { name: 'Close chats' }).click()
  await page.getByRole('button', { name: 'Open task details' }).click()
  await page.waitForTimeout(300)
  await audit(page, `${scheme} task`)
  await page.screenshot({ path: `${out}/details-task-${scheme}.png` })
  for (const tab of ['Project', 'Log']) {
    await page.getByRole('tab', { name: tab }).click()
    await page.waitForTimeout(150)
    await audit(page, `${scheme} ${tab.toLowerCase()}`)
    await page.screenshot({ path: `${out}/details-${tab.toLowerCase()}-${scheme}.png` })
  }
  await context.close()
}

for (const width of [360, 430, 768, 1440]) {
  const { context, page } = await open('dark', width)
  await audit(page, `${width}px chat`)
  if (width >= 768) await page.screenshot({ path: `${out}/chat-${width}.png` })
  await context.close()
}

await browser.close()
console.log(problems.length ? problems.join('\n') : 'No horizontal scroll and no touch targets under 44px.')
console.log(`Screenshots in ${out}`)
