import assert from 'node:assert/strict';
import {createComputer} from '../src/computer.mjs';
import {spawn} from 'node:child_process';
import {mkdtemp,readFile,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
const dir=await mkdtemp(join(tmpdir(),'opencomputer-integration-'));
const output=join(dir,'result.json');
const fixture=spawn(resolve('build/OpenComputer Fixture.app/Contents/MacOS/fixture'),[],{env:{...process.env,OPENCOMPUTER_FIXTURE_OUTPUT:output},stdio:'ignore'});
const c=createComputer({apps:['cc.opencomputer.fixture']});
let checks=0;
const check=(condition,message)=>{assert.ok(condition,message);checks++;};
try {
  let ready=false;
  for(let i=0;i<40;i++){try{await readFile(output);ready=true;break;}catch{await new Promise(r=>setTimeout(r,100));}}
  check(ready,'fixture starts');
  const before=await c.status();
  check(before.accessibility,'Accessibility permission available');
  await assert.rejects(c.request('observe',{app:'com.apple.finder'}),{code:'APP_NOT_ALLOWED'});checks++;
  const app=c.getApp('cc.opencomputer.fixture');
  let tree=await app.getAXState();
  const input=tree.nodes.find(x=>x.identifier==='benchmark-input');
  check(input?.settable,'field is exposed and writable');
  const old=tree.snapshot;
  const action=await app.setValue(input.id,'OPENCOMPUTER-INTEGRATION');
  check(!action.focusChanged,'setting value leaves foreground unchanged');
  await assert.rejects(c.request('click',{app:'cc.opencomputer.fixture',snapshot:old,element:input.id}),{code:'STALE_SNAPSHOT'});checks++;
  tree=await app.getAXState();
  check(tree.nodes.find(x=>x.identifier==='benchmark-input')?.value==='OPENCOMPUTER-INTEGRATION','AX read-back matches value');
  const toggle=tree.nodes.find(x=>x.identifier==='benchmark-option');
  check(toggle.actions.includes('AXPress'),'checkbox supports AXPress');
  check(!(await app.click(toggle.id)).focusChanged,'checkbox leaves foreground unchanged');
  tree=await app.getAXState();
  check(!(await app.click(tree.nodes.find(x=>x.identifier==='benchmark-submit').id)).focusChanged,'submit leaves foreground unchanged');
  const actual=JSON.parse(await readFile(output,'utf8'));
  check(actual.token==='OPENCOMPUTER-INTEGRATION'&&actual.option&&actual.submissions===1,'independent fixture state confirms result');
  check(actual.frontmostApp===before.frontmostApp,'foreground preserved at submit');
  let screenshot=await app.getScreenshot();
  if(screenshot.selectionRequired){console.log('Window selection:',JSON.stringify(screenshot.windows));const selected=screenshot.windows.find(x=>x.title==='OpenComputer Test Fixture');assert.ok(selected);screenshot=await app.getScreenshot(selected.windowId);}
  check(screenshot.mimeType==='image/png'&&Buffer.from(screenshot.data,'base64').subarray(1,4).toString()==='PNG','real window PNG captured');
  if(process.env.OPENCOMPUTER_TEST_IMAGE)await writeFile(process.env.OPENCOMPUTER_TEST_IMAGE,Buffer.from(screenshot.data,'base64'));
  console.log(JSON.stringify({passed:checks,fixture:actual,screenshot:{width:screenshot.width,height:screenshot.height},foregroundPreserved:true},null,2));
} finally {c.close();fixture.kill();await rm(dir,{recursive:true,force:true});}
