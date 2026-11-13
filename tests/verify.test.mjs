import test from 'node:test';
import assert from 'node:assert/strict';
import {changes, lines, outline} from '../src/outline.mjs';
import {Views, check, report, expectations, shortcutKey, pressByMenu} from '../src/flows.mjs';
import {guidance} from '../src/errors.mjs';
import {handle} from '../src/protocol.mjs';
import {verifyChain, summarize} from '../src/log.mjs';
import {createHash} from 'node:crypto';

const window = (nodes, extra = {}) => ({app:'cc.test', pid:7, snapshot:'s1', elapsedMs:5, frontmostApp:'cc.other', windows:[{index:0,title:'Draft - Notes',main:true}], nodes, ...extra});
const base = [
  {id:0, role:'AXWindow', title:'Draft - Notes'},
  {id:2, parent:0, role:'AXTextField', title:'Name', value:'Ada', settable:true},
  {id:3, parent:0, role:'AXButton', title:'Save', actions:['AXPress']},
  {id:4, parent:0, role:'AXCheckBox', title:'Remember', value:0, enabled:false},
];
const call = (name, args, id = 1) => ({jsonrpc:'2.0', id, method:'tools/call', params:{name, arguments:args}});
// A fake helper: observe returns the next scripted read; settle reports what it is given.
function helper(reads, {settled, stale = false, fail} = {}) {
  const calls = [];
  let i = 0;
  const request = async (method, args) => {
    calls.push({method, args});
    if (fail?.[method]) throw fail[method];
    if (method === 'settle') return settled ?? {watched:false};
    if (method === 'observe') {
      if (args.refresh && stale) throw Object.assign(new Error('gone'), {code:'STALE_SNAPSHOT'});
      return reads[Math.min(i++, reads.length - 1)];
    }
    return {dispatched:true, method, ...args, activity:{active:true}};
  };
  return {request, calls, computer:{request}};
}

test('check confirms, reports deviations, and refuses to prove absence from a cut-short read', () => {
  const read = window(base);
  const ok = check(read, [{element:2, valueContains:'ad'}, {query:'button save', enabled:true}, {windowTitle:'draft'}, {query:'Sheet', exists:false}]);
  assert.equal(ok.outcome, 'confirmed');
  const bad = check(read, [{element:2, value:'Grace'}, {query:'Remember', enabled:true}]);
  assert.equal(bad.outcome, 'deviation');
  assert.deepEqual(bad.results.map(r => r.met), [false, false]);
  assert.match(report(bad), /^outcome: deviation\. Expectations NOT met: 0 of 2 hold\./);
  assert.match(report(bad), /NOT MET \{"element":2,"value":"Grace"\}: found \[2\] TextField "Name" ="Ada" editable/);
  // Numbers compare as text, and a missing element is "nothing matches".
  assert.equal(check(read, [{element:4, value:'0'}]).outcome, 'confirmed');
  assert.match(report(check(read, [{element:99}])), /nothing matches/);
  assert.equal(check(window(base, {truncated:true}), [{query:'Sheet', exists:false}]).outcome, 'unverifiable');
  assert.throws(() => check(read, [{exists:true}]), /element, query, or windowTitle/);
});

test('expectations re-read until conditions hold and keep the first diff base', async () => {
  const views = new Views();
  views.remember('cc.test', window(base), {});
  const later = window([...base, {id:5, parent:0, role:'AXSheet', title:'Saved'}]);
  const {request, calls} = helper([window(base), later]);
  let clock = 0;
  const out = await expectations(request, views, {app:'cc.test'}, [{query:'Sheet Saved'}], {timeoutMs:2000, wait:async ms => { clock += ms; }, now:() => clock});
  assert.equal(out.verdict.outcome, 'confirmed');
  assert.equal(calls.filter(c => c.method === 'observe').length, 2);
  assert.ok(calls.every(c => c.args.refresh), 'reads keep the snapshot');
  assert.equal(out.before.get(5), undefined, 'the diff base is the read before the first re-read');
});

test('changes say when the app reported nothing, and name the focused element and open dialogs', () => {
  const before = lines(window(base));
  const quiet = changes(before, window(base), {settled:{watched:true, settled:true, waitedMs:210, notifications:0}, quietHint:'Try via menu.'});
  assert.match(quiet, /settled after 210 ms; the app sent 0 accessibility notifications/);
  assert.match(quiet, /most likely had no effect\. Try via menu\./);
  const hidden = changes(before, window(base), {settled:{watched:true, settled:true, waitedMs:300, notifications:4, kinds:{ValueChanged:3, Created:1}}});
  assert.match(hidden, /4 accessibility notifications \(ValueChanged 3, Created 1\)/);
  assert.match(hidden, /changes this outline does not show/);
  const focused = changes(before, window([...base.slice(0,1), {...base[1], focused:true}, ...base.slice(2), {id:5, parent:0, role:'AXSheet', title:'Save changes?'}]));
  assert.match(focused, /^focused: \[2\] TextField "Name"/m);
  assert.match(focused, /^open dialog: \[5\] Sheet "Save changes\?"\. Answer it first/m);
  assert.match(outline(window([{id:0, role:'AXWindow', subrole:'AXDialog', title:'Alert'}])), /open dialog: \[0\] Window\/Dialog "Alert"/);
});

test('shortcuts compare in one spelling and pressKey via menu presses the matching item', async () => {
  assert.equal(shortcutKey('Cmd+Shift+K'), shortcutKey('shift+cmd+k'));
  assert.equal(shortcutKey('command+option+Return'), 'alt+cmd+return');
  const menu = {app:'cc.test', pid:7, snapshot:'s1', nodes:[
    {id:10, role:'AXMenuBarItem', title:'Tools'},
    {id:11, parent:10, role:'AXMenu'},
    {id:12, parent:11, role:'AXMenuItem', title:'Stamp Document…', shortcut:'shift+cmd+k', actions:['AXPress']},
    {id:13, parent:11, role:'AXMenuItem', title:'Archive', shortcut:'cmd+e', enabled:false},
  ]};
  const {request, calls} = helper([menu]);
  const result = await pressByMenu(request, {app:'cc.test', key:'cmd+shift+K'});
  assert.equal(result.menuItem, 'Tools > Stamp Document…');
  assert.equal(result.delivery, 'menu');
  assert.deepEqual(calls.at(-1), {method:'click', args:{app:'cc.test', snapshot:'s1', element:12}});
  assert.equal(calls[0].args.menu, true);
  await assert.rejects(pressByMenu(request, {app:'cc.test', key:'cmd+e'}), e => e.code === 'MENU_ITEM_DISABLED' && /Tools > Archive/.test(e.message));
  await assert.rejects(pressByMenu(request, {app:'cc.test', key:'cmd+j'}), e => e.code === 'MENU_ITEM_NOT_FOUND' && e.details.dispatched === false);
  await assert.rejects(pressByMenu(request, {app:'cc.test', key:'cmd+e', count:2}), e => e.code === 'INVALID_ARGUMENT');
});

test('actions compare by default once the app was observed, and not before', async () => {
  const {computer, calls} = helper([window(base), window([...base.slice(0,1), {...base[1], value:'Ada L'}, ...base.slice(2)])], {settled:{watched:true, settled:true, waitedMs:200, notifications:2, kinds:{ValueChanged:2}}});
  const cold = await handle(call('click', {app:'cc.test', snapshot:'s1', element:3}), computer);
  assert.equal(cold.result.content.length, 1, 'no earlier read: nothing to compare');
  await handle(call('observe', {app:'cc.test'}), computer);
  const warm = await handle(call('setValue', {app:'cc.test', snapshot:'s1', element:2, value:'Ada L'}), computer);
  assert.equal(warm.result.content.length, 2);
  assert.match(warm.result.content[1].text, /~ \[2\] TextField "Name" ="Ada L"/);
  assert.match(warm.result.content[1].text, /settled after 200 ms/);
  assert.ok(calls.some(c => c.method === 'settle'));
  const skipped = await handle(call('click', {app:'cc.test', snapshot:'s1', element:3, changes:false}), computer);
  assert.equal(skipped.result.content.length, 1);
});

test('a default comparison never replaces the snapshot when the old one is gone', async () => {
  const {computer, calls} = helper([window(base)], {stale:true});
  await handle(call('observe', {app:'cc.test'}), computer);
  const result = await handle(call('click', {app:'cc.test', snapshot:'s1', element:3}), computer);
  assert.match(result.result.content[1].text, /Not compared: the earlier snapshot of this app is gone/);
  assert.equal(calls.filter(c => c.method === 'observe' && !c.args.refresh).length, 1, 'no fresh observe after the action');
});

test('a quiet pressKey chord suggests the menu, and via menu goes through the menu bar', async () => {
  const menu = {app:'cc.test', pid:7, snapshot:'s1', nodes:[{id:10, role:'AXMenuBarItem', title:'File'}, {id:11, parent:10, role:'AXMenu'}, {id:12, parent:11, role:'AXMenuItem', title:'Save', shortcut:'cmd+s'}]};
  const {computer, calls} = helper([window(base), window(base), menu, window(base)], {settled:{watched:true, settled:true, waitedMs:200, notifications:0}});
  await handle(call('observe', {app:'cc.test'}), computer);
  const quiet = await handle(call('pressKey', {app:'cc.test', key:'cmd+s'}), computer);
  assert.match(quiet.result.content[1].text, /no effect\. Background apps often ignore shortcuts sent as keys: pressKey with via "menu"/);
  const viaMenu = await handle(call('pressKey', {app:'cc.test', key:'cmd+s', via:'menu'}), computer);
  assert.equal(JSON.parse(viaMenu.result.content[0].text).menuItem, 'File > Save');
  assert.ok(!calls.some(c => c.method === 'pressKey' && c.args.via), 'via never reaches the helper');
  assert.ok(!/via "menu"/.test(viaMenu.result.content[1].text), 'no menu hint after using the menu');
});

test('batch compares once at the end and stops when a step\'s expectations fail', async () => {
  const {computer, calls} = helper([window(base)]);
  await handle(call('observe', {app:'cc.test'}), computer);
  const steps = [{tool:'setValue', arguments:{app:'cc.test', snapshot:'s1', element:2, value:'x'}}, {tool:'click', arguments:{app:'cc.test', snapshot:'s1', element:3}}];
  const ran = await handle(call('batch', {steps}), computer);
  assert.equal(calls.filter(c => c.method === 'settle').length, 1, 'only the last action settles and compares');
  assert.match(ran.result.content.at(-1).text, /No changes since the last read/);
  const failing = await handle(call('batch', {steps:[{...steps[0], arguments:{...steps[0].arguments, expect:[{query:'Sheet Saved'}]}}, steps[1]]}), computer);
  assert.equal(failing.result.isError, true);
  const error = JSON.parse(failing.result.content.at(-1).text);
  assert.equal(error.code, 'EXPECTATION_FAILED');
  assert.equal(error.details.completed, 1);
  assert.equal(error.retrySafe, false, 'the step was sent');
  assert.ok(failing.result.content.some(c => /outcome: deviation/.test(c.text)));
  assert.equal(calls.filter(c => c.method === 'click').length, 1, 'the click after the failed step never ran');
  const invalid = await handle(call('click', {app:'cc.test', snapshot:'s1', element:3, expect:[{exists:false}]}), computer);
  assert.equal(invalid.error.code, -32602);
});

test('verify reads without acting and says whether ids still apply', async () => {
  const {computer, calls} = helper([window(base), window(base)]);
  const fresh = await handle(call('verify', {app:'cc.test', expect:[{query:'Button Save'}]}), computer);
  assert.match(fresh.result.content[0].text, /^outcome: confirmed/);
  assert.match(fresh.result.content[0].text, /new snapshot: use the ids shown here/);
  const again = await handle(call('verify', {app:'cc.test', expect:[{element:2, value:'Grace'}]}), computer);
  assert.match(again.result.content[0].text, /^outcome: deviation/);
  assert.match(again.result.content[0].text, /re-read; earlier ids still apply/);
  assert.ok(calls.every(c => ['observe'].includes(c.method)), 'verify only reads');
});

test('errors say whether repeating is safe and what to call next', async () => {
  assert.deepEqual(guidance({code:'STALE_SNAPSHOT'}, 'click', {app:'a', snapshot:'s', element:1}), {retrySafe:true, next:{tool:'observe', arguments:{app:'a'}}});
  assert.deepEqual(guidance({code:'USER_BUSY', details:{dispatched:false, retryAfterMs:800}}, 'click', {app:'a'}).next, {tool:'click', arguments:{app:'a'}, afterMs:800});
  assert.equal(guidance({code:'TIMEOUT'}, 'click', {app:'a'}).retrySafe, false);
  assert.match(guidance({code:'HOST_APP_PROTECTED', details:{dispatched:false}}, 'click', {app:'a'}).hint, /runs in/);
  assert.deepEqual(guidance({code:'APP_NOT_RUNNING'}, 'observe', {app:'a'}).next, {tool:'open', arguments:{app:'a'}});
  const {computer} = helper([window(base)], {fail:{observe:Object.assign(new Error('gone'), {code:'STALE_SNAPSHOT'})}});
  const failed = await handle(call('batch', {steps:[{tool:'observe', arguments:{app:'cc.test', window:0}}]}), computer);
  const error = JSON.parse(failed.result.content.at(-1).text);
  assert.deepEqual(error.next, {tool:'observe', arguments:{app:'cc.test'}}, 'advice is for the failing step');
});

test('release forgets earlier reads, so the next action does not compare against them', async () => {
  const {computer, calls} = helper([window(base)]);
  await handle(call('observe', {app:'cc.test'}), computer);
  await handle(call('release', {}), computer);
  const result = await handle(call('click', {app:'cc.test', snapshot:'s1', element:3}), computer);
  assert.equal(result.result.content.length, 1);
  assert.ok(!calls.some(c => c.method === 'settle'));
});

const sha = text => createHash('sha256').update(text).digest('hex').slice(0, 32);
test('the log chain finds a line changed or removed inside a session file', () => {
  const rows = [];
  let prev = '';
  for (const entry of [{event:'session'}, {event:'click', app:'a', outcome:'dispatched'}, {event:'typeText', app:'a', textLength:3, outcome:'dispatched'}]) {
    const row = JSON.stringify({time:'2026-11-13T10:00:00.000Z', prev, ...entry});
    rows.push(row); prev = sha(row);
  }
  assert.deepEqual(verifyChain(rows.join('\n') + '\n'), {ok:true, chained:true, lines:3});
  const edited = [rows[0], rows[1].replace('"a"', '"b"'), rows[2]];
  assert.equal(verifyChain(edited.join('\n')).line, 3);
  assert.match(verifyChain([rows[0], rows[2]].join('\n')).problem, /changed or removed/);
  assert.deepEqual(verifyChain('{"time":"x","event":"session"}\n'), {ok:true, chained:false, lines:1});
  assert.match(verifyChain(rows[0] + '\n{"time":').problem, /incomplete/);
});

test('log summaries count actions, refusals, failures, and apps per session', () => {
  const [s] = summarize([
    {session:'a', agent:'claude-code', helperPid:1, time:'2026-11-13T10:00:00.000Z', event:'session'},
    {session:'a', time:'2026-11-13T10:00:01.000Z', event:'observe', app:'x', outcome:'ok'},
    {session:'a', time:'2026-11-13T10:00:02.000Z', event:'click', app:'x', outcome:'dispatched'},
    {session:'a', time:'2026-11-13T10:00:03.000Z', event:'typeText', app:'y', outcome:'refused'},
    {session:'a', time:'2026-11-13T10:00:04.000Z', event:'open', app:'z', outcome:'ok'},
  ]);
  assert.deepEqual({actions:s.actions, refused:s.refused, failed:s.failed, reads:s.reads, apps:s.apps}, {actions:2, refused:1, failed:0, reads:1, apps:['x','z']});
});
