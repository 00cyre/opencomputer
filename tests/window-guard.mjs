// Live test: it brings the fixture forward, the way a person working in it would.
// An agent press in another window opens a file panel sheet there; the person's window stays in front.
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {createComputer} from '../src/computer.mjs';
const dir=await mkdtemp(join(tmpdir(),'opencomputer-window-'));
const output=join(dir,'fixture.json');
const fixture=spawn(resolve('build/OpenComputer Fixture.app/Contents/MacOS/fixture'),[],{env:{...process.env,OPENCOMPUTER_FIXTURE_OUTPUT:output,OPENCOMPUTER_FIXTURE_SECOND_WINDOW:'1',OPENCOMPUTER_FIXTURE_PANEL_TRAP:'1'},stdio:'ignore'});
const c=createComputer({apps:['cc.opencomputer.fixture'],agent:'Window test'});
const delay=ms=>new Promise(r=>setTimeout(r,ms));
const state=async()=>JSON.parse(await readFile(output,'utf8'));
try{
  for(let i=0;i<50;i++){try{await state();break;}catch{await delay(100);}}
  execFileSync('open',['-b','cc.opencomputer.fixture']);
  await delay(800);
  const app=c.getApp('cc.opencomputer.fixture');
  let tree=await app.getAXState();
  const other=tree.windows.find(w=>w.title==='Other fixture window');
  tree=await app.getAXState({window:other.index});
  const result=await app.click(tree.nodes.find(n=>n.identifier==='panel-trap').id);
  assert.equal(result.dispatched,true);
  await delay(1500);
  const s=await state();
  assert.equal(s.frontmostApp,'cc.opencomputer.fixture');
  assert.equal(s.mainWindow,'OpenComputer Test Fixture','the person keeps the window they were in');
  console.log(JSON.stringify({focusRestored:result.focusRestored,mainWindow:s.mainWindow}));
}finally{await c.release().catch(()=>{});c.close();fixture.kill();await rm(dir,{recursive:true,force:true});}
