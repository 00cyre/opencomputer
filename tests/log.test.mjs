import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {readLog, formatEntry} from '../src/log.mjs';

const dir = await mkdtemp(join(tmpdir(), 'opencomputer-log-'));
test.after(() => rm(dir, {recursive: true, force: true}));
const lines = entries => entries.map(x => JSON.stringify(x)).join('\n') + '\n';
await writeFile(join(dir, 'session-2026-11-11T140000Z-11.jsonl'), lines([
  {time: '2026-11-11T14:00:00.000Z', event: 'session', helperPid: 11, agent: 'Agent', version: '0.4.1', apps: ['com.google.Chrome']},
  {time: '2026-11-11T14:00:01.000Z', event: 'configure', agent: 'claude-code', outcome: 'ok'},
  {time: '2026-11-11T14:31:10.500Z', event: 'click', app: 'com.google.Chrome', target: {role: 'AXButton', label: 'Verify'}, window: 'Cloudflare - Google Chrome', tab: 'Cloudflare', outcome: 'dispatched', dispatched: true, delivery: 'AXPress'},
]) + 'not json\n');
await writeFile(join(dir, 'session-2026-11-11T141500Z-22.jsonl'), lines([
  {time: '2026-11-11T14:15:00.000Z', event: 'session', helperPid: 22, agent: 'grok', version: '0.4.1', apps: ['*']},
  {time: '2026-11-11T14:31:12.000Z', event: 'click', app: 'com.google.Chrome', target: {role: 'AXButton', label: 'Save'}, window: 'Tanosia - Google Chrome', outcome: 'refused', dispatched: false, error: {code: 'TARGET_CHANGED', details: {reason: 'window-title'}}},
  {time: '2026-11-11T14:31:13.000Z', event: 'typeText', app: 'com.apple.TextEdit', textLength: 12, target: {role: 'AXTextArea'}, outcome: 'dispatched', delivery: 'AXValue'},
]));
await writeFile(join(dir, 'unrelated.txt'), 'ignored');

test('entries from every session merge in time order with their agent', async () => {
  const all = await readLog({dir});
  assert.deepEqual(all.map(x => x.time.slice(11, 19)), ['14:00:00', '14:00:01', '14:15:00', '14:31:10', '14:31:12', '14:31:13']);
  const verify = all.find(x => x.target?.label === 'Verify');
  assert.equal(verify.agent, 'claude-code');
  assert.equal(verify.helperPid, 11);
  assert.equal(all.find(x => x.target?.label === 'Save').agent, 'grok');
});
test('time window and app filters', async () => {
  const since = Date.parse('2026-11-11T14:31:00Z');
  assert.equal((await readLog({dir, since})).length, 3);
  assert.deepEqual((await readLog({dir, since, app: 'com.google.Chrome'})).map(x => x.target.label), ['Verify', 'Save']);
  assert.deepEqual(await readLog({dir: join(dir, 'missing')}), []);
});
test('formatted lines name who, what, where, and the outcome', async () => {
  const [click, refused, typed] = (await readLog({dir, since: Date.parse('2026-11-11T14:31:00Z')})).map(formatEntry);
  assert.match(click, /\[claude-code 11\] click Button "Verify" in com\.google\.Chrome window "Cloudflare - Google Chrome" tab "Cloudflare" -> dispatched via AXPress$/);
  assert.match(refused, /refused TARGET_CHANGED \(window-title\)$/);
  assert.match(typed, /typeText TextArea 12 chars in com\.apple\.TextEdit/);
});
