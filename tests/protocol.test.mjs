import test from 'node:test';
import assert from 'node:assert/strict';
import {handle,tools} from '../src/protocol.mjs';
const request = (method, params = {}, id = 1) => ({jsonrpc:'2.0',id,method,params});
const mock = {request:async (method,args) => ({method,...args})};
test('MCP initializes, lists tools, pings, and ignores notifications', async () => {
  assert.equal((await handle(request('initialize'),mock)).result.serverInfo.name,'opencomputer');
  assert.equal((await handle(request('tools/list'),mock)).result.tools.length,tools.length);
  assert.deepEqual((await handle(request('ping'),mock)).result,{});
  assert.equal(await handle({jsonrpc:'2.0',method:'notifications/initialized'},mock),null);
});
test('rejects unknown methods, malformed requests and tool arguments before execution',async () => {
  const never = {request:()=>{throw Error('must not execute');}};
  assert.equal((await handle(null,never)).error.code,-32600);
  assert.equal((await handle([],never)).error.code,-32600);
  assert.equal((await handle(request('unknown'),never)).error.code,-32601);
  for (const args of [{app:'a'},{app:'a',snapshot:'s',element:-1},{app:'a',snapshot:'s',element:true},{app:'a',snapshot:'s',element:1,extra:1}]) {
    assert.equal((await handle(request('tools/call',{name:'click',arguments:args}),never)).error.code,-32602);
  }
});
test('preserves native errors as tool errors, not false successes',async () => {
  const result = await handle(request('tools/call',{name:'observe',arguments:{app:'a'}}),{request:async()=>{throw Object.assign(Error('Denied'),{code:'APP_NOT_ALLOWED'});}});
  assert.equal(result.result.isError,true);
  assert.equal(JSON.parse(result.result.content[0].text).code,'APP_NOT_ALLOWED');
});
test('screenshots become image blocks with separate metadata',async () => {
  const result = await handle(request('tools/call',{name:'screenshot',arguments:{app:'a'}}),{request:async()=>({data:'YWJj',mimeType:'image/png',width:3})});
  assert.equal(result.result.content[0].type,'image');
  assert.equal(JSON.parse(result.result.content[1].text).data,undefined);
});
test('MCP identity reaches the native presentation and keyboard injection is absent', async () => {
  const names=[];
  const client={request:mock.request,setClientInfo:async name=>names.push(name)};
  await handle(request('initialize',{clientInfo:{name:'claude-code',version:'test'}}),client);
  assert.deepEqual(names,['claude-code']);
  assert.ok(tools.some(t=>t.name==='release'));
  assert.ok(!tools.some(t=>t.name==='pressKey'));
  assert.deepEqual(tools.find(t=>t.name==='performAction').inputSchema.properties.action.enum,['AXPress','AXIncrement','AXDecrement','AXPick']);
});
