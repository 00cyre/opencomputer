import test from 'node:test';
import assert from 'node:assert/strict';
import {handle,outline,tools} from '../src/protocol.mjs';
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
test('busy errors preserve retry guidance and no-dispatch evidence',async () => {
  const details={canProceed:false,reason:'editing-window',retryAfterMs:1000,dispatched:false};
  const result=await handle(request('tools/call',{name:'click',arguments:{app:'a',snapshot:'s',element:2}}),{request:async()=>{throw Object.assign(Error('Waiting'),{code:'USER_BUSY',details});}});
  assert.equal(result.result.isError,true);
  assert.deepEqual(JSON.parse(result.result.content[0].text).details,details);
  assert.equal(tools.find(t=>t.name==='checkInteraction').annotations.readOnlyHint,true);
});
test('screenshots become image blocks with separate metadata',async () => {
  const result = await handle(request('tools/call',{name:'screenshot',arguments:{app:'a'}}),{request:async()=>({data:'YWJj',mimeType:'image/png',width:3})});
  assert.equal(result.result.content[0].type,'image');
  assert.equal(JSON.parse(result.result.content[1].text).data,undefined);
});
test('MCP identity reaches the native presentation and the tool set covers background input', async () => {
  const names=[];
  const client={request:mock.request,setClientInfo:async name=>names.push(name)};
  await handle(request('initialize',{clientInfo:{name:'claude-code',version:'test'}}),client);
  assert.deepEqual(names,['claude-code']);
  for (const name of ['release','open','clickPoint','pressKey','typeText','scroll']) assert.ok(tools.some(t=>t.name===name),name);
  const actions=tools.find(t=>t.name==='performAction').inputSchema.properties.action.enum;
  assert.deepEqual(actions,['AXPress','AXIncrement','AXDecrement','AXPick','AXConfirm','AXCancel','AXScrollToVisible','AXOpen']);
  // Actions that raise a window or open a menu under the pointer stay out of the schema.
  assert.ok(!actions.includes('AXRaise')&&!actions.includes('AXShowMenu'));
  assert.ok(tools.find(t=>t.name==='click').inputSchema.properties.waitMs);
});
const tree={app:'cc.test',pid:7,snapshot:'s1',elapsedMs:12,frontmostApp:'cc.other',windows:[{index:0,title:'Main',main:true}],nodes:[
  {id:0,role:'AXWindow',title:'Main'},
  {id:1,parent:0,role:'AXGroup'},
  {id:2,parent:1,role:'AXTextField',title:'Search mail',value:'hello',identifier:'search'},
  {id:3,parent:1,role:'AXButton',title:'Send'}]};
test('observe returns a compact outline and drops unlabelled containers',async () => {
  const text=outline(tree);
  assert.match(text,/snapshot s1/);
  assert.match(text,/windows: \[0\] "Main" main/);
  assert.match(text,/\[2\] .*"Search mail".*#search.*="hello"/);
  assert.ok(!/\[1\]/.test(text),'unlabelled group is pruned');
  const indent=id=>text.split('\n').find(l=>l.includes(`[${id}]`)).search(/\S/);
  assert.equal(indent(2),indent(3));
  assert.ok(indent(2)>indent(0));
  const found=outline(tree,{query:'search MAIL'});
  assert.match(found,/1 of 4 elements match/);
  assert.ok(found.includes('[2]')&&!found.includes('[3]'));
  assert.match(outline(tree,{maxChars:40}),/outline cut at 40/);
});
test('observe strips query and format before the helper and honours json',async () => {
  const seen=[];
  const client={request:async(method,args)=>{seen.push(args);return tree;}};
  const text=(await handle(request('tools/call',{name:'observe',arguments:{app:'cc.test',query:'send'}}),client)).result.content[0].text;
  assert.ok(text.includes('[3]')&&!text.includes('[2]'));
  assert.ok(!('query' in seen[0])&&!('format' in seen[0]));
  const json=(await handle(request('tools/call',{name:'observe',arguments:{app:'cc.test',format:'json'}}),client)).result.content[0].text;
  assert.equal(JSON.parse(json).nodes.length,4);
});
