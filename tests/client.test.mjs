import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {Computer} from '../src/computer.mjs';
const dir = await mkdtemp(join(tmpdir(),'opencomputer-test-'));
const executable = join(dir,'helper');
await writeFile(executable,`#!/usr/bin/env node\nconst r=require('node:readline').createInterface({input:process.stdin});r.on('line',line=>{const v=JSON.parse(line);if(v.method==='hang')return;if(v.method==='bad')return console.log('not json');console.log(JSON.stringify({result:{...v,snapshot:'snapshot-1'}}));});`,{mode:0o755});
process.on('exit',()=>{});
test.after(async()=>rm(dir,{recursive:true,force:true}));
test('requests serialize and the snapshot stays usable across actions', async()=>{
  const c = new Computer({executable,apps:['cc.test']});
  try {
    const app=c.getApp('cc.test');
    await assert.rejects(app.click(1),{code:'OBSERVE_REQUIRED'});
    await app.getAXState();
    const action=await app.setValue(2,'hello');
    assert.equal(action.snapshot,'snapshot-1');
    assert.equal(action.app,'cc.test');
    assert.equal((await app.click(1)).snapshot,'snapshot-1');
    const key=await app.pressKey('Return');
    assert.equal(key.key,'Return');
    assert.equal(key.element,undefined);
    assert.equal((await app.pressKey('Tab',{element:2,count:2})).element,2);
    assert.equal((await app.clickPoint(10,20)).x,10);
    assert.equal((await c.getApp('cc.test',{pid:42}).open('https://example.com')).url,'https://example.com');
    const results=await Promise.all([c.status(),c.getState()]);
    assert.deepEqual(results.map(x=>x.method),['status','apps']);
  } finally {c.close();}
});
test('timeout closes connection, preventing late responses from matching another request',async()=>{
  const c=new Computer({executable,timeoutMs:200});
  await assert.rejects(c.request('hang'),{code:'TIMEOUT'});
  await assert.rejects(c.status(),{code:'CLOSED'});
});
test('malformed helper response fails closed',async()=>{
  const c=new Computer({executable});
  await assert.rejects(c.request('bad'));
  await assert.rejects(c.status(),{code:'CLOSED'});
});
test('missing helper reports build instruction',async()=>{
  const c=new Computer({executable:join(dir,'missing')});
  await assert.rejects(c.status(),{code:'HELPER_UNAVAILABLE'});
});
test('explicit agent attribution overrides inferred client names and release reaches native host',async()=>{
  const c=new Computer({executable,agent:'Claude'});
  try {assert.equal(await c.setClientInfo('different-client'),undefined);assert.equal((await c.release()).method,'release');}
  finally {c.close();}
  const inferred=new Computer({executable});
  try {assert.equal((await inferred.setClientInfo('grok-build')).agent,'grok-build');}
  finally {inferred.close();}
});
test('interaction preflight preserves the snapshot and window/subtree observations carry their scope',async()=>{
  const c=new Computer({executable,apps:['*']});
  try {
    const app=c.getApp('cc.test');
    await assert.rejects(app.checkInteraction(2),{code:'OBSERVE_REQUIRED'});
    await assert.rejects(app.getAXState({root:2}),{code:'OBSERVE_REQUIRED'});
    const window=await app.getAXState({window:1});
    assert.equal(window.window,1);
    const subtree=await app.getAXState({root:2});
    assert.equal(subtree.root,2);
    assert.equal(subtree.snapshot,'snapshot-1');
    const decision=await app.checkInteraction(3);
    assert.equal(decision.method,'checkInteraction');
    assert.equal(decision.snapshot,'snapshot-1');
    assert.equal((await app.click(3)).snapshot,'snapshot-1');
    assert.equal((await app.checkInteraction(3)).snapshot,'snapshot-1');
    assert.equal((await app.checkInteraction()).element,undefined);
    assert.throws(()=>new Computer({executable,apps:['com.apple.*']}),TypeError);
  } finally {c.close();}
});
test('a helper inside a TCC-protected folder is staged under Application Support', async()=>{
  const {stageExecutable} = await import('../src/computer.mjs');
  const {mkdir} = await import('node:fs/promises');
  const {existsSync} = await import('node:fs');
  const home = await mkdtemp(join(tmpdir(),'opencomputer-home-'));
  try {
    await mkdir(join(home,'Documents','oc'),{recursive:true});
    const inside = join(home,'Documents','oc','opencomputer-native');
    await writeFile(inside,'#!/bin/sh\n',{mode:0o755});
    const staged = stageExecutable(inside,home);
    if (process.platform === 'darwin') {
      assert.ok(staged.startsWith(join(home,'Library','Application Support','OpenComputer','helper')));
      assert.ok(existsSync(staged));
      assert.equal(stageExecutable(inside,home),staged);
    } else assert.equal(staged,inside);
    const outside = join(home,'opencomputer-native');
    await writeFile(outside,'#!/bin/sh\n',{mode:0o755});
    assert.equal(stageExecutable(outside,home),outside);
  } finally { await rm(home,{recursive:true,force:true}); }
});
