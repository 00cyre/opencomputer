# API reference

A `Computer` instance owns a serial native helper connection. `getApp(bundleId)` creates a handle; it does not launch, activate, or inspect that app. Actions require an explicitly allowed, already-running app.

## JavaScript

| Method | Result |
| --- | --- |
| `computer.status()` | Permissions, allowed bundle IDs, version, foreground app, activity state, and `focusProtectionBlocked`. |
| `computer.getState()` | Running regular app names, bundle IDs, PIDs, allowlist status. |
| `computer.getApp(bundleId)` | App handle. |
| `app.getAXState()` | Fresh snapshot and node array. |
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

Each snapshot contains `snapshot`, `app`, `pid`, `nodes`, `truncated`, and `frontmostApp`. Nodes have `id`, `role`, `parent`, `depth`, available labels/values, `enabled`, `settable`, supported `actions`, and a `frame` when available. Frames use macOS global accessibility coordinates; screenshot pixels may be scaled and are not action coordinates.

Trees are bounded to 600 nodes, depth 24, and 4000 characters per string. `truncated: true` means the whole tree was not returned. There is no pagination in 0.2. The helper uses a two-second accessibility messaging timeout for observations; the client enforces an overall request timeout.

Element IDs belong to the latest observation in that connection, for the same process and bundle ID, for up to 60 seconds. Dispatch consumes the snapshot even if the action fails. Pre-dispatch rejections such as `USER_BUSY` do not dispatch; always re-observe before retrying. Observing another app or calling `release` invalidates previous IDs. The JavaScript app handle requires a fresh observation after every attempted action.

## Focus protection and text

Successful action responses include `dispatched`, `verificationRequired`, `frontmostBefore`, `frontmostAfter`, `focusChanged: false`, and `activity`. They report dispatch, not task success. Observe to verify outcomes.

The helper never activates the target, sets its focus, injects raw keyboard events, or restores the foreground app. It records the foreground app/window/control and watches activation and focus notifications through dispatch and a 150 ms settling interval. Recent typing/clicking in the foreground target returns `USER_BUSY` before dispatch.

If focus changes, the action returns `FOCUS_CHANGED` and may already have executed. Further writes return `FOCUS_PROTECTION_BLOCKED`. Read-only inspection and `release` remain available; reconnect only after inspecting the outcome. The indicator shows the paused state. User-initiated switches during this interval also pause the session conservatively. Apps can activate themselves later or omit accessibility notifications, so this is detection and containment, not a universal focus lock.

`typeText` needs both a readable `AXValue` and a valid `AXSelectedTextRange`. It replaces that range without moving the caret or sending keys. Unsupported controls return `FOCUS_UNSAFE`; use `setValue` to replace the full value. Text and final replacement values are limited to 16000 UTF-16 units. Secure fields are rejected. Menu-show, confirm/cancel, global key, coordinate-click, and drag actions are not exposed.

`scroll` takes `up`, `down`, `left`, or `right`. It sends `AXScroll*ByPage` to the selected element and returns `AX_ERROR` when unsupported. It never falls back to a global scroll event.

## Activity state

Observation, capture, and actions update the indicators. `status().activity` contains `enabled`, `active`, `agent`, `app`, `action`, `pillVisible`, `expanded`, `ghostVisible`, `ghostReason`, `stackRow`, `nonActivating`, `clickThrough`, and helper window IDs/geometry for diagnostics. These are current observations, not a persistent activity log. See [activity behavior](ACTIVITY.md).

## MCP

Tool names are `status`, `apps`, `observe`, `screenshot`, `click`, `setValue`, `performAction`, `typeText`, `scroll`, and `release`. Clients add their own server-name prefix. Call `release` when the task ends so a persistent MCP server does not keep showing the last task.

Every app operation takes `app`. Every action also takes `snapshot` and integer `element`; action-specific arguments match the JavaScript table. Use `tools/list` for the canonical schemas. Screenshots use image blocks plus text metadata; other tools use JSON encoded in text blocks. Native errors are `isError: true` tool results with `code` and `message`. Invalid JSON-RPC or schema arguments return protocol errors.

Only stdio is supported. Requests are serialized. The server supports `initialize`, `ping`, `tools/list`, `tools/call`, and ignores notifications; it advertises no resources, prompts, streaming, or cancellation. The stop control is terminating the process. A request line is limited to 1 MiB after reading; this is a local-process protocol, not a hardened parser for remote hostile streams.

## Native protocol

The helper accepts newline-delimited JSON with `method` plus arguments and returns one `result` or `error` object per line. The JavaScript client is the supported integration boundary. The helper itself checks the allowlist, macOS permissions, process identity, secure fields, snapshot ownership, and expiry. Host configuration of the display identity is not an agent-facing MCP tool.
