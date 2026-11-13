// Live checks for reading features: read-only access, ID-preserving re-reads, element marks,
// zoomed capture with clickPoint, text recognition, readText, menu paths, and waitFor; and
// for settle, verify, shortcuts through the menu bar, click-only access, and release summaries.
// Needs a logged-in Mac with Accessibility and Screen Recording, and `npm run fixture:build`.
import assert from 'node:assert/strict';
import {createComputer} from '../src/computer.mjs';
import {spawn} from 'node:child_process';
import {mkdtemp,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
const dir=await mkdtemp(join(tmpdir(),'opencomputer-perception-'));
const output=join(dir,'result.json');
const fixture=spawn(resolve('build/OpenComputer Fixture.app/Contents/MacOS/fixture'),[],{env:{...process.env,OPENCOMPUTER_FIXTURE_OUTPUT:output,OPENCOMPUTER_FIXTURE_MENU:'1'},stdio:'ignore'});
const bundle='cc.opencomputer.fixture';
const reader=createComputer({apps:[`${bundle}:read`]});
const c=createComputer({apps:[bundle]});
let checks=0;
const check=(condition,message)=>{assert.ok(condition,message);checks++;};
const settle=()=>new Promise(r=>setTimeout(r,250));
const state=async()=>JSON.parse(await readFile(output,'utf8'));
try {
  let ready=false;
  for(let i=0;i<40;i++){try{await readFile(output);ready=true;break;}catch{await settle();}}
  check(ready,'fixture starts');

  // Read-only access reads but never acts.
  const looking=reader.getApp(bundle);
  const seen=await looking.getAXState();
  const field=seen.nodes.find(x=>x.identifier==='benchmark-input');
  check(field,'read-only access observes');
  await assert.rejects(looking.setValue(field.id,'nope'),e=>e.code==='READ_ONLY_APP'&&e.details.dispatched===false);checks++;
  check((await reader.status()).allowedApps.includes(`${bundle}:read`),'status lists read-only entries');
  check((await state()).token==='','nothing reached the fixture');

  // A refresh keeps ids and shows the change.
  const app=c.getApp(bundle);
  let tree=await app.getAXState();
  const input=tree.nodes.find(x=>x.identifier==='benchmark-input');
  await app.setValue(input.id,'PERCEPTION');
  const again=await app.getAXState({refresh:true});
  check(again.refreshed&&again.snapshot===tree.snapshot,'refresh keeps the snapshot');
  check(again.nodes.find(x=>x.id===input.id)?.value==='PERCEPTION','refresh reads the new value under the same id');

  // Screenshots: marks, zoom, and text recognition.
  let shot=await app.getScreenshot();
  if(shot.selectionRequired){const w=shot.windows.find(x=>x.title==='OpenComputer Test Fixture');shot=await app.getScreenshot(w.windowId);}
  const marked=await app.getScreenshot(shot.windowId,{marks:true});
  check(marked.marked>=3&&Buffer.from(marked.data,'base64').subarray(1,4).toString()==='PNG','marks drawn for the fixture controls');
  const read=await app.getScreenshot(shot.windowId,{ocr:true});
  check(read.lines.some(l=>/Background control benchmark/i.test(l.text)),'text recognized in the window');
  const frame=tree.nodes.find(x=>x.role==='AXWindow').frame,button=tree.nodes.find(x=>x.identifier==='benchmark-submit').frame;
  const s=read.scale,region={x:(button.x-frame.x-10)*s,y:(button.y-frame.y-10)*s,width:(button.width+20)*s,height:(button.height+20)*s};
  const zoomed=await app.getScreenshot(undefined,{region});
  check(zoomed.zoomed&&zoomed.width>=Math.floor(region.width),'region captured at least at the original size');
  const press=await app.clickPoint(zoomed.width/2,zoomed.height/2);
  check(press.target.role==='AXButton','a point in the zoomed picture resolves to the button');
  await settle();
  check((await state()).submissions===1,'the zoomed click submitted once');

  // waitFor sees the status text the submit produced, under ids that still work.
  const waited=await app.waitFor('Submitted PERCEPTION',{timeoutMs:5000});
  check(waited.matches.length===1,'waitFor finds the new status');

  // readText: a value, and the text inside the window.
  tree=await app.getAXState();
  const text=await app.readText(tree.nodes.find(x=>x.role==='AXWindow').id);
  check(/Background control benchmark/.test(text.text)&&text.source==='contents','readText returns the window text');
  check((await app.readText(tree.nodes.find(x=>x.identifier==='benchmark-input').id)).text==='PERCEPTION','readText returns a field value');

  // Menu shortcuts and paths.
  const menu=await app.getAXState({menu:true});
  check(menu.nodes.some(x=>x.role==='AXMenuItem'&&x.shortcut==='cmd+shift+k'),'menu item shortcut reported');
  const chosen=await app.chooseMenu('Tools > Stamp Document');
  check(chosen.menuItem==='Tools > Stamp Document…'&&!chosen.focusChanged,'menu path pressed without taking the foreground');
  await settle();
  check((await state()).stamps===1,'the menu command ran once');

  // Settle, verify, and shortcuts through the menu bar.
  const settled=await c.request('settle',{app:bundle});
  check(settled.watched===true&&typeof settled.waitedMs==='number','settle watches an observed app');
  const viaMenu=await app.pressKey('cmd+shift+k',{via:'menu'});
  check(viaMenu.menuItem==='Tools > Stamp Document…'&&viaMenu.delivery==='menu','pressKey via menu presses the item with that shortcut');
  await settle();
  check((await state()).stamps===2,'the shortcut ran the command once');
  check((await app.verify([{query:'benchmark-input',valueContains:'perception'}])).outcome==='confirmed','verify confirms the field value');
  check((await app.verify([{query:'benchmark-input',value:'nope'}])).outcome==='deviation','verify reports a deviation');

  // Click-only access presses but does not type.
  const clicker=createComputer({apps:[`${bundle}:click`]});
  try {
    const limited=clicker.getApp(bundle);
    const t=await limited.getAXState();
    await assert.rejects(limited.setValue(t.nodes.find(x=>x.identifier==='benchmark-input').id,'no'),e=>e.code==='CLICK_ONLY_APP'&&e.details.dispatched===false);checks++;
  } finally {clicker.close();}
  const released=await c.request('release');
  check(released.summary.actions>=4&&released.summary.apps.includes(bundle),'release summarizes what the session did');
  console.log(JSON.stringify({passed:checks},null,2));
} finally {reader.close();c.close();fixture.kill();await rm(dir,{recursive:true,force:true});}
