import test from 'node:test';
import assert from 'node:assert/strict';
import {changes, lines, outline} from '../src/outline.mjs';
import {Views, read, waitFor, findMenuItem, chooseMenu} from '../src/flows.mjs';
import {handle, tools} from '../src/protocol.mjs';

const window = (nodes, extra = {}) => ({app:'cc.test', pid:7, snapshot:'s1', elapsedMs:5, frontmostApp:'cc.other', windows:[{index:0,title:'Main',main:true}], nodes, ...extra});
const base = [
  {id:0, role:'AXWindow', title:'Main'},
  {id:1, parent:0, role:'AXGroup'},
  {id:2, parent:1, role:'AXTextField', title:'Name', value:'Ada', settable:true},
  {id:3, parent:1, role:'AXButton', title:'Save', actions:['AXPress']},
  {id:4, parent:1, role:'AXButton', title:'Old', actions:['AXPress']},
];

test('changes lists only what was added, removed, or reads differently, with shared ids', () => {
  const before = lines(window(base));
  const after = window([...base.slice(0,2), {...base[2], value:'Ada Lovelace', focused:true}, base[3], {id:5, parent:0, role:'AXSheet', title:'Saved'}]);
  const text = changes(before, after);
  assert.match(text, /re-read; earlier ids still apply/);
  assert.match(text, /1 added, 1 changed, 1 removed/);
  assert.match(text, /^\+ \[5\] Sheet "Saved"$/m);
  assert.match(text, /^~ \[2\] TextField "Name" ="Ada Lovelace" editable focused$/m);
  assert.match(text, /^ {4}was: TextField "Name" ="Ada" editable$/m);
  assert.match(text, /^- \[4\] Button "Old"$/m);
  assert.ok(!/\[3\]/.test(text), 'unchanged elements are not repeated');
  assert.match(changes(before, window(base)), /No changes since the last read/);
  // A truncated read cannot prove anything went away.
  const partial = changes(before, window(base.slice(0,3), {truncated:true}));
  assert.ok(!/^- /m.test(partial));
  assert.match(partial, /not reported as removed/);
});

test('menu items show their shortcut in pressKey syntax', () => {
  const text = outline(window([{id:0, role:'AXMenuItem', title:'Save As…', shortcut:'cmd+shift+s', actions:['AXPress']}]));
  assert.match(text, /\[0\] MenuItem "Save As…" keys:cmd\+shift\+s/);
});

// A fake helper: observe returns the next scripted read and records every request.
function helper(reads, {stale = false} = {}) {
  const calls = [];
  let i = 0;
  const request = async (method, args) => {
    calls.push({method, args});
    if (method === 'observe') {
      if (args.refresh && stale) throw Object.assign(new Error('gone'), {code:'STALE_SNAPSHOT'});
      return reads[Math.min(i++, reads.length - 1)];
    }
    return {dispatched:true, method, ...args, activity:{active:true}};
  };
  return {request, calls};
}

test('read re-reads the last scope into the same snapshot and falls back when it is gone', async () => {
  const views = new Views();
  const {request, calls} = helper([window(base), window(base)]);
  const first = await read(request, views, {app:'cc.test', window:0}, {refresh:true});
  assert.equal(first.before, undefined, 'nothing to compare with yet');
  assert.equal(calls[0].args.refresh, undefined);
  const second = await read(request, views, {app:'cc.test'}, {refresh:true});
  assert.ok(second.before instanceof Map);
  assert.deepEqual(calls[1].args, {app:'cc.test', window:0, refresh:true, snapshot:'s1'});
  const lost = helper([window(base)], {stale:true});
  const views2 = new Views();
  views2.remember('cc.test', window(base), {});
  const fallback = await read(lost.request, views2, {app:'cc.test'}, {refresh:true});
  assert.equal(fallback.before, undefined);
  assert.equal(lost.calls.length, 2);
  assert.equal(lost.calls[1].args.refresh, undefined, 'falls back to a fresh observe');
});

test('waitFor re-reads until the query matches, or until it is gone, and times out with evidence', async () => {
  let clock = 0;
  const timing = {wait:async ms => { clock += ms; }, now:() => clock};
  const sheet = {id:9, parent:0, role:'AXSheet', title:'Export'};
  const {request, calls} = helper([window(base), window(base), window([...base, sheet])]);
  const found = await waitFor(request, new Views(), {app:'cc.test', query:'sheet export'}, timing);
  assert.equal(found.reads, 3);
  assert.deepEqual(found.matches.map(n => n.id), [9]);
  assert.equal(calls[1].args.refresh, true, 'later reads keep ids');
  const gone = helper([window([...base, sheet]), window(base)]);
  assert.equal((await waitFor(gone.request, new Views(), {app:'cc.test', query:'sheet', gone:true}, timing)).reads, 2);
  clock = 0;
  const never = helper([window(base)]);
  await assert.rejects(waitFor(never.request, new Views(), {app:'cc.test', query:'sheet', timeoutMs:1000}, timing), e => e.code === 'WAIT_TIMEOUT' && e.details.reads > 1 && e.details.matches === 0);
  await assert.rejects(waitFor(never.request, new Views(), {app:'cc.test', query:'  '}, timing), {code:'INVALID_ARGUMENT'});
});

const menuBar = window([
  {id:20, role:'AXMenuBar'},
  {id:21, parent:20, role:'AXMenuBarItem', title:'File'},
  {id:22, parent:21, role:'AXMenu'},
  {id:23, parent:22, role:'AXMenuItem', title:'Save', shortcut:'cmd+s'},
  {id:24, parent:22, role:'AXMenuItem', title:'Export as PDF…'},
  {id:25, parent:22, role:'AXMenuItem', title:'Share'},
  {id:26, parent:25, role:'AXMenu'},
  {id:27, parent:26, role:'AXMenuItem', title:'Mail', enabled:false},
  {id:28, parent:20, role:'AXMenuBarItem', title:'Edit'},
], {snapshot:'m1'});

test('menu paths match case-insensitively, ignore ellipses, and explain misses', () => {
  assert.equal(findMenuItem(menuBar.nodes, 'file > export as pdf').node.id, 24);
  assert.equal(findMenuItem(menuBar.nodes, ['File', 'Save']).node.id, 23);
  assert.throws(() => findMenuItem(menuBar.nodes, 'File > Print'), e => e.code === 'MENU_ITEM_NOT_FOUND' && e.details.available.includes('Export as PDF…'));
  assert.throws(() => findMenuItem(menuBar.nodes, 'File > Share > Mail'), {code:'MENU_ITEM_DISABLED'});
  assert.throws(() => findMenuItem(menuBar.nodes, 'File > Share'), e => e.code === 'INVALID_ARGUMENT' && e.details.available[0] === 'Mail');
  assert.throws(() => findMenuItem(menuBar.nodes, 'File'), {code:'INVALID_ARGUMENT'});
});

test('chooseMenu reads the menu bar and presses the item in that snapshot', async () => {
  const {request, calls} = helper([menuBar]);
  const result = await chooseMenu(request, {app:'cc.test', path:'File > Save', waitMs:0});
  assert.deepEqual(calls[0], {method:'observe', args:{app:'cc.test', menu:true, limit:5000}});
  assert.deepEqual(calls[1].args, {app:'cc.test', snapshot:'m1', element:23, waitMs:0});
  assert.equal(result.menuItem, 'File > Save');
  assert.equal(result.shortcut, 'cmd+s');
});

const call = (name, args, id = 1) => ({jsonrpc:'2.0', id, method:'tools/call', params:{name, arguments:args}});

test('MCP observe and actions with changes return a diff that keeps ids', async () => {
  const computer = helper([window(base), window([...base, {id:5, parent:0, role:'AXSheet', title:'Saved'}])]);
  computer.request.bind(computer);
  const client = {request:computer.request};
  const full = (await handle(call('observe', {app:'cc.test'}), client)).result.content[0].text;
  assert.match(full, /\[3\] Button "Save"/);
  const clicked = (await handle(call('click', {app:'cc.test', snapshot:'s1', element:3, changes:true}), client)).result.content;
  assert.equal(JSON.parse(clicked[0].text).activity, undefined);
  assert.equal(JSON.parse(clicked[0].text).changes, undefined, 'changes stays in the server');
  assert.match(clicked[1].text, /^\+ \[5\] Sheet "Saved"$/m);
  const reread = computer.calls.filter(c => c.method === 'observe').at(-1).args;
  assert.equal(reread.refresh, true);
  assert.equal(reread.snapshot, 's1');
});

test('MCP waitFor, menu, and readText are exposed with schemas', async () => {
  for (const name of ['waitFor','menu','batch','readText']) assert.ok(tools.some(t => t.name === name), name);
  assert.equal(tools.find(t => t.name === 'readText').annotations.readOnlyHint, true);
  assert.equal(tools.find(t => t.name === 'waitFor').annotations.readOnlyHint, true);
  assert.equal(tools.find(t => t.name === 'menu').annotations.readOnlyHint, false);
  const computer = helper([menuBar]);
  const menu = await handle(call('menu', {app:'cc.test', path:'File > Export as PDF'}), {request:computer.request});
  assert.equal(JSON.parse(menu.result.content[0].text).element, 24);
  const missing = await handle(call('menu', {app:'cc.test', path:'File > Nope'}), {request:computer.request});
  assert.equal(missing.result.isError, true);
  assert.equal(JSON.parse(missing.result.content[0].text).code, 'MENU_ITEM_NOT_FOUND');
});

test('batch validates every step first, runs them in order, and stops at the first error', async () => {
  const never = {request:() => { throw Error('must not execute'); }};
  for (const steps of [[], [{tool:'batch', arguments:{steps:[]}}], [{tool:'click', arguments:{app:'a', snapshot:'s', element:1}}, {tool:'click', arguments:{app:'a'}}], [{tool:'nope'}]]) {
    assert.equal((await handle(call('batch', {steps}), never)).error?.code, -32602, JSON.stringify(steps));
  }
  const seen = [];
  const client = {request:async (method, args) => {
    seen.push(method);
    if (method === 'pressKey') throw Object.assign(Error('Waiting'), {code:'USER_BUSY', details:{dispatched:false}});
    return {dispatched:true, method};
  }};
  const ok = await handle(call('batch', {steps:[{tool:'setValue', arguments:{app:'a', snapshot:'s', element:1, value:'x'}}, {tool:'click', arguments:{app:'a', snapshot:'s', element:2}}]}), client);
  assert.match(ok.result.content[0].text, /All 2 steps ran/);
  assert.deepEqual(seen, ['setValue','click']);
  seen.length = 0;
  const stopped = await handle(call('batch', {steps:[{tool:'click', arguments:{app:'a', snapshot:'s', element:2}}, {tool:'pressKey', arguments:{app:'a', key:'Return'}}, {tool:'click', arguments:{app:'a', snapshot:'s', element:3}}]}), client);
  assert.equal(stopped.result.isError, true);
  assert.deepEqual(seen, ['click','pressKey'], 'the step after the failure never runs');
  const failure = JSON.parse(stopped.result.content.at(-1).text);
  assert.deepEqual([failure.code, failure.details.step, failure.details.completed], ['USER_BUSY', 2, 1]);
  assert.match(stopped.result.content[0].text, /step 1: click/);
});

test('screenshot options: region is validated, ocr text becomes its own block, image can be left out', async () => {
  const never = {request:() => { throw Error('must not execute'); }};
  for (const region of [{x:1, y:2, width:3}, {x:1, y:2, width:3, height:-1}, {x:1, y:2, width:3, height:4, z:1}, [1,2,3,4]]) {
    assert.equal((await handle(call('screenshot', {app:'a', region}), never)).error?.code, -32602, JSON.stringify(region));
  }
  let sent;
  const client = {request:async (method, args) => { sent = args; return {mimeType:'image/png', data:'YWJj', width:3, lines:[{text:'Total 42', x:1, y:2, width:30, height:9, confidence:0.9}]}; }};
  const result = (await handle(call('screenshot', {app:'a', ocr:true, image:false, region:{x:0, y:0, width:10, height:10}}), client)).result.content;
  assert.equal(sent.image, undefined, 'image stays in the server');
  assert.deepEqual(sent.region, {x:0, y:0, width:10, height:10});
  assert.equal(result.length, 2);
  assert.equal(JSON.parse(result[0].text).lines, undefined);
  assert.match(result[1].text, /^\[1,2,30,9\] Total 42$/m);
  const withImage = (await handle(call('screenshot', {app:'a', marks:true}), client)).result.content;
  assert.equal(withImage[0].type, 'image');
});
