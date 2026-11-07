import test from 'node:test';
import assert from 'node:assert/strict';
import {summarizeAudit} from '../scripts/benchmark-audit.mjs';
const busy={tool:'setValue',ok:false,errorCode:'USER_BUSY',dispatched:false};
const observe={tool:'observe',ok:true};
const action={tool:'setValue',ok:true,pillVisible:true,nonActivating:true,clickThrough:true};
test('expected activity pauses require no dispatch and a fresh observation before retrying',()=>{
  const recovered=summarizeAudit([busy,observe,action]);
  assert.equal(recovered.protectivePauses,1);
  assert.equal(recovered.unexpectedToolErrors,0);
  assert.equal(recovered.reobservedAfterPause,true);
  assert.equal(recovered.activityAttributed,true);
  assert.equal(summarizeAudit([busy,action,observe]).reobservedAfterPause,false);
  assert.equal(summarizeAudit([busy]).reobservedAfterPause,false);
  assert.equal(summarizeAudit([{...busy,dispatched:undefined},observe,action]).unexpectedToolErrors,1);
  assert.equal(summarizeAudit([{...busy,errorCode:'AX_ERROR'},observe,action]).unexpectedToolErrors,1);
  assert.equal(summarizeAudit([]).activityAttributed,false);
});
