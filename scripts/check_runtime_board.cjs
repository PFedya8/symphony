#!/usr/bin/env node
// Only for scripts/runtime_board_fixture.exs: fake provider/Codex, actual orchestrator.
const {chromium}=require('playwright');
const fs=require('node:fs/promises'),path=require('node:path');
(async()=>{
 const base=new URL(process.env.SYMPHONY_URL||'http://127.0.0.1:4000');
 if(!['127.0.0.1','localhost','[::1]'].includes(base.hostname))throw new Error('Local synthetic runtime required');
 const token=process.env.SYMPHONY_BOARD_TOKEN;if(!token||token.length<32)throw new Error('Disposable runtime token required');
 const browser=await chromium.launch({headless:true,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 const out=process.env.SYMPHONY_SCREENSHOTS||'/tmp/symphony-runtime-screenshots';await fs.mkdir(out,{recursive:true});
 try{
  const context=await browser.newContext({httpCredentials:{username:'demo',password:token},viewport:{width:1500,height:950}});
  const page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto(new URL('/tasks',base).href);await page.locator('.phx-connected').waitFor();
  await page.locator('#card-101').waitFor();
  if(!(await page.locator('#card-101').innerText()).includes('Synthetic GitLab task'))throw new Error('Refusing non-fixture task');
  if(await page.locator('.task-card').count()!==2)throw new Error('Fresh runtime fixture required');
  await page.screenshot({path:path.join(out,'12-runtime-board-desktop.png'),fullPage:true});
  await page.locator('#card-101').click();await page.locator('.task-detail').waitFor();
  if(await page.getByRole('button',{name:'Approve real worker attempt',exact:true}).count())throw new Error('Missing preview gate');
  await page.getByRole('button',{name:'preview',exact:true}).click();
  await page.locator('.approval-note').filter({hasText:'One real Codex worker attempt'}).waitFor();
  await page.getByRole('button',{name:'Approve real worker attempt',exact:true}).click();
  await page.locator('.run-row strong').filter({hasText:'running · attempt 1'}).waitFor();
  await page.setViewportSize({width:390,height:844});
  await page.locator('.run-row').evaluate(el=>el.scrollIntoView({block:'center'}));
  await page.screenshot({path:path.join(out,'13-runtime-worker-mobile.png'),fullPage:true});
  await page.locator('.run-row strong').filter({hasText:'succeeded · attempt 1'}).waitFor();
  await page.locator('.stage-tag').filter({hasText:'Human Review'}).waitFor();
  await page.setViewportSize({width:1500,height:950});
  await page.getByRole('button',{name:'Expand task',exact:true}).click();
  await page.locator('.run-row').evaluate(el=>el.scrollIntoView({block:'center'}));
  await page.screenshot({path:path.join(out,'14-runtime-completion-desktop.png'),fullPage:true});
  const response=await context.request.get(new URL('/api/v1/control/snapshot?task_id=101',base).href,{headers:{Authorization:'Bearer '+token}});
  const payload=await response.json();
  if(payload.mode!=='gitlab_runtime'||payload.runs.length!==1||payload.runs[0].simulated!==false||payload.task.release_verified!==false)throw new Error('Runtime provenance mismatch');
  if(JSON.stringify(payload).includes('workspace_path'))throw new Error('Workspace path leaked into board');
  await page.getByLabel('Close task').click();await page.locator('#card-102').click();
  await page.getByRole('button',{name:'preview',exact:true}).click();
  await page.getByRole('button',{name:'Approve real worker attempt',exact:true}).click();
  await page.getByRole('button',{name:'Stop and hold',exact:true}).click();
  await page.locator('.run-row strong').filter({hasText:'stopped · attempt 1'}).waitFor();
  if(errors.length)throw new Error(JSON.stringify(errors));
  console.log(JSON.stringify({passed:true,checks:['automatic GitLab adapter projection','approval gate','actual AgentRunner lifecycle with fake protocol process','observed completion','actual stop and hold','API/UI run identity','no workspace path exposure','desktop/mobile'],externalProvider:'synthetic; no live credentials',screenshots:out}));
 }finally{await browser.close();}
})().catch(e=>{console.error(e.message);process.exitCode=1;});
