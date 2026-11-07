#!/usr/bin/env node
// Non-test build, synthetic provider, production execution gate. Never uses live credentials.
const {chromium}=require('playwright');
const fs=require('node:fs/promises'),path=require('node:path');
(async()=>{
 const base=new URL(process.env.SYMPHONY_URL||'http://127.0.0.1:4000');
 if(!['127.0.0.1','localhost','[::1]'].includes(base.hostname))throw new Error('Loopback fixture required');
 const token=process.env.SYMPHONY_BOARD_TOKEN;if(!token||token.length<32)throw new Error('Disposable token required');
 const browser=await chromium.launch({headless:true,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE});
 try{
  const context=await browser.newContext({httpCredentials:{username:'demo',password:token},viewport:{width:390,height:844}});
  const page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto(new URL('/tasks?task=101',base).href);await page.locator('.phx-connected').waitFor();
  if(!(await page.locator('.task-detail').innerText()).includes('Synthetic GitLab task'))throw new Error('Non-fixture task');
  const notice=page.getByRole('alert').filter({hasText:'Execution unavailable: verified OS containment is required'});
  await notice.waitFor();await notice.scrollIntoViewIfNeeded();
  await page.getByRole('button',{name:'preview',exact:true}).click();
  await page.getByRole('alert').filter({hasText:'runtime_execution_unavailable'}).waitFor();
  if(await page.getByRole('button',{name:'Approve synthetic runtime attempt',exact:true}).count())throw new Error('Unexpected authorization');
  const response=await context.request.get(new URL('/api/v1/control/snapshot?task_id=101',base).href,{headers:{Authorization:`Bearer ${token}`}});
  if(!response.ok())throw new Error(`Snapshot HTTP ${response.status()}`);
  const snapshot=await response.json();
  if(snapshot.execution_available!==false||snapshot.runs.length!==0)throw new Error('Execution gate failed');
  const out=process.env.SYMPHONY_SCREENSHOTS||'/tmp/symphony-disabled-screenshots';await fs.mkdir(out,{recursive:true});
  await page.screenshot({path:path.join(out,'15-runtime-disabled-mobile.png'),fullPage:true});
  if(errors.length)throw new Error(errors.join('\n'));
  console.log(JSON.stringify({passed:true,checks:['non-test build blocks preview','no worker or approval','mobile blocker visible','discovery remains available'],screenshots:out}));
 }finally{await browser.close();}
})().catch(e=>{console.error(e.message);process.exit(1);});
