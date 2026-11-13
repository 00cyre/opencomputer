import {createHash} from 'node:crypto';
import {readdir, readFile} from 'node:fs/promises';
import {homedir} from 'node:os';
import {join} from 'node:path';

/** Where helpers write their action logs: one `session-*.jsonl` file per helper process. */
export const logDir = () => process.env.OPENCOMPUTER_LOG_DIR || join(homedir(), 'Library', 'Logs', 'OpenComputer');

/** Entries from every session log, oldest first. Each carries its session file and agent. */
export async function readLog({dir = logDir(), since, until, app} = {}) {
  let names;
  try { names = await readdir(dir); } catch (error) { if (error.code === 'ENOENT') return []; throw error; }
  const entries = [];
  for (const name of names.filter(n => /^session-.*\.jsonl$/.test(n))) {
    let header;
    for (const line of (await readFile(join(dir, name), 'utf8')).split('\n')) {
      if (!line.trim()) continue;
      let entry;
      try { entry = JSON.parse(line); } catch { continue; }
      if (entry.event === 'session') header = entry;
      if (entry.event === 'configure' && entry.agent && header) header = {...header, agent: entry.agent};
      const time = Date.parse(entry.time);
      if (Number.isNaN(time) || (since !== undefined && time < since) || (until !== undefined && time > until)) continue;
      if (app !== undefined && entry.app !== app) continue;
      entries.push({...entry, session: name, agent: entry.agent ?? header?.agent, helperPid: header?.helperPid});
    }
  }
  return entries.sort((a, b) => Date.parse(a.time) - Date.parse(b.time));
}

const pad = (n, size = 2) => String(n).padStart(size, '0');
const clock = time => { const d = new Date(time); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${pad(d.getMilliseconds(), 3)}`; };
const name = target => target ? `${(target.role ?? '').replace(/^AX/, '')}${target.label ? ` "${target.label}"` : ''}` : '';

/** One line per entry in local time: who, what, where, and how it ended. */
export function formatEntry(e) {
  const who = `[${e.agent ?? 'Agent'} ${e.helperPid ?? '?'}]`;
  if (e.event === 'session') return `${clock(e.time)} ${who} session started (OpenComputer ${e.version}; apps ${(e.apps ?? []).join(', ') || 'none'})`;
  const parts = [clock(e.time), who, e.event];
  if (e.target) parts.push(name(e.target));
  if (e.pressed) parts.push(`(pressed ${name(e.pressed)})`);
  if (e.key) parts.push(e.key);
  if (e.textLength !== undefined) parts.push(`${e.textLength} chars`);
  if (e.valueLength !== undefined) parts.push(`${e.valueLength} chars`);
  if (e.url) parts.push(e.url);
  if (e.app && !['release', 'configure'].includes(e.event)) parts.push(`in ${e.app}`);
  if (e.window) parts.push(`window "${e.window}"`);
  if (e.tab) parts.push(`tab "${e.tab}"`);
  if (e.page) parts.push(e.page);
  if (e.event === 'observe' && e.windows) parts.push(`windows ${e.windows.map(w => `"${w}"`).join(', ')}`);
  const end = e.error ? `${e.outcome ?? 'error'} ${e.error.code}${e.error.details?.reason ? ` (${e.error.details.reason})` : ''}` : (e.outcome ?? 'ok');
  return `${parts.join(' ')} -> ${end}${e.delivery ? ` via ${e.delivery}` : ''}${e.focusRestored ? ', focus restored' : ''}`;
}

const digest = line => createHash('sha256').update(line, 'utf8').digest('hex').slice(0, 32);

/**
 * Check the chain in one session log: each line's `prev` must be the start of the SHA-256
 * of the line before it ("" on the first line). Finds a line edited or removed inside the
 * file; it cannot tell that lines were cut from the end, or that the whole chain was
 * rewritten by someone able to write the file. Logs from before 0.5 have no chain.
 */
export function verifyChain(text) {
  const rows = text.split('\n');
  if (rows.at(-1) === '') rows.pop();
  let previous = '';
  for (const [i, row] of rows.entries()) {
    let entry;
    try { entry = JSON.parse(row); } catch { return {ok:false, lines:rows.length, line:i + 1, problem:i === rows.length - 1 ? 'the last line is incomplete' : 'a line is not valid JSON'}; }
    if (entry.prev === undefined) return i === 0 ? {ok:true, chained:false, lines:rows.length} : {ok:false, lines:rows.length, line:i + 1, problem:'a line has no prev field'};
    if (entry.prev !== previous) return {ok:false, lines:rows.length, line:i + 1, problem:i === 0 ? 'the first line does not start the chain' : 'the line before it was changed or removed'};
    previous = digest(row);
  }
  return {ok:true, chained:rows.length > 0, lines:rows.length};
}

/** verifyChain for every session log in `dir`, by file name. */
export async function verifyLogs({dir = logDir()} = {}) {
  let names;
  try { names = await readdir(dir); } catch (error) { if (error.code === 'ENOENT') return []; throw error; }
  const out = [];
  for (const name of names.filter(n => /^session-.*\.jsonl$/.test(n)).sort()) out.push({session:name, ...verifyChain(await readFile(join(dir, name), 'utf8'))});
  return out;
}

const acted = new Set(['click','clickPoint','setValue','performAction','pressKey','typeText','scroll','open']);
/** Per session: who, when, how many actions were sent, refused, and failed, and in which apps. */
export function summarize(entries) {
  const sessions = new Map();
  for (const e of entries) {
    if (!sessions.has(e.session)) sessions.set(e.session, {session:e.session, agent:e.agent, helperPid:e.helperPid, first:e.time, last:e.time, actions:0, refused:0, failed:0, reads:0, apps:new Set()});
    const s = sessions.get(e.session);
    s.last = e.time; s.agent = e.agent ?? s.agent;
    if (acted.has(e.event)) {
      if (e.outcome === 'dispatched' || (e.event === 'open' && e.outcome === 'ok')) { s.actions++; if (e.app) s.apps.add(e.app); }
      else if (e.outcome === 'refused') s.refused++;
      else if (e.outcome === 'failed') s.failed++;
    } else if (['observe','screenshot','readText'].includes(e.event)) s.reads++;
  }
  return [...sessions.values()].map(s => ({...s, apps:[...s.apps].sort()}));
}
/** One line per summarized session. */
export const formatSummary = s => `${clock(s.first)} to ${clock(s.last).slice(11)} [${s.agent ?? 'Agent'} ${s.helperPid ?? '?'}] ${s.actions} action${s.actions === 1 ? '' : 's'}, ${s.refused} refused, ${s.failed} failed, ${s.reads} read${s.reads === 1 ? '' : 's'}${s.apps.length ? ' in ' + s.apps.join(', ') : ''}`;
