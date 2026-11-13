// Multi-step operations built from the helper's own methods, shared by the MCP server and
// the JavaScript API: re-reading an app into the same snapshot, waiting for elements,
// checking expectations, and choosing a menu command by its path or its shortcut.
import {ComputerError} from './errors.mjs';
import {line, lines, matcher} from './outline.mjs';

const scopeKeys = ['window','windowTitle','limit','budgetMs'];
const pick = (object, keys) => Object.fromEntries(keys.filter(key => object[key] !== undefined).map(key => [key, object[key]]));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

/** The last full or window read of each app on one connection, keyed by the app as requested. */
export class Views {
  #views = new Map();
  get(app) { return this.#views.get(app); }
  remember(app, result, scope) { this.#views.set(app, {snapshot:result.snapshot, pid:result.pid, scope, lines:lines(result)}); }
  forget(app) { if (app === undefined) this.#views.clear(); else this.#views.delete(app); }
}
const owners = new WeakMap();
/** The views of one connection (a Computer, or whatever object the server was given). */
export function viewsOf(owner) {
  let views = owners.get(owner);
  if (!views) owners.set(owner, views = new Views());
  return views;
}

/**
 * Observe an app. With `refresh`, re-read the scope of its last full or window read into the
 * same snapshot, so ids stay the same, and also return that read's lines as `before`. Falls
 * back to a fresh observe when there is no earlier read or its snapshot is gone, unless
 * `fallback` is false; then it resolves with no result.
 */
export async function read(request, views, args, {refresh = false, fallback = true} = {}) {
  const scoped = args.root === undefined && !args.menu;
  const view = views.get(args.app);
  if (refresh && scoped && view && (args.pid === undefined || args.pid === view.pid)) {
    const given = pick(args, scopeKeys);
    const scope = Object.keys(given).length ? given : view.scope;
    try {
      const result = await request('observe', {app:args.app, ...scope, refresh:true, snapshot:view.snapshot});
      views.remember(args.app, result, scope);
      return {result, before:view.lines};
    } catch (error) { if (error?.code !== 'STALE_SNAPSHOT') throw error; }
  }
  // Without fallback, a refresh that cannot keep the ids does not read at all.
  if (refresh && !fallback) return {};
  const result = await request('observe', args);
  if (scoped && Array.isArray(result?.nodes)) views.remember(args.app, result, pick(args, scopeKeys));
  return {result};
}

/**
 * Re-read an app about three times a second until an element matches `query` (or, with
 * `gone`, until none does). Resolves with the last read and its matches; rejects with
 * WAIT_TIMEOUT after `timeoutMs` (default 10000, at most 60000).
 */
export async function waitFor(request, views, {query, gone = false, timeoutMs = 10000, ...scope}, {wait = sleep, now = Date.now} = {}) {
  if (typeof query !== 'string' || !query.trim()) throw new ComputerError('INVALID_ARGUMENT', 'query must name what to wait for, such as "Button Send" or "Sheet Save".');
  const limit = Math.min(Math.max(Number(timeoutMs) || 0, 0), 60000);
  const started = now();
  const match = matcher(query);
  let reads = 0, last;
  for (;;) {
    const {result} = await read(request, views, scope, {refresh:true});
    reads++;
    const matches = (result.nodes ?? []).filter(match);
    last = {result, matches};
    // A read that stopped early cannot show that something is gone.
    const met = gone ? matches.length === 0 && !result.truncated : matches.length > 0;
    const waitedMs = now() - started;
    if (met) return {...last, reads, waitedMs};
    if (waitedMs >= limit) {
      const hint = gone && result.truncated ? ' Reads were truncated, so absence could not be confirmed: narrow with window or windowTitle.' : ' Observe to see what the app shows now.';
      throw new ComputerError('WAIT_TIMEOUT', `${gone ? 'Elements matching' : 'No element matching'} ${JSON.stringify(query)} ${gone ? 'were still there' : 'appeared'} after ${waitedMs} ms (${reads} reads).${hint}`,
        {query, gone, reads, waitedMs, matches:matches.length, snapshot:result.snapshot});
    }
    await wait(Math.min(350, limit - waitedMs));
  }
}

const plain = text => String(text ?? '').toLowerCase().replace(/(\.\.\.|…)\s*$/,'').replace(/\s+/g,' ').trim();
const titles = nodes => nodes.map(node => node.title).filter(title => typeof title === 'string' && title.trim()).slice(0,60);

/** The menu item a path such as "File > Export as PDF…" names, among the nodes of a menu read. */
export function findMenuItem(nodes, path) {
  const steps = (Array.isArray(path) ? path : String(path ?? '').split('>')).map(plain).filter(Boolean);
  if (steps.length < 2) throw new ComputerError('INVALID_ARGUMENT', 'path names a menu and an item in it, such as "File > Save".');
  const children = new Map();
  for (const node of nodes) if (node.parent !== undefined) { if (!children.has(node.parent)) children.set(node.parent, []); children.get(node.parent).push(node); }
  const kids = node => children.get(node.id) ?? [];
  const items = node => kids(node).filter(n => n.role === 'AXMenu').flatMap(menu => kids(menu).filter(n => n.role === 'AXMenuItem'));
  let level = nodes.filter(node => node.role === 'AXMenuBarItem');
  const trail = [];
  let found;
  for (const [i, step] of steps.entries()) {
    found = level.find(node => plain(node.title) === step) ?? level.find(node => plain(node.title).startsWith(step));
    if (!found) throw new ComputerError('MENU_ITEM_NOT_FOUND', `No menu item ${JSON.stringify(step)} in ${trail.length ? trail.join(' > ') : 'the menu bar'}.`, {available:titles(level), dispatched:false});
    trail.push(found.title);
    if (i < steps.length - 1) level = items(found);
  }
  if (items(found).length) throw new ComputerError('INVALID_ARGUMENT', `${trail.join(' > ')} opens a submenu; add one of its items to the path.`, {available:titles(items(found)), dispatched:false});
  if (found.enabled === false) throw new ComputerError('MENU_ITEM_DISABLED', `${trail.join(' > ')} is disabled right now.`, {dispatched:false});
  return {node:found, trail};
}

/** Read the app's menu bar and press the item `path` names, without opening the menu. */
export async function chooseMenu(request, {path, waitMs, ...scope}) {
  const menu = await request('observe', {...scope, menu:true, limit:5000});
  const {node, trail} = findMenuItem(menu.nodes ?? [], path);
  const result = await request('click', {app:scope.app, ...(scope.pid === undefined ? {} : {pid:scope.pid}), snapshot:menu.snapshot, element:node.id, ...(waitMs === undefined ? {} : {waitMs})});
  return {...result, menuItem:trail.join(' > '), element:node.id, snapshot:menu.snapshot, ...(node.shortcut ? {shortcut:node.shortcut} : {})};
}

const lower = value => String(value ?? '').toLowerCase();
const holds = (node, key, want) => {
  if (key === 'value') return String(node.value ?? '') === want;
  if (key === 'valueContains') return lower(node.value).includes(lower(want));
  if (key === 'enabled') return (node.enabled !== false) === want;
  return Boolean(node[key]) === want;
};
const properties = ['value','valueContains','enabled','selected','focused'];

/**
 * Check expectations against a read. A condition names elements by `element` id and/or
 * `query` words, with optional `value`, `valueContains`, `enabled`, `selected`, and
 * `focused`; or names a window by `windowTitle` words alone. `exists: false` turns it into
 * "nothing like this is there". The outcome is `confirmed` when every condition holds,
 * `deviation` when one does not, and `unverifiable` when the read was cut short and absence
 * could not be proved.
 */
export function check(result, expect) {
  const nodes = result.nodes ?? [];
  const byId = new Map(nodes.map(node => [node.id, node]));
  const results = expect.map(condition => {
    const {query, element, windowTitle, exists = true} = condition;
    if (query === undefined && element === undefined) {
      if (windowTitle === undefined) throw new ComputerError('INVALID_ARGUMENT', 'Each expectation needs element, query, or windowTitle.');
      const found = (result.windows ?? []).filter(w => lower(w.title).includes(lower(windowTitle))).map(w => `window ${JSON.stringify(w.title ?? '')}`);
      return {condition, met:exists ? found.length > 0 : found.length === 0, found};
    }
    let found = element === undefined ? nodes : byId.has(element) ? [byId.get(element)] : [];
    if (query !== undefined) found = found.filter(matcher(query));
    const wanted = properties.filter(key => condition[key] !== undefined);
    const fitting = found.filter(node => wanted.every(key => holds(node, key, condition[key])));
    const shown = (fitting.length ? fitting : found).slice(0,3).map(line);
    if (exists) return {condition, met:fitting.length > 0, found:shown};
    // Absence is only proved by a read that reached everything.
    return {condition, met:fitting.length === 0, found:shown, ...(fitting.length === 0 && result.truncated ? {unverifiable:true} : {})};
  });
  const outcome = results.some(r => !r.met) ? 'deviation' : results.some(r => r.unverifiable) ? 'unverifiable' : 'confirmed';
  return {outcome, results};
}

/** check() as lines an agent reads: the outcome, then each expectation and what was found. */
export function report({outcome, results}) {
  const held = results.filter(r => r.met).length;
  const head = {confirmed:`Expectations met: ${held} of ${results.length}.`, deviation:`Expectations NOT met: ${held} of ${results.length} hold.`,
    unverifiable:`Expectations unverifiable: the read was cut short, so absence could not be confirmed. Narrow with window or windowTitle.`}[outcome];
  return [`outcome: ${outcome}. ${head}`, ...results.map(r => `${r.met ? (r.unverifiable ? '?' : 'ok') : 'NOT MET'} ${JSON.stringify(r.condition)}${r.found.length ? ': found ' + r.found.join('; ') : ': nothing matches'}`)].join('\n');
}

/**
 * Re-read the app until every expectation holds or `timeoutMs` passes (default 0: one
 * read). Resolves with the last read, the read before the first one (for a diff), and the
 * check.
 */
export async function expectations(request, views, scope, expect, {timeoutMs = 0, wait = sleep, now = Date.now} = {}) {
  const started = now();
  let first, last, verdict;
  for (;;) {
    last = await read(request, views, scope, {refresh:true});
    first ??= last;
    verdict = check(last.result, expect);
    if (verdict.outcome === 'confirmed' || now() - started >= timeoutMs) break;
    await wait(Math.min(300, Math.max(0, timeoutMs - (now() - started))));
  }
  return {result:last.result, before:first.before, verdict};
}

const aliases = {command:'cmd', meta:'cmd', control:'ctrl', option:'alt', opt:'alt', enter:'return', esc:'escape', backspace:'delete'};
/** A shortcut in one spelling, so "Cmd+Shift+K" and the menu's "shift+cmd+k" compare equal. */
export function shortcutKey(key) {
  const parts = lower(key).split('+').map(part => part.trim()).filter(Boolean).map(part => aliases[part] ?? part);
  const name = parts.pop() ?? '';
  const order = ['ctrl','alt','shift','cmd'];
  return [...order.filter(mod => parts.includes(mod)), name].join('+');
}

/**
 * Press the menu bar item whose shortcut is `key`, instead of sending the keys: apps act on
 * menu shortcuts reliably only while they are in front, but a menu item can be pressed in
 * the background. The menu read adds to the current snapshot, so earlier ids stay valid.
 */
export async function pressByMenu(request, {key, count, waitMs, ...scope}) {
  if (count !== undefined && count !== 1) throw new ComputerError('INVALID_ARGUMENT', 'via "menu" presses the command once; leave out count.');
  const menu = await request('observe', {app:scope.app, ...(scope.pid === undefined ? {} : {pid:scope.pid}), menu:true, limit:5000});
  const nodes = menu.nodes ?? [];
  const wanted = shortcutKey(key);
  const items = nodes.filter(node => node.role === 'AXMenuItem' && node.shortcut && shortcutKey(node.shortcut) === wanted);
  if (!items.length) throw new ComputerError('MENU_ITEM_NOT_FOUND', `No menu item has the shortcut ${key}. Leave out via to send it as keys, or choose a command with menu.`, {dispatched:false});
  const item = items.find(node => node.enabled !== false);
  const byId = new Map(nodes.map(node => [node.id, node]));
  const path = node => { const trail = []; for (let at = node; at; at = byId.get(at.parent)) if (['AXMenuItem','AXMenuBarItem'].includes(at.role) && at.title) trail.unshift(at.title); return trail.join(' > '); };
  if (!item) throw new ComputerError('MENU_ITEM_DISABLED', `${path(items[0])} (${key}) is disabled right now.`, {dispatched:false});
  const result = await request('click', {app:scope.app, ...(scope.pid === undefined ? {} : {pid:scope.pid}), snapshot:menu.snapshot, element:item.id, ...(waitMs === undefined ? {} : {waitMs})});
  return {...result, delivery:'menu', menuItem:path(item), shortcut:item.shortcut};
}
