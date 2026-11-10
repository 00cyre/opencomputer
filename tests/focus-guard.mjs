// The fixture deliberately activates itself, exercising the guard against a real app-side focus change.
import strict from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {createComputer} from '../src/computer.mjs';
const dir=await mkdtemp(join(tmpdir(),'opencomputer-focus-'));
const output=join(dir,'fixture.json');
const fixture=spawn(resolve('build/OpenComputer Fixture.app/Contents/MacOS/fixture'),[],{env:{...process.env,OPENCOMPUTER_FIXTURE_OUTPUT:output,OPENCOMPUTER_FIXTURE_FOCUS_TRAP:'1',OPENCOMPUTER_FIXTURE_SECOND_WINDOW:'1'},stdio:'ignore'});
const c=createComputer({apps:['cc.opencomputer.fixture'],agent:'Focus test'});
let checks=0;
const assert=new Proxy(strict,{get(target,key){const value=target[key];return typeof value==='function'?(...args)=>{checks++;return value(...args);}:value;}});
const delay=ms=>new Promise(r=>setTimeout(r,ms));
try{
  let ready=false;
  for(let i=0;i<50;i++){try{await readFile(output);ready=true;break;}catch{await delay(100);}}
  assert.ok(ready);
  const app=c.getApp('cc.opencomputer.fixture');
  const before=await c.status();
  assert.notEqual(before.frontmostApp,'cc.opencomputer.fixture','fixture must begin in background');
  let tree=await app.getAXState();
  // The trap brings the fixture forward. The helper hands the foreground back and keeps working.
  const trapped=await app.click(tree.nodes.find(n=>n.identifier==='focus-trap').id);
  assert.equal(trapped.dispatched,true);
  assert.equal(trapped.focusChanged,true,'the app-side activation is reported');
  assert.equal(trapped.focusRestored,true,'the foreground is handed back');
  assert.equal(trapped.frontmostAfter,before.frontmostApp);
  await delay(400);
  let status=await c.status();
  assert.equal(status.frontmostApp,before.frontmostApp,'the person keeps the app they were in');
  assert.equal(status.focusProtectionBlocked,false,'a restored activation does not block the session');
  assert.ok(status.focusRestorations>=1);
  // The same snapshot and session stay usable, in either window.
  const field=tree.nodes.find(n=>n.identifier==='benchmark-input');
  assert.equal((await app.checkInteraction(field.id)).canProceed,true);
  assert.equal((await app.setValue(field.id,'after-trap')).focusChanged,false);
  tree=await app.getAXState();
  assert.equal(tree.nodes.find(n=>n.identifier==='benchmark-input').value,'after-trap');
  const other=tree.windows.find(w=>w.title==='Other fixture window');
  assert.ok(other);
  tree=await app.getAXState({window:other.index});
  assert.equal((await c.status()).activity.windowTitle,'Other fixture window','the pill names the observed window');
  assert.ok(!tree.nodes.some(n=>n.identifier==='benchmark-input'),'window observation is scoped to that window');
  const background=tree.nodes.find(n=>n.identifier==='background-input');
  assert.ok(background);
  const subtree=await app.getAXState({root:background.id});
  assert.equal(subtree.snapshot,tree.snapshot,'subtree expansion extends the current snapshot');
  assert.equal(subtree.nodes[0].id,background.id,'expanded elements keep their ids');
  assert.equal((await app.setValue(background.id,'background-work')).focusChanged,false);
  tree=await app.getAXState();
  assert.equal(tree.nodes.find(n=>n.identifier==='background-input').value,'background-work');
  assert.equal(tree.nodes.find(n=>n.identifier==='benchmark-input').value,'after-trap');
  // A preflight needs no element: it asks whether keys could go to this app now.
  const preflight=await app.checkInteraction(undefined,{intrusive:true});
  assert.equal(typeof preflight.canProceed,'boolean');
  assert.equal((await c.status()).frontmostApp,before.frontmostApp);
  console.log(JSON.stringify({passed:checks,activationReported:true,foregroundRestored:true,sessionUsable:true,unrelatedWindowWritable:true}));
}finally{await c.release().catch(()=>{});c.close();fixture.kill();await rm(dir,{recursive:true,force:true});}
