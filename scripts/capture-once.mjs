#!/usr/bin/env node
// Takes one screenshot of the terminal window this runs in, through the helper, and prints
// nothing on success. scripts/record-demo.sh runs it before the recording starts, so a
// screen capture question from macOS (macOS 15 and later ask before an app captures without
// the system picker) comes up and is answered before the camera rolls, not during the demo.
import {createComputer} from '../src/computer.mjs';

const host = {Apple_Terminal:'com.apple.Terminal', 'iTerm.app':'com.googlecode.iterm2'}[process.env.TERM_PROGRAM];
if (!host) { console.error('Run this from Terminal or iTerm.'); process.exit(2); }
const computer = createComputer({apps:['*'], overlay:false, agent:'Warm-up'});
try {
  // Under *, the host app is read-only, which still allows a screenshot.
  let shot = await computer.request('screenshot', {app:host});
  if (shot.selectionRequired) shot = await computer.request('screenshot', {app:host, windowId:shot.windows[0].windowId});
  if (!shot.width) throw new Error('no picture came back');
} catch (error) {
  console.error(`The warm-up screenshot failed: ${error.message}`);
  process.exitCode = 1;
} finally { computer.close(); }
