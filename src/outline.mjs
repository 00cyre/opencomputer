// How observe results read to an agent: one line per useful element, and, between two
// reads of the same snapshot, only the lines that changed.

const quiet = new Set(['AXPress','AXShowMenu','AXScrollToVisible','AXRaise','AXShowDefaultUI','AXShowAlternateUI']);
const kept = new Set(['AXWindow','AXSheet','AXWebArea','AXMenuBar','AXDrawer','AXPopover']);
const clip = (value, size) => { const text = String(value).replace(/\s+/g,' ').trim(); return text.length > size ? text.slice(0,size-1) + '…' : text; };
const hasText = value => typeof value === 'number' || (typeof value === 'string' && value.trim() !== '');

/** One element as `[id] Role "label" #identifier ="value" flags`. */
export function line(node) {
  const role = node.role.replace(/^AX/,'');
  const subrole = node.subrole && !['AXStandardWindow','AXUnknown'].includes(node.subrole) ? '/' + node.subrole.replace(/^AX/,'') : '';
  const parts = [`[${node.id}] ${role}${subrole}`];
  const label = hasText(node.title) ? node.title : node.description;
  if (hasText(label)) parts.push(JSON.stringify(clip(label,120)));
  if (hasText(node.title) && hasText(node.description) && node.description !== node.title) parts.push(`(${clip(node.description,80)})`);
  if (hasText(node.identifier)) parts.push('#' + clip(node.identifier,60));
  if (hasText(node.value) && node.value !== label) parts.push('=' + JSON.stringify(typeof node.value === 'number' ? node.value : clip(node.value,200)));
  else if (hasText(node.placeholder)) parts.push(`placeholder=${JSON.stringify(clip(node.placeholder,80))}`);
  if (node.settable) parts.push('editable');
  if (node.focused) parts.push('focused');
  if (node.selected) parts.push('selected');
  if (node.enabled === false) parts.push('disabled');
  if (node.shortcut) parts.push('keys:' + node.shortcut);
  const extra = (node.actions ?? []).filter(x => !quiet.has(x) && x.startsWith('AX')).map(x => x.slice(2));
  if (extra.length) parts.push('actions:' + extra.join(','));
  return parts.join(' ');
}

/** Elements worth a line: labelled, valued, editable, pressable, or structural. */
export const useful = node => kept.has(node.role) || node.settable || node.focused || node.selected || (node.actions ?? []).some(x => x === 'AXPress' || x === 'AXPick')
  || [node.title,node.description,node.value,node.placeholder,node.identifier].some(hasText);

/** A predicate for nodes whose role, label, identifier, or value contain every word of the query. */
export function matcher(query) {
  const words = String(query ?? '').toLowerCase().split(/\s+/).filter(Boolean);
  return node => {
    const text = [node.role,node.subrole,node.title,node.description,node.identifier,node.value,node.placeholder].filter(x => x !== undefined).join(' ').toLowerCase();
    return words.every(word => text.includes(word));
  };
}

/** Sheets and dialogs: while one is open, controls behind it usually do not respond. */
export const modal = node => node.role === 'AXSheet' || (node.role === 'AXWindow' && ['AXDialog','AXSystemDialog'].includes(node.subrole));

function header(result) {
  const nodes = result.nodes ?? [];
  const head = [`app ${result.app} pid ${result.pid} snapshot ${result.snapshot}`,
    `${nodes.length} elements in ${result.elapsedMs ?? '?'} ms; frontmost app: ${result.frontmostApp}`];
  if (result.windows?.length) head.push('windows: ' + result.windows.map(w => `[${w.index}] ${JSON.stringify(clip(w.title,60))}${w.main ? ' main' : ''}${w.minimized ? ' minimized' : ''}`).join('  '));
  const dialogs = nodes.filter(modal);
  if (dialogs.length) head.push(`open dialog: ${dialogs.slice(0,3).map(line).join('; ')}. Answer it first: controls behind it usually do not respond.`);
  if (result.webAccessibilityEnabled) head.push('Web accessibility was just switched on for this app; observe again if page content is missing.');
  if (result.truncated) head.push('Truncated: narrow with window, root, or query, or raise limit.');
  return head;
}
const cut = (text, maxChars) => text.length > maxChars ? text.slice(0,maxChars) + '\n… outline cut at ' + maxChars + ' characters: narrow with window, root, or query.' : text;

/** Render an observe result as the compact outline agents read. */
export function outline(result, {query, maxChars = 80000} = {}) {
  const nodes = result.nodes ?? [];
  const head = header(result);
  const body = [];
  if (query !== undefined) {
    const matches = nodes.filter(matcher(query));
    head.push(`${matches.length} of ${nodes.length} elements match ${JSON.stringify(query)}${matches.length > 150 ? '; first 150 shown' : ''}`);
    for (const node of matches.slice(0,150)) body.push(line(node));
  } else {
    // Unlabelled containers are dropped and their children move up a level.
    const indent = new Map();
    for (const node of nodes) {
      const base = node.parent === undefined ? 0 : indent.get(node.parent) ?? 0;
      const show = useful(node);
      indent.set(node.id, show ? base + 1 : base);
      if (show) body.push('  '.repeat(Math.min(base,12)) + line(node));
    }
  }
  return cut([...head,'',...body].join('\n'), maxChars);
}

/** The lines of a read, by element id, for comparing with a later read of the same snapshot. */
export function lines(result) {
  const map = new Map();
  for (const node of result.nodes ?? []) if (useful(node)) map.set(node.id, line(node));
  return map;
}

// "[12] Button "Send" editable" -> "Button "Send" editable", to show what an element was.
const body = text => text.replace(/^\[\d+\]\s*/,'');

const kinds = counts => Object.entries(counts ?? {}).sort((a, b) => b[1] - a[1]).slice(0,5).map(([name, n]) => `${name.replace(/Notification$/,'')} ${n}`).join(', ');

/**
 * What changed between two reads of one snapshot: elements that appeared (+), went away
 * (-), or read differently (~, with what they were). Ids are shared by both reads.
 * `settled` is the helper's settle result for the wait before the second read: with it, a
 * read that shows nothing new says whether the app reported changes the outline cannot
 * show, or none at all (`quietHint` is added then).
 */
export function changes(before, result, {query, maxLines = 300, maxChars = 40000, settled, quietHint} = {}) {
  const after = lines(result);
  const keep = query === undefined ? () => true : (() => { const match = matcher(query); const byId = new Map((result.nodes ?? []).map(n => [n.id, n])); return id => byId.has(id) && match(byId.get(id)); })();
  const out = [];
  let added = 0, changed = 0, removed = 0;
  for (const [id, text] of after) {
    const was = before.get(id);
    if (was === text || !keep(id)) continue;
    if (was === undefined) { added++; out.push('+ ' + text); }
    else { changed++; out.push('~ ' + text, '    was: ' + body(was)); }
  }
  // A read that stopped early did not see everything, so absence proves nothing.
  if (!result.truncated) for (const [id, text] of before) if (!after.has(id) && query === undefined) { removed++; out.push('- ' + text); }
  const head = header(result);
  head[0] += ' (re-read; earlier ids still apply)';
  const total = added + changed + removed;
  head.push(total ? `changes since the last read: ${added} added, ${changed} changed, ${removed} removed${query === undefined ? '' : ` among elements matching ${JSON.stringify(query)}`}` : 'No changes since the last read.');
  if (settled?.watched) {
    head.push(`${settled.settled === false ? 'still changing after' : 'settled after'} ${settled.waitedMs} ms; the app sent ${settled.notifications} accessibility notification${settled.notifications === 1 ? '' : 's'}${settled.notifications ? ` (${kinds(settled.kinds)})` : ''}`);
    if (!total && settled.notifications === 0) head.push('The app reported no change either, so this most likely had no effect.' + (quietHint ? ' ' + quietHint : ''));
    else if (!total) head.push('The app reported changes this outline does not show: they may be in another window, a menu, or past the read limit.');
  }
  const focused = (result.nodes ?? []).find(node => node.focused);
  if (focused) head.push('focused: ' + line(focused));
  if (result.truncated) head.push('Elements this read did not reach are not reported as removed.');
  let shown = out;
  if (out.length > maxLines) shown = [...out.slice(0,maxLines), `… ${out.length - maxLines} more lines: observe without changes for the full outline.`];
  return cut([...head, ...(shown.length ? ['', ...shown] : [])].join('\n'), maxChars);
}
