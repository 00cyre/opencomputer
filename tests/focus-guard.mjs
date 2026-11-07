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
  // A fresh connection still respects the user's focused editor. No synthetic
  // typing or pointer movements are needed to exercise the production detector.
  const fresh=createComputer({apps:['*'],agent:'Interaction test'});
  try {
    const windows=fresh.getApp('cc.opencomputer.fixture');
    tree=await windows.getAXState();
    const field=tree.nodes.find(n=>n.identifier==='benchmark-input');
    const decision=await windows.checkInteraction(field.id);
    assert.equal(decision.canProceed,false);
    assert.equal(decision.reason,'editing-window');
    await assert.rejects(windows.setValue(field.id,'must not write'),error=>{
      assert.equal(error.code,'USER_BUSY');
      assert.equal(error.details.dispatched,false);
      assert.equal(error.details.reason,'editing-window');
      assert.ok(error.details.retryAfterMs>0);
      return true;
    });
    const waiting=await fresh.status();
    assert.match(waiting.activity.action,/Waiting/);
    assert.equal(waiting.focusProtectionBlocked,false,'ordinary activity does not latch a permanent focus block');
    tree=await windows.getAXState();
    assert.equal(tree.nodes.find(n=>n.identifier==='benchmark-input').value,'','busy rejection leaves the field untouched');
    const other=tree.windows.find(w=>w.title==='Other fixture window');
    assert.ok(other);
    tree=await windows.getAXState({window:other.index});
    assert.equal((await fresh.status()).activity.windowTitle,'Other fixture window','the pill names the observed window');
    assert.ok(!tree.nodes.some(n=>n.identifier==='benchmark-input'),'window observation excludes the foreground editor');
    let background=tree.nodes.find(n=>n.identifier==='background-input');
    assert.ok(background);
    tree=await windows.getAXState({root:background.id});
    assert.equal(tree.nodes[0].identifier,'background-input','subtree expansion resolves the selected element');
    assert.equal(tree.nodes.length,1);
    assert.equal((await windows.checkInteraction(0)).canProceed,true,'an unrelated window of the same app remains available');
    assert.equal((await windows.setValue(0,'background-work')).focusChanged,false);
    tree=await windows.getAXState();
    assert.equal(tree.nodes.find(n=>n.identifier==='background-input').value,'background-work');
    assert.equal(tree.nodes.find(n=>n.identifier==='benchmark-input').value,'');
    assert.equal((await fresh.status()).frontmostApp,'cc.opencomputer.fixture');
    console.log(JSON.stringify({passed:checks,detectedFocusChange:true,furtherActionsBlocked:true,editingWindowProtected:true,unrelatedWindowWritable:true}));
  } finally {await fresh.release().catch(()=>{});fresh.close();}
}finally{await c.release().catch(()=>{});c.close();fixture.kill();await rm(dir,{recursive:true,force:true});}
