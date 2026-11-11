#!/usr/bin/env node
import {createInterface} from 'node:readline';
import {createComputer} from '../src/computer.mjs';
import {handle} from '../src/protocol.mjs';
import {readLog, formatEntry, logDir} from '../src/log.mjs';

const command = process.argv[2] ?? 'serve';
if (['--help','-h','help'].includes(command)) {
  console.log('OpenComputer 0.4.1\n\nopencomputer serve    Local stdio MCP server\nopencomputer doctor   Check native permissions\nopencomputer apps     List running apps\nopencomputer call METHOD JSON   One request (read-only methods recommended)\nopencomputer log [MINUTES] [--app BUNDLE] [--json]   Actions of every session in the last MINUTES (default 60)\n\nSet OPENCOMPUTER_APPS to comma-separated exact bundle IDs, or * to explicitly enable all apps. No apps allowed by default.\nBuild first: npm run build. Requires macOS 14+ and Node 22+.');
  process.exit(0);
}
// Reading the action logs needs no helper and no permissions.
if (command === 'log') {
  const args = process.argv.slice(3), at = name => args.indexOf(name);
  const minutes = Number(args.find(x => /^\d+(\.\d+)?$/.test(x)) ?? 60);
  const app = at('--app') >= 0 ? args[at('--app') + 1] : undefined;
  const entries = await readLog({since: Date.now() - minutes * 60000, app});
  for (const entry of entries) console.log(args.includes('--json') ? JSON.stringify(entry) : formatEntry(entry));
  if (!entries.length) console.error(`No OpenComputer actions in the last ${minutes} minutes in ${logDir()}.`);
  process.exit(0);
}
const computer = createComputer({agent:process.env.OPENCOMPUTER_AGENT, overlay:process.env.OPENCOMPUTER_OVERLAY !== "0", apps:(process.env.OPENCOMPUTER_APPS ?? '').split(',').map(x=>x.trim()).filter(Boolean)});
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
