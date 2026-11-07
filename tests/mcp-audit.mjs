// Benchmark-only proxy. Logs tool names, timings, and status; never screenshot/text payloads.
import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {appendFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
const child=spawn(process.execPath,[fileURLToPath(new URL('../bin/opencomputer.mjs',import.meta.url)),'serve'],{stdio:['pipe','pipe','inherit'],env:process.env});
const pending=new Map();
const file=process.env.OPENCOMPUTER_BENCH_AUDIT;
const log=entry=>{if(file)appendFileSync(file,JSON.stringify(entry)+'\n');};
createInterface({input:process.stdin}).on('line',line=>{
  try{const m=JSON.parse(line);if(m.method==='tools/call')pending.set(m.id,{tool:m.params.name,app:m.params.arguments?.app,start:performance.now()});}catch{}
  child.stdin.write(line+'\n');
}).on('close',()=>child.stdin.end());
createInterface({input:child.stdout}).on('line',line=>{
  try {
    const m=JSON.parse(line),p=pending.get(m.id);
    if(p){
      const content=m.result?.content??[];
      let focusChanged=false,targetWasForeground=false,activityAgent,pillVisible,nonActivating,clickThrough,released,errorCode,dispatched;
      for(const block of content){
        if(block.type==='text'){
          try {
            const state=JSON.parse(block.text);
            focusChanged ||= state.focusChanged===true||state.code==='FOCUS_CHANGED';
            if(state.activity) ({agent:activityAgent,pillVisible,nonActivating,clickThrough}=state.activity);
            if(m.result?.isError && /^[A-Z_]{1,64}$/.test(state.code??'')) errorCode=state.code;
            if(typeof state.details?.dispatched==='boolean') dispatched=state.details.dispatched;
            released ||= state.released===true;
            targetWasForeground ||= Boolean(p.app)&&(state.frontmostBefore===p.app||state.frontmostAfter===p.app);
          }catch{}
        }
      }
      log({tool:p.tool,elapsedMs:Math.round(performance.now()-p.start),ok:!m.error&&!m.result?.isError,errorCode,dispatched,imageCaptured:content.some(x=>x.type==='image'),focusChanged,targetWasForeground,activityAgent,pillVisible,nonActivating,clickThrough,released});
      pending.delete(m.id);
    }
  }catch{}
  process.stdout.write(line+'\n');
});
for(const s of ['SIGINT','SIGTERM'])process.on(s,()=>{child.kill();process.exit(0);});
child.on('exit',code=>process.exit(code??1));
