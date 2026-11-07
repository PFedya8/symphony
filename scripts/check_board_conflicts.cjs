#!/usr/bin/env node
// Use a fresh disposable local demo; this exercises real concurrent browser drafts.
const {chromium}=require('playwright');
const fs=require('node:fs/promises');
const path=require('node:path');
(async()=>{
 const base=new URL(process.env.SYMPHONY_URL||'http://127.0.0.1:4000');
 if(!['127.0.0.1','localhost','[::1]'].includes(base.hostname)) throw new Error('Local disposable demo required');
 const token=process.env.SYMPHONY_DEMO_TOKEN;
 if(!token||token.length<32) throw new Error('Disposable demo token required');
 const out=process.env.SYMPHONY_SCREENSHOTS||'/tmp/symphony-conflicts';await fs.mkdir(out,{recursive:true});
 const browser=await chromium.launch({headless:true,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 try {
  const context=await browser.newContext({httpCredentials:{username:'demo',password:token}});
  const first=await context.newPage(),second=await context.newPage();const errors=[];
  for(const page of [first,second])page.on('pageerror',e=>errors.push(e.message));
  await first.setViewportSize({width:390,height:844});
  for(const page of [first,second]){await page.goto(new URL('/tasks?task=fixture-1',base).href);await page.locator('.phx-connected').waitFor();}
  const firstPlan=first.locator('#edit-plan'),secondPlan=second.locator('#edit-plan');
  for(const page of [first,second])await page.getByText('Edit plan',{exact:true}).click();
  if(await firstPlan.locator('[name=revision]').inputValue()!=='1')throw new Error('Fresh database required');
  await firstPlan.locator('textarea').fill('First client unsaved plan');
  await first.waitForFunction(()=>!document.querySelector('.phx-change-loading'));
  await secondPlan.locator('textarea').fill('Second client saved plan');
  await secondPlan.getByRole('button',{name:'Save plan',exact:true}).click();
  await first.locator('.detail-meta').filter({hasText:'Revision 2'}).waitFor();
  if(await firstPlan.locator('[name=revision]').inputValue()!=='1')throw new Error('Draft revision silently rebased');
  if(await firstPlan.locator('textarea').inputValue()!=='First client unsaved plan')throw new Error('Unsaved draft lost');
  await firstPlan.getByRole('button',{name:'Save plan',exact:true}).click();
  async function visibleFailure(code){
   const alert=first.locator(`.task-detail [role=alert][data-error="${code}"]`);await alert.waitFor({state:'visible'});
   const visible=await alert.evaluate(el=>{const r=el.getBoundingClientRect();const top=document.elementFromPoint(r.left+r.width/2,r.top+r.height/2);return r.top>=0&&r.bottom<=innerHeight&&(top===el||el.contains(top));});
   if(!visible)throw new Error(`Mobile error obscured: ${code}`);
  }
  await visibleFailure('stale_revision');
  await first.screenshot({path:path.join(out,'06-mobile-stale-draft.png'),fullPage:true});
  await firstPlan.getByRole('button',{name:'Reload current data (discard draft)',exact:true}).click();
  await first.waitForFunction(()=>document.querySelector('#edit-plan textarea').value==='Second client saved plan');
  await firstPlan.locator('textarea').fill('Reviewed replacement');
  await firstPlan.getByRole('button',{name:'Save plan',exact:true}).click();
  await second.locator('.detail-meta').filter({hasText:'Revision 3'}).waitFor();
  await firstPlan.locator('textarea').fill('x'.repeat(161));
  await firstPlan.getByRole('button',{name:'Save plan',exact:true}).click();await visibleFailure('invalid_plan');
  await first.getByText('Add an existing evidence link',{exact:true}).click();
  await first.locator('#add-link input[name=title]').fill('Invalid HTTP reference');
  await first.locator('#add-link input[name=url]').fill('http://example.com');
  await first.getByRole('button',{name:'Add link',exact:true}).click();await visibleFailure('invalid_url');
  await first.screenshot({path:path.join(out,'07-mobile-invalid-link.png'),fullPage:true});
  await first.locator('#move-task select').selectOption('Done');
  await first.getByRole('button',{name:'Move task',exact:true}).click();
  await first.locator('.stage-tag').filter({hasText:'Done'}).waitFor();
  await first.getByRole('button',{name:'preview',exact:true}).click();await visibleFailure('task_ineligible');
  await second.getByLabel('Close task').click();await second.locator('.new-task summary').click();
  await second.locator('#create-task input[name=title]').fill('Literal all project');
  await second.locator('#create-task input[name=project]').fill('all');
  await second.locator('#create-task textarea').fill('Synthetic reserved-name regression');
  await second.getByRole('button',{name:'Create task',exact:true}).click();
  await second.locator('.task-detail h2').filter({hasText:'Literal all project'}).waitFor();
  await second.getByLabel('Close task').click();
  await second.waitForFunction(()=>document.querySelectorAll('.task-card').length===1);
  if(!second.url().includes('project=all'))throw new Error('Literal project filter lost');
  await second.getByLabel('Project',{exact:true}).first().selectOption('');
  await second.waitForFunction(()=>document.querySelectorAll('.task-card').length===7);
  if(errors.length)throw new Error(JSON.stringify(errors));
  console.log(JSON.stringify({passed:true,checks:['two-browser stale plan rejected','draft/revision preserved','explicit reload and save',
   'mobile visible invalid plan/link/run errors','literal all project and All projects distinct','no browser errors'],screenshots:out}));
 }finally{await browser.close();}
})().catch(e=>{console.error(e.message);process.exitCode=1;});
