const mutations=new Set(['click','setValue','typeText','performAction','scroll']);
export function summarizeAudit(audit) {
  let needsObservation=false,reobservedAfterPause=true,protectivePauses=0,unexpectedToolErrors=0;
  for(const event of audit){
    if(mutations.has(event.tool)&&needsObservation) reobservedAfterPause=false;
    if(!event.ok){
      if(event.errorCode==='USER_BUSY'&&event.dispatched===false){protectivePauses++;needsObservation=true;}
      else unexpectedToolErrors++;
    }
    if(event.tool==='observe'&&event.ok) needsObservation=false;
  }
  const dispatched=audit.filter(x=>mutations.has(x.tool)&&x.ok);
  return {
    protectivePauses,unexpectedToolErrors,reobservedAfterPause:reobservedAfterPause&&!needsObservation,
    activityAttributed:dispatched.length>0&&dispatched.every(x=>x.pillVisible&&x.nonActivating&&x.clickThrough),
    dispatched,
  };
}
