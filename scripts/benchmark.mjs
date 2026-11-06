import {spawn,spawnSync} from 'node:child_process';
import {mkdir,writeFile,readFile,symlink,rm} from 'node:fs/promises';
import {resolve,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {homedir} from 'node:os';
import {createComputer} from '../src/computer.mjs';
const root=fileURLToPath(new URL('../',import.meta.url));
const label=process.argv[2];
if(!['claude','grok'].includes(label))throw Error('Usage: node scripts/benchmark.mjs claude|grok OUTPUT_DIR');
const dir=resolve(process.argv[3]??join(root,'work',`bench-${label}`));
await mkdir(dir,{recursive:true});
const statePath=join(dir,'fixture.json'),auditPath=join(dir,'audit.jsonl');
await writeFile(auditPath,'');
await rm(statePath,{force:true});
const fixture=spawn(join(root,'build/OpenComputer Fixture.app/Contents/MacOS/fixture'),[],{env:{...process.env,OPENCOMPUTER_FIXTURE_OUTPUT:statePath},stdio:'ignore'});
const computer=createComputer({apps:['cc.opencomputer.fixture']});
const token='OPENCOMPUTER-BENCH-2026';
const prompt=`Use only the opencomputer MCP tools to complete this benchmark. The only permitted app is cc.opencomputer.fixture. Do not use shell, files, other computer tools, or subagents. 1. Check status and observe the app. 2. Set the Benchmark token field to exactly ${token}. 3. Turn on Enable test option. 4. Click Submit benchmark exactly once. 5. Observe again and verify the result. 6. Capture the fixture window screenshot; if offered multiple windows, select OpenComputer Test Fixture. Report whether the token and option are correct and whether focusChanged was ever true. Observe before and after each action; use each fresh snapshot. This is a disposable test app with no user data.`;
const config={mcpServers:{opencomputer:{command:process.execPath,args:[join(root,'tests/mcp-audit.mjs')],env:{OPENCOMPUTER_APPS:'cc.opencomputer.fixture',OPENCOMPUTER_BENCH_AUDIT:auditPath}}}};
await writeFile(join(dir,'mcp.json'),JSON.stringify(config,null,2));
await writeFile(join(dir,'prompt.txt'),prompt);
let child;
try{
  let ready=false;
  for(let i=0;i<50;i++){try{await readFile(statePath);ready=true;break;}catch{await new Promise(r=>setTimeout(r,100));}}
  if(!ready)throw Error('Fixture did not start');
  const before=await computer.status();
  let args;
  let agentEnv={...process.env};
  if(label==='claude')args=['-p',prompt,'--strict-mcp-config','--mcp-config',join(dir,'mcp.json'),'--tools','','--allowedTools','mcp__opencomputer__*','--permission-mode','dontAsk','--no-session-persistence','--output-format','json'];
  else{
    // Isolated client configuration; reuse the existing login without reading its contents.
    const grokHome=join(dir,'grok-home');
    await mkdir(grokHome,{recursive:true});
    try { await symlink(join(homedir(),'.grok/auth.json'),join(grokHome,'auth.json')); } catch(e) { if(e.code!=='EEXIST')throw e; }
    agentEnv.GROK_HOME=grokHome;
    const setup=spawnSync('grok',['mcp','add','--scope','user','opencomputer','-e','OPENCOMPUTER_APPS=cc.opencomputer.fixture','-e',`OPENCOMPUTER_BENCH_AUDIT=${auditPath}`,'--',process.execPath,join(root,'tests/mcp-audit.mjs')],{cwd:dir,env:agentEnv,encoding:'utf8'});
    if(setup.status!==0)throw Error(setup.stderr||setup.stdout);
    args=['--leader-socket',join(dir,'leader.sock'),'--cwd',dir,'-p',prompt,'--tools','','--disable-web-search','--no-subagents','--max-turns','24','--allow','opencomputer__*','--permission-mode','dontAsk','--output-format','json'];
  }
  const started=performance.now();
  console.log(`Starting ${label} benchmark with fixture-only MCP access`);
  child=spawn(label,args,{cwd:dir,env:agentEnv,stdio:['ignore','pipe','pipe']});
  let stdout='',stderr='';
  child.stdout.on('data',d=>stdout+=d);child.stderr.on('data',d=>stderr+=d);
  const timeout=setTimeout(()=>child.kill('SIGTERM'),300000);
  const code=await new Promise((resolve,reject)=>{child.on('exit',resolve);child.on('error',reject);});
  clearTimeout(timeout);
  await writeFile(join(dir,'agent-output.json'),stdout);await writeFile(join(dir,'agent-stderr.txt'),stderr);
  const actual=JSON.parse(await readFile(statePath,'utf8'));
  const audit=(await readFile(auditPath,'utf8')).trim().split('\n').filter(Boolean).map(x=>JSON.parse(x));
  const after=await computer.status();
  const result={client:label,clientVersion:spawnSync(label,['--version'],{encoding:'utf8'}).stdout.trim(),exitCode:code,elapsedSeconds:Number(((performance.now()-started)/1000).toFixed(2)),toolCalls:audit.length,toolErrors:audit.filter(x=>!x.ok).length,tokenCorrect:actual.token===token,optionCorrect:actual.option===true,submittedExactlyOnce:actual.submissions===1,foregroundPreserved:!audit.some(x=>x.focusChanged||x.targetWasForeground)&&actual.frontmostApp!=='cc.opencomputer.fixture',foregroundStableAcrossRun:actual.frontmostApp===before.frontmostApp&&after.frontmostApp===before.frontmostApp,screenshotToolSucceeded:audit.some(x=>x.tool==='screenshot'&&x.ok&&x.imageCaptured),actionFocusPreserved:!audit.some(x=>x.focusChanged),allActionsInBackground:!audit.some(x=>x.targetWasForeground),fixture:actual};
  try{const parsed=JSON.parse(stdout);result.models=Object.keys(parsed.modelUsage??{});}catch{result.models=[];}
  result.foregroundSamples={before:before.frontmostApp,atSubmit:actual.frontmostApp,after:after.frontmostApp};
  result.passed=result.actionFocusPreserved&&result.exitCode===0&&result.tokenCorrect&&result.optionCorrect&&result.submittedExactlyOnce&&result.foregroundPreserved&&result.screenshotToolSucceeded;
  await writeFile(join(dir,'result.json'),JSON.stringify(result,null,2)+'\n');
  console.log(JSON.stringify(result,null,2));
  if(!result.passed)process.exitCode=1;
}finally{child?.kill();computer.close();fixture.kill();}
