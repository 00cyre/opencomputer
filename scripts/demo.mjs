#!/usr/bin/env node
// A narrated tour of the 0.5 features on the test fixture, paced for a screen recording.
// It drives the fixture through the MCP server exactly as an agent would and prints what
// the agent gets back. Needs a logged-in Mac with Accessibility and Screen Recording for
// the terminal, and `npm run build && npm run fixture:build`. Run it from Terminal or
// iTerm, so the guard for the agent's own app has a host app to protect.
// DEMO_PACE_MS sets the pause after each call (default 1800).
import {spawn, spawnSync} from 'node:child_process';
import {mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {createComputer} from '../src/computer.mjs';
import {handle} from '../src/protocol.mjs';
import {outline} from '../src/outline.mjs';

const pace = Number(process.env.DEMO_PACE_MS ?? 1800);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const bold = s => `\x1b[1m${s}\x1b[0m`, dim = s => `\x1b[2m${s}\x1b[0m`, cyan = s => `\x1b[36m${s}\x1b[0m`, green = s => `\x1b[32m${s}\x1b[0m`;
const bundle = 'cc.opencomputer.fixture';
let id = 0;

async function call(computer, name, args) {
  const response = await handle({jsonrpc:'2.0', id:++id, method:'tools/call', params:{name, arguments:args}}, computer);
  if (response.error) throw new Error(`${name}: ${response.error.message}`);
  const texts = response.result.content.filter(c => c.type === 'text').map(c => c.text);
  let json; try { json = JSON.parse(texts[0]); } catch {}
  return {texts, json, isError:response.result.isError === true, images:response.result.content.filter(c => c.type === 'image').length};
}
// Show one tool call and what came back, as the agent sees it.
async function tool(computer, name, args, {show = 14, shown = args} = {}) {
  console.log(cyan(`→ ${name} ${JSON.stringify(shown)}`));
  const result = await call(computer, name, args);
  const lines = result.texts.join('\n').split('\n');
  console.log(lines.slice(0, show).join('\n') + (lines.length > show ? dim(`\n… ${lines.length - show} more lines`) : ''));
  if (result.images) console.log(dim(`[${result.images} image block returned]`));
  await sleep(pace);
  return result;
}
async function step(title, note) {
  console.log('\n' + bold(title));
  if (note) console.log(dim(note));
  await sleep(pace / 2);
}

const dir = await mkdtemp(join(tmpdir(), 'opencomputer-demo-'));
const output = join(dir, 'fixture.json');
const fixture = spawn(resolve('build/OpenComputer Fixture.app/Contents/MacOS/fixture'), [], {
  env:{...process.env, OPENCOMPUTER_FIXTURE_OUTPUT:output, OPENCOMPUTER_FIXTURE_MENU:'1', OPENCOMPUTER_FIXTURE_TOP_RIGHT:'1'}, stdio:'ignore'});
const computers = [];
const open = apps => { const c = createComputer({apps, agent:'Demo'}); computers.push(c); return c; };
try {
  for (let i = 0; i < 40; i++) { try { await readFile(output); break; } catch { await sleep(250); } }
  // Hand the foreground back to the terminal: everything after this happens in the background.
  const front = {Apple_Terminal:'Terminal', 'iTerm.app':'iTerm'}[process.env.TERM_PROGRAM];
  if (front) spawnSync('osascript', ['-e', `tell application "${front}" to activate`]);
  await sleep(800);
  const agent = open([bundle]);

  console.log(bold('OpenComputer 0.5: an agent works in a background app while you keep the keyboard and pointer.'));
  await step('1. Look', 'observe returns a compact outline with element ids.');
  console.log(cyan(`→ observe {"app":"${bundle}"}`));
  const tree = (await call(agent, 'observe', {app:bundle, format:'json'})).json;
  console.log(outline(tree).split('\n').slice(0, 14).join('\n'));
  await sleep(pace);
  const find = key => tree.nodes.find(n => n.identifier === key)?.id;
  const target = element => ({app:bundle, snapshot:tree.snapshot, element});

  await step('2. Act, and see only what changed', 'The server waits for the app\'s own accessibility notifications to settle, then diffs. Ids stay valid.');
  await tool(agent, 'setValue', {...target(find('benchmark-input')), value:'Hello from OpenComputer 0.5'});

  await step('3. Say what should happen', 'expect checks the result after the action: confirmed, deviation, or unverifiable.');
  await tool(agent, 'click', {...target(find('benchmark-submit')), expect:[{query:'Submitted: Hello'}], expectMs:3000});

  await step('4. Shortcuts in a background app', 'Sent as keys first; then via "menu", which presses the menu item that owns the shortcut.');
  await tool(agent, 'pressKey', {app:bundle, key:'cmd+shift+k'});
  await tool(agent, 'pressKey', {app:bundle, key:'cmd+shift+k', via:'menu'});

  await step('5. verify catches what did not happen', 'A read-only check; nothing is sent to the app.');
  await tool(agent, 'verify', {app:bundle, expect:[{query:'benchmark-input', valueContains:'OpenComputer'}, {query:'benchmark-input', value:'something else'}]});

  await step('6. See what the outline cannot', 'Element ids drawn on the picture, and on-device text recognition.');
  await tool(agent, 'screenshot', {app:bundle, marks:true, ocr:true, image:false, maxEdge:1200}, {show:10});
  const marked = await agent.request('screenshot', {app:bundle, marks:true});
  const picture = join(tmpdir(), 'opencomputer-demo-marks.png');
  if (marked.data) { await writeFile(picture, Buffer.from(marked.data, 'base64')); console.log(green(`marked screenshot saved to ${picture}`)); }

  await step('7. Errors say what to do next', 'retrySafe: nothing reached the app. next: the call most likely to help.');
  await tool(agent, 'click', {app:bundle, snapshot:'an-old-snapshot', element:1}, {show:4});

  await step('8. Access levels', 'bundle:click allows clicks and scrolling but no typing.');
  const clicker = open([`${bundle}:click`]);
  const limited = (await call(clicker, 'observe', {app:bundle, format:'json'})).json;
  const field = limited.nodes.find(n => n.identifier === 'benchmark-input')?.id;
  await tool(clicker, 'setValue', {app:bundle, snapshot:limited.snapshot, element:field, value:'typed'}, {show:4});

  await step('9. The agent cannot drive its own app', 'Under *, the terminal or chat app running the agent is read-only.');
  const everything = open(['*']);
  const status = (await call(everything, 'status', {})).json;
  console.log(cyan('→ status {}'));
  console.log(`protectedHosts: ${JSON.stringify(status.protectedHosts)}`);
  await sleep(pace);
  if (status.protectedHosts?.length) {
    // "shift" alone is not a key, so even without the guard nothing could be sent.
    await tool(everything, 'pressKey', {app:status.protectedHosts[0], key:'shift'}, {show:4});
  } else console.log(dim('No host app found above this process (run the demo from Terminal or iTerm to see the guard).'));

  await step('10. Wrap up', 'release summarizes the session; the action log is hash-chained and checkable.');
  await tool(agent, 'release', {});
  for (const args of [['log', '5', '--summary'], ['log', '--verify']]) {
    console.log(cyan(`$ opencomputer ${args.join(' ')}`));
    const run = spawnSync(process.execPath, ['bin/opencomputer.mjs', ...args], {encoding:'utf8'});
    console.log((run.stdout + run.stderr).trim().split('\n').slice(-6).join('\n'));
    await sleep(pace);
  }
  const state = JSON.parse(await readFile(output, 'utf8'));
  console.log('\n' + green(`Fixture state: token "${state.token}", ${state.submissions} submission, ${state.stamps} stamps. The terminal kept the foreground: ${state.frontmostApp}.`));
} finally {
  for (const c of computers) c.close();
  fixture.kill();
  await rm(dir, {recursive:true, force:true});
}
