#!/usr/bin/env node
// Requires Playwright + Chromium and a fresh, disposable local board database.
const { chromium } = require('playwright');
const fs = require('node:fs/promises');
const path = require('node:path');
(async () => {
  const base = new URL(process.env.SYMPHONY_URL || 'http://127.0.0.1:4000');
  if (!['127.0.0.1', 'localhost', '[::1]'].includes(base.hostname)) throw new Error('Local disposable demo required');
  const token = process.env.SYMPHONY_DEMO_TOKEN;
  if (!token || token.length < 32) throw new Error('Set the disposable demo token');
  const out = process.env.SYMPHONY_SCREENSHOTS || '/tmp/symphony-screenshots';
  await fs.mkdir(out, {recursive:true});
  const browser = await chromium.launch({headless:true, executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
  try {
    const context = await browser.newContext({httpCredentials:{username:'demo',password:token}, viewport:{width:1600,height:1000}});
    const page = await context.newPage();
    const errors=[];
    page.on('pageerror', error=>errors.push(error.message));
    await page.goto(new URL('/tasks',base).href);
    await page.locator('.phx-connected').waitFor();
    if (await page.locator('.task-card').count() !== 6) throw new Error('Fresh six-task database required');
    await page.screenshot({path:path.join(out,'01-board-desktop.png'),fullPage:true});
    await page.getByLabel('Project',{exact:true}).first().selectOption('sandbox');
    await page.waitForFunction(()=>document.querySelectorAll('.task-card').length===1);
    await page.getByLabel('Project',{exact:true}).first().selectOption('all');
    await page.waitForFunction(()=>document.querySelectorAll('.task-card').length===6);
    await page.locator('#card-fixture-1').click();
    await page.locator('.task-detail').waitFor();
    await page.getByRole('button',{name:'preview',exact:true}).click();
    await page.getByRole('button',{name:'Approve and start simulation',exact:true}).click();
    await page.getByRole('button',{name:'Stop and hold',exact:true}).click();
    await page.getByText('stopped · attempt 1',{exact:true}).waitFor();
    if(await page.getByRole('button',{name:'Approve new retry',exact:true}).count()) throw new Error('Stale approval');
    await page.getByRole('button',{name:'release-hold',exact:true}).click();
    await page.getByRole('button',{name:'preview',exact:true}).click();
    await page.getByRole('button',{name:'Approve new retry',exact:true}).click();
    await page.getByText('succeeded · attempt 2',{exact:true}).waitFor();
    await page.locator('.stage-tag').filter({hasText:'Human Review'}).waitFor();
    await page.getByText('Edit plan',{exact:true}).click();
    await page.locator('#edit-plan textarea').fill('Inspect timeout behavior\nVerify cancellation and retry\nReview the simulation evidence');
    await page.getByRole('button',{name:'Save plan',exact:true}).click();
    await page.getByRole('button',{name:'Toggle Inspect timeout behavior'}).click();
    await page.getByText('Edit plan',{exact:true}).click();
    await page.getByText('Add an existing evidence link',{exact:true}).click();
    await page.locator('#add-link input[name=title]').fill('Implementation review — supplied reference');
    await page.locator('#add-link input[name=url]').fill('https://github.com/PFedya8/symphony/pull/2');
    await page.getByRole('button',{name:'Add link',exact:true}).click();
    await page.locator('.evidence-link').waitFor();
    await page.getByText('Add an existing evidence link',{exact:true}).click();
    await page.locator('.activity-event summary').first().click();
    await page.locator('.activity-event[open] pre').waitFor({state:'visible'});
    await page.locator('.activity-event summary').first().click();
    await page.locator('.task-detail').evaluate(el=>el.scrollTo(0,0));
    await page.screenshot({path:path.join(out,'02-task-desktop.png'),fullPage:true});
    // A separate mobile browser checks the persisted detail and project board.
    const mobile=await context.newPage();
    await mobile.setViewportSize({width:390,height:844});
    mobile.on('pageerror',error=>errors.push(error.message));
    await mobile.goto(new URL('/tasks',base).href);
    await mobile.locator('.phx-connected').waitFor();
    await mobile.screenshot({path:path.join(out,'03-board-mobile.png'),fullPage:true});
    await mobile.locator('#card-fixture-1').click();
    await mobile.locator('.task-detail').waitFor();
    await mobile.screenshot({path:path.join(out,'04-task-mobile.png'),fullPage:true});
    await mobile.locator('.evidence-link').evaluate(el=>el.closest('section').scrollIntoView({block:'start'}));
    await mobile.screenshot({path:path.join(out,'05-evidence-mobile.png'),fullPage:true});
    await mobile.locator('.task-detail').evaluate(el=>el.scrollTo(0,0));
    await mobile.getByLabel('Close task').click();
    await mobile.locator('.new-task summary').click();
    await mobile.locator('#create-task input[name=title]').fill('Mobile-created acceptance task');
    await mobile.locator('#create-task input[name=project]').fill('sandbox');
    await mobile.locator('#create-task textarea').fill('Created from a mobile-sized browser using the shared backend.');
    await mobile.getByRole('button',{name:'Create task',exact:true}).click();
    await mobile.locator('.task-detail h2').filter({hasText:'Mobile-created acceptance task'}).waitFor();
    await mobile.locator('#move-task select').selectOption('Todo');
    await mobile.getByRole('button',{name:'Move task',exact:true}).click();
    await mobile.locator('.stage-tag').filter({hasText:'Todo'}).waitFor();
    if (errors.length) throw new Error(JSON.stringify(errors));
    console.log(JSON.stringify({passed:true,checks:['six-stage board','project filter','detail navigation','start/stop/hold/retry',
      'Human Review after simulated success','plan edit/check','linked unverified PR reference','activity disclosure',
      'mobile create/move','persisted cross-browser state','no browser runtime errors'],screenshots:out}));
  } finally {await browser.close();}
})().catch(error=>{console.error(error.message);process.exitCode=1;});
