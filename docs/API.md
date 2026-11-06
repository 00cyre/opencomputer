# API reference

A `Computer` instance owns a serial native helper connection. `getApp(bundleId)` creates a handle; it does not launch, activate, or inspect that app. Actions require an explicitly allowed, already-running app.

## JavaScript

| Method | Result |
| --- | --- |
| `computer.status()` | Permission booleans, allowed bundle IDs, version, foreground app. |
| `computer.getState()` | Running regular app names, bundle IDs, PIDs, allowlist status. |
| `computer.getApp(bundleId)` | App handle. |
| `app.getAXState()` | Fresh snapshot and node array. |
| `app.getScreenshot(windowId?)` | PNG data/metadata, or `selectionRequired` with candidate windows. |
| `app.click(element)` | `AXPress`. Requires the control to expose it. |
| `app.setValue(element, value)` | Replace a writable accessibility value. |
| `app.performSecondaryAction(element, action)` | Supported accessibility action. |
| `app.typeText(element, text)` | Experimental process-targeted Unicode typing. |
| `app.pressKey(element, key)` | Experimental process-targeted key or chord. |
| `app.scroll(element, direction)` | Accessibility page scroll, if the app supports it. |
| `computer.close()` | Stop helper and reject pending work. |

Create with `createComputer({apps: ['com.apple.TextEdit'], timeoutMs: 20000})`. The optional `executable` overrides the native helper path for embedding/testing. A timeout terminates the connection, preventing a late reply from being applied to a later request. **Do not blindly retry a timed-out action: inspect its outcome first.**

Each snapshot contains `snapshot`, `app`, `pid`, `nodes`, `truncated`, and `frontmostApp`. Nodes have `id`, `role`, `parent`, `depth`, available labels/values, `enabled`, `settable`, supported `actions`, and a `frame` when available. Frames use macOS global accessibility coordinates; screenshot pixels may be scaled and are not action coordinates.

Trees are bounded to 600 nodes, depth 24, and 4000 characters per string. `truncated: true` means the whole tree was not returned. There is no pagination in 0.1. The helper uses a two-second accessibility messaging timeout; the client enforces an overall request timeout.

Element IDs are valid only for the latest observation in that native connection, for the same process and bundle ID, for up to 60 seconds. An action consumes the snapshot even if dispatch fails. Observing another app invalidates the previous app's snapshot. Always inspect new state after an action.

Action responses include `dispatched`, `verificationRequired`, `frontmostBefore`, `frontmostAfter`, and `focusChanged`. These report API dispatch and foreground identity, not task success. Keyboard events can be ignored by the target app. An app may activate itself, and focus sampling does not detect every transient transition.

Supported key names: `Return`, `Tab`, `Escape`, `Backspace`, `Delete`, `Space`, `Left`, `Right`, `Up`, `Down`, `Home`, `End`, `PageUp`, `PageDown`, and `a/c/v/x/z`. Join modifiers with `+`, for example `super+a`, `shift+Tab`, or `ctrl+Left`. Modifier aliases: `super/cmd/meta`, `ctrl/control`, `shift`, `alt/option`. Unicode typing and replacement values are limited to 16000 UTF-16 units. Secure text fields are rejected.

`scroll` takes `up`, `down`, `left`, or `right`. It sends `AXScroll*ByPage` to the selected element and returns `AX_ERROR` when unsupported. It never falls back to a global scroll event. Coordinate clicking and dragging are not exposed.

## MCP

Tool names are `status`, `apps`, `observe`, `screenshot`, `click`, `setValue`, `performAction`, `typeText`, `pressKey`, and `scroll`. Clients add their own server-name prefix.

Every app operation takes `app`. Every action also takes `snapshot` and integer `element`; action-specific arguments match the JavaScript table. Use `tools/list` for the canonical schemas. Screenshots use image blocks plus text metadata; other tools use JSON encoded in text blocks. Native errors are `isError: true` tool results with `code` and `message`. Invalid JSON-RPC or schema arguments return protocol errors.

Only stdio is supported. Requests are serialized. The server supports `initialize`, `ping`, `tools/list`, `tools/call`, and ignores notifications; it advertises no resources, prompts, streaming, or cancellation. The stop control is terminating the process. A request line is limited to 1 MiB after reading; this is a local-process protocol, not a hardened parser for remote hostile streams.

## Native protocol

The helper accepts newline-delimited JSON with `method` plus arguments and returns one `result` or `error` object per line. The JavaScript client is the supported integration boundary. The helper itself checks the allowlist, macOS permissions, process identity, secure fields, snapshot ownership, and expiry.
