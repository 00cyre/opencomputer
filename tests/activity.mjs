import assert from 'node:assert/strict';
import {spawn,spawnSync} from 'node:child_process';
import {mkdtemp,readFile,rm,mkdir,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {createInterface} from 'node:readline';
import {createComputer} from '../src/computer.mjs';
const preview=process.argv[2]==='--preview';
const outputDir=resolve(process.argv[3]??'work/activity');
const dir=await mkdtemp(join(tmpdir(),'opencomputer-activity-'));
const resultPath=join(dir,'fixture.json');
const fixture=spawn(resolve('build/OpenComputer Fixture.app/Contents/MacOS/fixture'),[],{env:{...process.env,OPENCOMPUTER_FIXTURE_OUTPUT:resultPath,OPENCOMPUTER_FIXTURE_TOP_RIGHT:preview?'1':'0',OPENCOMPUTER_FIXTURE_OVERLAY_TEST:'1'},stdio:'ignore'});
const a=createComputer({apps:['cc.opencomputer.fixture'],agent:'Claude'});
const b=createComputer({apps:['cc.opencomputer.fixture'],agent:'Grok'});
const delay=ms=>new Promise(r=>setTimeout(r,ms));
let checks=0;
function check(value,message){assert.ok(value,message);checks++;}
async function status(){const x=await a.status(),y=await b.status();if(preview){await mkdir(outputDir,{recursive:true});await writeFile(join(outputDir,'state.json'),JSON.stringify({claude:x,grok:y},null,2));}return{x,y};}
try{
  let ready=false;
  for(let i=0;i<50;i++){try{await readFile(resultPath);ready=true;break;}catch{await delay(100);}}
  check(ready,'fixture starts');
  const before=await a.status();
  const app=a.getApp('cc.opencomputer.fixture');
  let tree=await app.getAXState();
  await delay(300);
  let {x}=await status();
  check(x.activity.pillVisible&&x.activity.active,'pill appears for active work');
  check(x.activity.agent==='Claude','agent identity is visible');
  check(x.activity.nonActivating&&x.activity.clickThrough,'both panels reject key/main status and pass clicks through');
  check(x.activity.ghostVisible,`ghost appears on the exposed target window (${x.activity.ghostReason})`);
  check(x.frontmostApp===before.frontmostApp,'showing overlays preserves foreground app');
  await b.getApp('cc.opencomputer.fixture').getAXState();
  await delay(650);
  const pair=await status();
  check(pair.y.activity.agent==='Grok'&&pair.y.activity.pillVisible,'second agent has its own pill');
  check(pair.x.activity.stackRow!==pair.y.activity.stackRow,'concurrent pills occupy different rows');
  const one=pair.x.activity.pillFrame,two=pair.y.activity.pillFrame;
  check(one.y+one.height<=two.y || two.y+two.height<=one.y,'concurrent panels do not overlap');
  await assert.rejects(app.pressKey(tree.nodes.find(n=>n.identifier==='benchmark-input').id,'Tab'),{code:'FOCUS_UNSAFE'});checks++;
  tree=await app.getAXState();
  await app.setValue(tree.nodes.find(n=>n.identifier==='benchmark-input').id,'FOCUS-PROTECTED');
  check((await app.getAXState()).nodes.find(n=>n.identifier==='benchmark-input').value==='FOCUS-PROTECTED','semantic text edits still work');
  check(!(await a.status()).focusProtectionBlocked,'safe action leaves session usable');
  tree=await app.getAXState();
  await app.click(tree.nodes.find(n=>n.identifier==='cover-ghost').id);
  await delay(200);
  check(!(await a.status()).activity.ghostVisible,'ghost disappears when another window covers its target');
  await delay(1000);
  check((await a.status()).activity.ghostVisible,'ghost reappears when the target is exposed');
  await a.release();
  x=await a.status();
  check(!x.activity.active&&!x.activity.pillVisible&&!x.activity.ghostVisible,'release removes both annotations');
  check((await b.status()).activity.pillVisible,'releasing one session preserves the other');
  console.log(JSON.stringify({passed:checks,foregroundPreserved:true},null,2));
  if(preview){
    await app.getAXState();await delay(700);await status();
    console.log('Preview ready. Commands: status, capture NAME, release-grok, quit.');
    for await(const line of createInterface({input:process.stdin})){
      if(line==='quit')break;
      if(line==='release-grok')await b.release();
      const {x,y}=await status();
      console.log(JSON.stringify({claude:x.activity,grok:y.activity}));
      if(line.startsWith('capture ')){
        const name=line.slice(8).replace(/[^a-z0-9-]/gi,'');
        const capture=spawnSync(resolve('build/capture-overlay'),[String(x.helperPid),String(x.activity.pillWindowId),join(outputDir,`${name}.png`)],{encoding:'utf8'});
        if(capture.status!==0)throw Error(capture.stderr);console.log(capture.stdout.trim());
      }
    }
  }
}finally{await Promise.allSettled([a.release(),b.release()]);a.close();b.close();fixture.kill();await rm(dir,{recursive:true,force:true});}
