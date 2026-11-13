#!/usr/bin/env node
import {createInterface} from 'node:readline';
import {createComputer, ReconnectingComputer} from '../src/computer.mjs';
import {handle} from '../src/protocol.mjs';
import {readLog, formatEntry, formatSummary, logDir, summarize, verifyLogs} from '../src/log.mjs';

const command = process.argv[2] ?? 'serve';
if (['--help','-h','help'].includes(command)) {
  console.log('OpenComputer 0.5.0\n\nopencomputer serve    Local stdio MCP server\nopencomputer doctor   Check native permissions\nopencomputer apps     List running apps\nopencomputer call METHOD JSON   One request (read-only methods recommended)\nopencomputer log [MINUTES] [--app BUNDLE] [--json]   Actions of every session in the last MINUTES (default 60)\nopencomputer log [MINUTES] --summary   One line per session: actions sent, refused, failed, and apps\nopencomputer log --verify   Check that no line inside a session log was changed or removed\n\nSet OPENCOMPUTER_APPS to comma-separated exact bundle IDs, or * to explicitly enable all apps; end an entry with :read for read-only or :click for click and scroll only. No apps allowed by default.\nBuild first: npm run build. Requires macOS 14+ and Node 22+.');
  process.exit(0);
}
// Reading the action logs needs no helper and no permissions.
if (command === 'log') {
  const args = process.argv.slice(3), at = name => args.indexOf(name);
  if (args.includes('--verify')) {
    const results = await verifyLogs();
    for (const r of results) console.log(`${r.session}: ${r.ok ? (r.chained ? `ok, ${r.lines} lines` : 'not chained (written before 0.5)') : `BROKEN at line ${r.line} of ${r.lines}: ${r.problem}`}`);
    if (!results.length) console.error(`No OpenComputer session logs in ${logDir()}.`);
    process.exit(results.some(r => !r.ok) ? 1 : 0);
  }
  const minutes = Number(args.find(x => /^\d+(\.\d+)?$/.test(x)) ?? 60);
  const app = at('--app') >= 0 ? args[at('--app') + 1] : undefined;
  const entries = await readLog({since: Date.now() - minutes * 60000, app});
  if (args.includes('--summary')) for (const s of summarize(entries)) console.log(args.includes('--json') ? JSON.stringify(s) : formatSummary(s));
  else for (const entry of entries) console.log(args.includes('--json') ? JSON.stringify(entry) : formatEntry(entry));
  if (!entries.length) console.error(`No OpenComputer actions in the last ${minutes} minutes in ${logDir()}.`);
  process.exit(0);
}
const options = {agent:process.env.OPENCOMPUTER_AGENT, overlay:process.env.OPENCOMPUTER_OVERLAY !== "0", apps:(process.env.OPENCOMPUTER_APPS ?? '').split(',').map(x=>x.trim()).filter(Boolean)};
// The MCP server outlives helper timeouts and helper rebuilds; one-shot commands do not need to.
const computer = command === 'serve' ? new ReconnectingComputer(options) : createComputer(options);
for (const signal of ['SIGINT','SIGTERM']) process.on(signal, () => {computer.close(); process.exit(0);});
try {
  if (command === 'doctor' || command === 'apps') console.log(JSON.stringify(await computer.request(command === 'doctor' ? 'status' : 'apps'), null, 2));
  else if (command === 'call') console.log(JSON.stringify(await computer.request(process.argv[3], JSON.parse(process.argv[4] ?? '{}')), null, 2));
  else if (command === 'serve') {
    const lines = createInterface({input:process.stdin});
    for await (const line of lines) {
      let response;
      try {
        if (Buffer.byteLength(line) > 1_048_576) throw new Error('Too large');
        response = await handle(JSON.parse(line), computer);
      } catch { response = {jsonrpc:'2.0',id:null,error:{code:-32700,message:'Invalid or oversized JSON'}}; }
      if (response) process.stdout.write(JSON.stringify(response) + '\n');
    }
  } else throw new Error(`Unknown command: ${command}`);
} catch (e) { console.error(`${e.code ?? 'ERROR'}: ${e.message}`); process.exitCode = 1; }
finally { computer.close(); }
