// The fixture deliberately activates itself, exercising the guard against a real app-side focus change.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {createComputer} from '../src/computer.mjs';
const dir=await mkdtemp(join(tmpdir(),'opencomputer-focus-'));
const output=join(dir,'fixture.json');
const fixture=spawn(resolve('build/OpenComputer Fixture.app/Contents/MacOS/fixture'),[],{env:{...process.env,OPENCOMPUTER_FIXTURE_OUTPUT:output,OPENCOMPUTER_FIXTURE_FOCUS_TRAP:'1'},stdio:'ignore'});
const c=createComputer({apps:['cc.opencomputer.fixture'],agent:'Focus test'});
try{
  let ready=false;
  for(let i=0;i<50;i++){try{await readFile(output);ready=true;break;}catch{await new Promise(r=>setTimeout(r,100));}}
  assert.ok(ready);
  const app=c.getApp('cc.opencomputer.fixture');
  const before=await c.status();
  assert.notEqual(before.frontmostApp,'cc.opencomputer.fixture','fixture must begin in background');
  let tree=await app.getAXState();
  await assert.rejects(app.click(tree.nodes.find(n=>n.identifier==='focus-trap').id),{code:'FOCUS_CHANGED'});
  assert.equal((await c.status()).focusProtectionBlocked,true);
  tree=await app.getAXState();
  assert.match((await c.status()).activity.action,/Paused/);
  await assert.rejects(app.setValue(tree.nodes.find(n=>n.identifier==='benchmark-input').id,'must not write'),{code:'FOCUS_PROTECTION_BLOCKED'});
  await c.release();
  assert.equal((await c.status()).focusProtectionBlocked,true,'release must not bypass the focus latch');
  console.log(JSON.stringify({passed:7,detectedFocusChange:true,furtherActionsBlocked:true}));
}finally{await c.release().catch(()=>{});c.close();fixture.kill();await rm(dir,{recursive:true,force:true});}
