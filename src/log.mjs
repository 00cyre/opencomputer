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
