# API reference

A `Computer` instance owns a serial native helper connection. `getApp(bundleId)` creates a handle; it does not launch, activate, or inspect that app. Actions require an explicitly allowed, already-running app.

## JavaScript

| Method | Result |
| --- | --- |
| `computer.status()` | Permissions, allowed bundle IDs, version, foreground app, activity state, and `focusProtectionBlocked`. |
| `computer.getState()` | Running regular app names, bundle IDs, PIDs, allowlist status. |
| `computer.getApp(bundleId)` | App handle. |
| `app.getAXState({window?, root?}?)` | Fresh snapshot, node array, and window list. Optionally select a window or expand a subtree. |
| `app.checkInteraction(element)` | Read-only conflict check for a fresh element. Does not consume the snapshot or reserve the window. |
| `app.getScreenshot(windowId?)` | PNG data/metadata, or `selectionRequired` with candidate windows. |
| `app.click(element)` | `AXPress`. Requires the control to expose it. |
| `app.setValue(element, value)` | Replace a writable accessibility value. |
| `app.performSecondaryAction(element, action)` | `AXPress`, `AXIncrement`, `AXDecrement`, or `AXPick`, if supported. |
| `app.typeText(element, text)` | Replace the exposed selected range through `AXValue`; no key events or focus changes. |
| `app.pressKey(element, key)` | Compatibility method that rejects with `FOCUS_UNSAFE`. Removed from MCP discovery in 0.2. |
| `app.scroll(element, direction)` | Accessibility page scroll, if the app supports it. |
| `computer.release()` | Hide this session’s indicators and invalidate its snapshot. Does not reset a focus block. |
| `computer.close()` | Stop helper and reject pending work. |

```js
const computer = createComputer({
  apps: ['com.apple.TextEdit'],
  agent: 'Claude',    // optional display identity
  overlay: true,     // default: dots and ghost cursor enabled
  timeoutMs: 20000,
});
```

An explicit `agent` takes priority over MCP `initialize.clientInfo.name`; otherwise the server derives the display identity from that client name. Custom names use an initial when no known installed AI icon is available. Identity is presentation metadata, not authentication. The optional `executable` overrides the helper path for embedding/testing. A timeout terminates the connection, preventing a late reply from being applied to a later request. **Do not blindly retry a timed-out action: inspect its outcome first.**

`apps: ['*']` explicitly enables all running apps. Each request still names one bundle ID, and snapshots, window captures, and mutations remain scoped to its process. The default is still no app access. This uses the apps and logged-in sessions on the current Mac; it creates no VM and copies no credentials.

Each snapshot contains `snapshot`, `app`, `pid`, `nodes`, `truncated`, and `frontmostApp`. Nodes have `id`, `role`, `parent`, `depth`, available labels/values, `enabled`, `settable`, supported `actions`, and a `frame` when available. Frames use macOS global accessibility coordinates; screenshot pixels may be scaled and are not action coordinates.

Trees are bounded to 600 nodes, depth 24, and 4000 characters per string. `truncated: true` means the whole tree was not returned. `windows` lists the app's window indices, titles, and minimized state. Pass `{window: index}` to inspect one window, or `{root: elementId}` to expand a subtree from the previous snapshot. These options cannot be combined. MCP subtree requests also supply the previous `snapshot`; the JavaScript handle supplies it automatically. Every observation replaces the snapshot. Window indices can change, so verify the returned title before acting. These are accessibility window indices, distinct from screenshot `windowId` values. Subtree expansion is not sibling pagination: an exceptionally wide subtree can still truncate. The helper uses a two-second accessibility messaging timeout for observations; the client enforces an overall request timeout.

Element IDs belong to the latest observation in that connection, for the same process and bundle ID, for up to 60 seconds. Dispatch consumes the snapshot even if the action fails. Pre-dispatch rejections such as `USER_BUSY` do not dispatch; always re-observe before retrying. Observing another app or calling `release` invalidates previous IDs. The JavaScript app handle requires a fresh observation after every attempted action.

## Focus protection and text

Successful action responses include `dispatched`, `verificationRequired`, `frontmostBefore`, `frontmostAfter`, `focusChanged: false`, and `activity`. They report dispatch, not task success. Observe to verify outcomes.

The helper never activates the target, sets its focus, injects raw keyboard events, or restores the foreground app. Every mutation checks the current foreground window, editable focus, pointer hit-test and proximity, held mouse buttons/keys, and recent keyboard/click/scroll/movement activity immediately before dispatch. A background window of the same app can remain available while the foreground window is being edited.

| Signal | Behavior |
| --- | --- |
| Mouse button held | Wait globally; a drag can cross app boundaries. |
| Focused text editor in the target window | Keep that window reserved even during typing pauses. |
| Key or shortcut held | Wait when the target is the foreground window or under the pointer. |
| Pointer within 64 points of the target control, in its visible window | Wait until it moves away. Occlusion by another app does not count as pointer proximity. |
| Typing in the target window | Wait for 2 seconds of keyboard quiet. |
| Clicking / scrolling in or over the target window | Wait 1.2 / 1.5 seconds respectively. |
| Pointer moving over the target window | Wait for 0.8 seconds of quiet. |
| Required foreground, window, pointer, or input information unavailable | Reject the write until it can be checked. |

Conflicts return `USER_BUSY` with `details.canProceed: false`, `details.reason`, `details.retryAfterMs`, and `details.dispatched: false`. The pill turns amber and explains the wait on hover. Nothing is queued, and this does not permanently block the connection. The client should wait the suggested interval, re-observe, reconsider the action, and try again only if still appropriate. A delay is not permission to proceed. Work in unrelated windows can continue. `checkInteraction` exposes the same check without dispatch, but its answer is advisory: every mutation samples again. Native errors preserve `details` in MCP output and `ComputerError.details`.

The focus guard records foreground app/window/control and watches activation and focus notifications through dispatch and a 150 ms settling interval.

If focus changes, the action returns `FOCUS_CHANGED` and may already have executed. Further writes return `FOCUS_PROTECTION_BLOCKED`. Read-only inspection and `release` remain available; reconnect only after inspecting the outcome. The indicator shows the paused state. User-initiated switches during this interval also pause the session conservatively. Apps can activate themselves later or omit accessibility notifications, so this is detection and containment, not a universal focus lock.

Quiet input does not establish that a person has stopped reading, and a user can start interacting between the check and dispatch. Browser tabs are treated as part of their window; there is no per-tab ownership detection or browser DOM adapter. Unsupported controls remain unsupported; this guard does not enable global input as a fallback.

`typeText` needs both a readable `AXValue` and a valid `AXSelectedTextRange`. It replaces that range without moving the caret or sending keys. Unsupported controls return `FOCUS_UNSAFE`; use `setValue` to replace the full value. Text and final replacement values are limited to 16000 UTF-16 units. Secure fields are rejected. Menu-show, confirm/cancel, global key, coordinate-click, and drag actions are not exposed.

`scroll` takes `up`, `down`, `left`, or `right`. It sends `AXScroll*ByPage` to the selected element and returns `AX_ERROR` when unsupported. It never falls back to a global scroll event.

## Activity state

Observation, capture, and actions update the indicators. `status().activity` contains `enabled`, `active`, `agent`, `app`, `action`, `windowTitle`, `pillVisible`, `expanded`, `ghostVisible`, `ghostFloating`, `ghostReason`, `stackRow`, `nonActivating`, `clickThrough`, and helper window IDs/geometry for diagnostics. These are current observations, not a persistent activity log. See [activity behavior](ACTIVITY.md).

## MCP

Tool names are `status`, `apps`, `observe`, `screenshot`, `checkInteraction`, `click`, `setValue`, `performAction`, `typeText`, `scroll`, and `release`. Clients add their own server-name prefix. Call `release` when the task ends so a persistent MCP server does not keep showing the last task.

Every app operation takes `app`. Every action and interaction check also takes `snapshot` and integer `element`; action-specific arguments match the JavaScript table. Use `tools/list` for the canonical schemas. Screenshots use image blocks plus text metadata; other tools use JSON encoded in text blocks. Native errors are `isError: true` tool results with `code`, `message`, and optional `details`. Invalid JSON-RPC or schema arguments return protocol errors.

Only stdio is supported. Requests are serialized. The server supports `initialize`, `ping`, `tools/list`, `tools/call`, and ignores notifications; it advertises no resources, prompts, streaming, or cancellation. The stop control is terminating the process. A request line is limited to 1 MiB after reading; this is a local-process protocol, not a hardened parser for remote hostile streams.

## Native protocol

The helper accepts newline-delimited JSON with `method` plus arguments and returns one `result` or `error` object per line. The JavaScript client is the supported integration boundary. The helper itself checks the allowlist, macOS permissions, process identity, secure fields, snapshot ownership, and expiry. Host configuration of the display identity is not an agent-facing MCP tool.
