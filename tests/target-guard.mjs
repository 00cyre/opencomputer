// Live check that actions refuse a target whose window, tab, or page changed after the
// snapshot, and that every request lands in the session's action log without typed text.
// Uses only the disposable fixture; a signal to the fixture plays the person switching tabs.
import assert from 'node:assert/strict';
import {createComputer} from '../src/computer.mjs';
import {spawn} from 'node:child_process';
import {mkdtemp, readFile, readdir, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';

const dir = await mkdtemp(join(tmpdir(), 'opencomputer-guard-'));
const output = join(dir, 'result.json'), logs = join(dir, 'logs');
process.env.OPENCOMPUTER_LOG_DIR = logs;
const fixture = spawn(resolve('build/OpenComputer Fixture.app/Contents/MacOS/fixture'), [], {env: {...process.env, OPENCOMPUTER_FIXTURE_OUTPUT: output, OPENCOMPUTER_FIXTURE_TABS: '1', OPENCOMPUTER_FIXTURE_AWAY_FROM_POINTER: '1'}, stdio: 'ignore'});
const c = createComputer({apps: ['cc.opencomputer.fixture'], overlay: false, agent: 'target-guard-test'});
const sleep = ms => new Promise(r => setTimeout(r, ms));
const state = async () => JSON.parse(await readFile(output, 'utf8'));
let checks = 0;
const check = (condition, message) => { assert.ok(condition, message); checks++; };
const refused = async (promise, codes, message) => {
  await assert.rejects(promise, e => { assert.ok(codes.includes(e.code), `${message}: got ${e.code} ${e.message}`); assert.equal(e.details?.dispatched ?? false, false); return true; });
  checks++;
};
// The person's tab switch, from outside OpenComputer.
const person = async (signal, title) => {
  fixture.kill(signal);
  for (let i = 0; i < 40; i++) { const s = await state(); if (s.tab === title) return; await sleep(50); }
  throw Error('fixture did not switch to ' + title);
};
try {
  for (let i = 0; i < 40; i++) { try { await state(); break; } catch { await sleep(100); } }
  const before = (await c.status()).frontmostApp;
  const app = c.getApp('cc.opencomputer.fixture');
  const find = (tree, id) => tree.nodes.find(x => x.identifier === id);
  let tree = await app.getAXState();
  const tabs = tree.nodes.filter(x => x.subrole === 'AXTabButton');
  check(tabs.length === 2, 'tab buttons are exposed');
  check(tree.windows[0].title === 'Fixture: Alpha', 'window title follows the tab');

  // The person switches tabs after the agent observed: the old tab's control, a control of
  // the window itself, and keys to the focused window are all refused.
  await person('SIGUSR1', 'Beta');
  await refused(app.click(find(tree, 'alpha-action').id), ['TARGET_CHANGED', 'STALE_ELEMENT'], 'control in a tab the person left');
  await refused(app.setValue(find(tree, 'benchmark-input').id, 'secret-typed-value'), ['TARGET_CHANGED'], 'window control after a tab switch');
  await refused(app.pressKey('Return'), ['TARGET_CHANGED'], 'keys after a tab switch');
  check((await state()).presses['Alpha action'] === undefined && (await state()).token === '', 'nothing reached the fixture');

  // After observing again, the same kind of action goes through.
  tree = await app.getAXState();
  check((await app.click(find(tree, 'beta-action').id)).dispatched, 'fresh snapshot acts');
  await sleep(100);
  check((await state()).presses['Beta action'] === 1, 'the press reached the fixture');

  // A switch that keeps the title is caught by the selected tab.
  await person('SIGUSR2', 'Alpha');
  check((await state()).title === 'Fixture: Beta', 'title unchanged by the silent switch');
  await refused(app.setValue(find(tree, 'benchmark-input').id, 'secret-typed-value'), ['TARGET_CHANGED'], 'window control after a same-title tab switch');
  await refused(app.click(find(tree, 'beta-action').id), ['TARGET_CHANGED', 'STALE_ELEMENT'], 'control in the hidden tab');

  // The agent's own tab switch keeps the snapshot valid for the window's controls.
  tree = await app.getAXState();
  const beta = tree.nodes.find(x => x.subrole === 'AXTabButton' && x.title === 'Beta');
  check((await app.click(beta.id)).dispatched, 'agent presses a tab');
  await sleep(100);
  check((await state()).title === 'Fixture: Beta', 'the agent\'s tab press changed the title');
  check((await app.setValue(find(tree, 'benchmark-input').id, 'agent-typed-value')).dispatched, 'window control after the agent\'s own switch');
  await refused(app.click(find(tree, 'alpha-action').id), ['TARGET_CHANGED', 'STALE_ELEMENT'], 'the tab the agent left');

  // A screenshot pixel is refused once another tab shows.
  tree = await app.getAXState();
  let shot = await app.getScreenshot();
  if (shot.selectionRequired) shot = await app.getScreenshot(shot.windows[0].windowId);
  const frame = tree.nodes.find(x => x.role === 'AXWindow').frame, button = find(tree, 'beta-action').frame;
  const x = (button.x - frame.x + button.width / 2) * shot.scale, y = (button.y - frame.y + button.height / 2) * shot.scale;
  await person('SIGUSR1', 'Alpha');
  await refused(app.clickPoint(x, y), ['TARGET_CHANGED'], 'screenshot point after a tab switch');
  check((await c.status()).frontmostApp === before, 'foreground preserved');

  // The log: one line per request, targets and windows named, typed text absent.
  const status = await c.status();
  check(status.actionLog?.startsWith(logs), 'status reports the log file');
  const files = await readdir(logs);
  check(files.length === 1 && /^session-.*\.jsonl$/.test(files[0]), 'one log file per session');
  const raw = await readFile(status.actionLog, 'utf8');
  const lines = raw.trim().split('\n').map(JSON.parse);
  check(!raw.includes('secret-typed-value') && !raw.includes('agent-typed-value'), 'typed values stay out of the log');
  check(lines[0].event === 'session' && lines[0].agent === 'target-guard-test', 'session header names the agent');
  check(lines.every(l => typeof l.time === 'string' && !Number.isNaN(Date.parse(l.time))), 'every line has a timestamp');
  const refusedClick = lines.find(l => l.event === 'click' && l.outcome === 'refused');
  check(refusedClick?.target?.label === 'Alpha action' && refusedClick.window && refusedClick.error?.code, 'a refused click names its target, window, and error');
  const set = lines.find(l => l.event === 'setValue' && l.outcome === 'dispatched');
  check(set?.valueLength === 'agent-typed-value'.length && set.target?.role === 'AXTextField' && set.window === 'Fixture: Beta', 'a dispatched edit logs length, target, and window');
  check(lines.some(l => l.event === 'pressKey' && l.key === 'Return' && l.error?.code === 'TARGET_CHANGED'), 'a refused key press is logged');
  check(lines.some(l => l.event === 'clickPoint' && l.error?.details?.reason === 'window-title'), 'a refused screenshot point is logged');
  console.log(JSON.stringify({passed: checks, log: lines.length + ' lines'}, null, 2));
} finally { c.close(); fixture.kill(); if (process.env.OPENCOMPUTER_KEEP_LOG) console.log(await readFile((await readdir(logs)).map(f => join(logs, f))[0], "utf8").catch(() => "")); await rm(dir, {recursive: true, force: true}); }
