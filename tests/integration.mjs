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
  const settle=()=>new Promise(r=>setTimeout(r,250));
  const state=async()=>JSON.parse(await readFile(output,'utf8'));
  const action=await app.setValue(input.id,'OPENCOMPUTER');
  check(!action.focusChanged,'setting value leaves foreground unchanged');
  // The snapshot stays valid across actions, so a multi-step task needs one observe.
  check((await app.typeText(input.id,'-INTEGRATION')).delivery==='AXValue','text is inserted at the caret without key events');
  const key=await app.pressKey('Return',{element:input.id});
  check(key.delivery==='keys'&&!key.focusChanged,'Return is delivered to the background app only');
  await settle();
  check((await state()).returns===1,'the background field received the key');
  check((await app.typeText(input.id,'!',{keys:true})).delivery==='keys','typed keys reach a background field');
  await settle();
  const toggle=tree.nodes.find(x=>x.identifier==='benchmark-option');
  check(toggle.actions.includes('AXPress'),'checkbox supports AXPress');
  check(!(await app.click(toggle.id)).focusChanged,'checkbox leaves foreground unchanged');
  await assert.rejects(c.request('click',{app:'cc.opencomputer.fixture',snapshot:'not-a-snapshot',element:toggle.id}),{code:'STALE_SNAPSHOT'});checks++;
  await assert.rejects(app.performSecondaryAction(toggle.id,'AXRaise'),{code:'FOCUS_UNSAFE'});checks++;
  tree=await app.getAXState();
  check(tree.nodes.find(x=>x.identifier==='benchmark-input')?.value==='OPENCOMPUTER-INTEGRATION!','AX read-back matches value');
  let screenshot=await app.getScreenshot();
  if(screenshot.selectionRequired){const selected=screenshot.windows.find(x=>x.title==='OpenComputer Test Fixture');assert.ok(selected);screenshot=await app.getScreenshot(selected.windowId);}
  // A point picked from the screenshot is resolved to the control under it; no pointer moves.
  const frame=tree.nodes.find(x=>x.role==='AXWindow').frame,button=tree.nodes.find(x=>x.identifier==='benchmark-submit').frame;
  const point=await app.clickPoint((button.x-frame.x+button.width/2)*screenshot.scale,(button.y-frame.y+button.height/2)*screenshot.scale);
  check(point.target.role==='AXButton'&&!point.focusChanged,'screenshot point resolves to the button');
  await settle();
  const actual=await state();
  check(actual.token==='OPENCOMPUTER-INTEGRATION!'&&actual.option&&actual.submissions===1,'independent fixture state confirms result');
  check(actual.frontmostApp===before.frontmostApp,'foreground preserved at submit');
  check((await c.status()).frontmostApp===before.frontmostApp,'foreground preserved throughout');
  check(screenshot.mimeType==='image/png'&&Buffer.from(screenshot.data,'base64').subarray(1,4).toString()==='PNG','real window PNG captured');
  if(process.env.OPENCOMPUTER_TEST_IMAGE)await writeFile(process.env.OPENCOMPUTER_TEST_IMAGE,Buffer.from(screenshot.data,'base64'));
  console.log(JSON.stringify({passed:checks,fixture:actual,screenshot:{width:screenshot.width,height:screenshot.height},foregroundPreserved:true},null,2));
} finally {c.close();fixture.kill();await rm(dir,{recursive:true,force:true});}
