#!/usr/bin/env node
// Requires Playwright + Chromium. Use only a fresh, disposable local demo.
const { chromium } = require('playwright');
const fs = require('node:fs/promises');
const path = require('node:path');

(async () => {
  const base = new URL(process.env.SYMPHONY_URL || 'http://127.0.0.1:4000');
  if (!['127.0.0.1', 'localhost', '[::1]'].includes(base.hostname)) {
    throw new Error('Screenshot verification only permits a local disposable demo');
  }
  const token = process.env.SYMPHONY_DEMO_TOKEN;
  if (!token || token.length < 32) throw new Error('Set the disposable demo token');
  const out = process.env.SYMPHONY_SCREENSHOTS || '/tmp/symphony-screenshots';
  await fs.mkdir(out, {recursive: true});
  const browser = await chromium.launch({headless: true, executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
  try {
    const context = await browser.newContext({
      httpCredentials: {username: 'demo', password: token},
      viewport: {width: 390, height: 844}, deviceScaleFactor: 1,
    });
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(new URL('/tasks', base).href);
    await page.locator('.phx-connected').waitFor();
    if (await page.locator('article[id^="run-"]').count()) throw new Error('Use a fresh demo database');
    await page.screenshot({path: path.join(out, '01-queue-mobile.png'), fullPage: true});
    await page.getByRole('button', {name: 'preview', exact: true}).click();
    await page.getByRole('button', {name: 'Approve and start simulation', exact: true}).click();
    await page.getByRole('button', {name: 'Stop and hold', exact: true}).click();
    await page.getByText('stopped · attempt 1', {exact: false}).waitFor();
    await page.getByText('hold: true', {exact: false}).waitFor();
    await page.screenshot({path: path.join(out, '02-stopped-mobile.png'), fullPage: true});
    await page.getByRole('button', {name: 'release-hold', exact: true}).click();
    await page.getByRole('button', {name: 'preview', exact: true}).click();
    await page.getByRole('button', {name: 'Approve new retry', exact: true}).click();
    await page.getByText('succeeded · attempt 2', {exact: false}).waitFor();
    await page.screenshot({path: path.join(out, '03-retry-succeeded-mobile.png'), fullPage: true});
    if (errors.length) throw new Error(JSON.stringify(errors));
    console.log(JSON.stringify({passed: true, viewport: '390x844',
      checks: ['LiveView connected', 'preview/start', 'stop/hold', 'release/preview/retry',
        'simulated success', 'no browser runtime errors'], screenshots: out}));
  } finally { await browser.close(); }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
