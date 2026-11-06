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
test('requests serialize and API consumes snapshots after mutations', async()=>{
  const c = new Computer({executable,apps:['cc.test']});
  try {
    const app=c.getApp('cc.test');
    await assert.rejects(app.click(1),{code:'OBSERVE_REQUIRED'});
    await app.getAXState();
    const action=await app.setValue(2,'hello');
    assert.equal(action.snapshot,'snapshot-1');
    assert.equal(action.app,'cc.test');
    await assert.rejects(app.click(1),{code:'OBSERVE_REQUIRED'});
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
