// Multi-step operations built from the helper's own methods, shared by the MCP server and
// the JavaScript API: re-reading an app into the same snapshot, waiting for elements, and
// choosing a menu command by its path.
import {ComputerError} from './errors.mjs';
import {lines, matcher} from './outline.mjs';

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
 * back to a fresh observe when there is no earlier read or its snapshot is gone.
 */
export async function read(request, views, args, {refresh = false} = {}) {
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
