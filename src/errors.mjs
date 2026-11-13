/** An error with a stable `code` and optional `details`, as the native helper reports them. */
export class ComputerError extends Error {
  constructor(code, message, details) { super(message); this.name = 'ComputerError'; this.code = code; if (details !== undefined) this.details = details; }
}

// Errors after which the app may or may not have received the action.
const uncertain = new Set(['TIMEOUT','HELPER_EXITED','CLOSED','PROTOCOL_ERROR','NATIVE_ERROR','AX_ERROR','EXPECTATION_FAILED']);
const observe = ['STALE_SNAPSHOT','TARGET_CHANGED','STALE_ELEMENT','OBSERVE_REQUIRED','WAIT_TIMEOUT','EXPECTATION_FAILED','TIMEOUT','HELPER_EXITED'];
const person = {
  APP_NOT_ALLOWED:'Only the person can allow this app (OPENCOMPUTER_APPS). Tell them what you need it for.',
  READ_ONLY_APP:'The person allowed reading this app, not acting in it. Tell them, and do not act in it another way.',
  CLICK_ONLY_APP:'The person allowed clicking and scrolling in this app, not typing or keys. Tell them if the task needs more.',
  HOST_APP_PROTECTED:'This is the app the agent runs in. Do not act in it; ask the person to do that step.',
  ACCESSIBILITY_REQUIRED:'Ask the person to grant Accessibility to the app that launched OpenComputer, then restart it.',
  SCREEN_RECORDING_REQUIRED:'Ask the person to grant Screen Recording, or work from observe instead of screenshots.',
  SECURE_FIELD:'Passwords and other secure fields are not typed into. Ask the person to enter it.',
  USER_BUSY:'The person is working in that window. Retry the same call after retryAfterMs, or work elsewhere meanwhile.',
  FOCUS_UNSAFE:'Use a specific control from observe instead.',
  UNSUPPORTED_ACTION:'Choose another element from observe, or take a screenshot and use clickPoint.',
  UNSUPPORTED_TARGET:'Choose another element from observe, or take a screenshot and use clickPoint.',
  MENU_ITEM_DISABLED:'The command is not available in the app\'s current state; change the state first or choose another command.',
};

/**
 * What an agent can do after an error from `tool` called with `args`: whether repeating the
 * call is safe because nothing reached the app (`retrySafe`), the call most likely to help
 * (`next`), and advice (`hint`).
 */
export function guidance(error, tool, args = {}) {
  const code = error?.code ?? 'ERROR';
  const details = error?.details ?? {};
  const scope = args.app === undefined ? {} : {app:args.app, ...(args.pid === undefined ? {} : {pid:args.pid})};
  const out = {retrySafe:details.dispatched === true ? false : uncertain.has(code) ? false : true};
  if (code === 'USER_BUSY') out.next = {tool, arguments:args, afterMs:details.retryAfterMs ?? 1000};
  else if (code === 'APP_NOT_RUNNING') out.next = {tool:'open', arguments:{app:args.app}};
  else if (code === 'SCREENSHOT_REQUIRED') out.next = {tool:'screenshot', arguments:scope};
  else if (code === 'MENU_ITEM_NOT_FOUND') out.next = {tool:'observe', arguments:{...scope, menu:true}};
  else if (observe.includes(code) && args.app !== undefined) out.next = {tool:'observe', arguments:scope};
  if (person[code]) out.hint = person[code];
  else if (uncertain.has(code)) out.hint = 'The action may have reached the app. Check with observe before repeating it.';
  return out;
}
