# API reference

A `Computer` instance owns a serial native helper connection. `getApp(bundleId)` creates a handle. Every operation names one explicitly allowed app, and nothing the helper does moves the pointer, takes keyboard focus, or brings an app forward.

## JavaScript

| Method | Result |
| --- | --- |
| `computer.status()` | Permissions, allowed bundle IDs, version, foreground app, activity state, default `waitMs`, and `focusRestorations`. |
| `computer.getState()` | Running regular apps: name, bundle ID, PID, frontmost, hidden, allowlist status. |
| `computer.getApp(bundleId, {pid}?)` | App handle. Pass `pid` when several instances of one bundle run. |
| `app.open(url?)` | Launch the app, or open an `http`, `https`, or `file` URL in it, without activating it. |
| `app.getAXState({window?, root?, menu?, limit?}?)` | Snapshot, node array, and window list. Select a window, expand a subtree, or read the menu bar. |
| `app.getScreenshot(windowId?)` | PNG data/metadata, or `selectionRequired` with candidate windows. |
| `app.click(element)` | Press, select, or focus the element, or the control containing it. No pointer. |
| `app.clickPoint(x, y)` | The same press on the element under a pixel of the last screenshot of this app. |
| `app.setValue(element, value)` | Replace a writable accessibility value (text or number). |
| `app.typeText(element, text, {keys}?)` | Insert at the caret through `AXValue`; falls back to key events sent to this app only. |
| `app.pressKey(key, {element?, count?}?)` | Send a key or shortcut to this app only. |
| `app.scroll(element, direction, pages?)` | Scroll the area containing the element by pages. |
| `app.performSecondaryAction(element, action)` | `AXPress`, `AXIncrement`, `AXDecrement`, `AXPick`, `AXConfirm`, `AXCancel`, or `AXScrollToVisible`, if the element lists it. |
| `app.checkInteraction(element?, {intrusive}?)` | Read-only conflict check. Actions repeat it themselves. |
| `computer.release()` | Hide this session's indicators and drop its snapshots. |
| `computer.close()` | Stop the helper and reject pending work. |

Every action also accepts `{waitMs}` in its trailing options.

```js
const computer = createComputer({
  apps: ['com.apple.TextEdit'],
  agent: 'Claude',    // optional display identity
  overlay: true,     // default: dots and ghost cursor enabled
  timeoutMs: 20000,
});
```

An explicit `agent` takes priority over MCP `initialize.clientInfo.name`. Identity is presentation metadata, not authentication. `executable`, or the `OPENCOMPUTER_NATIVE` environment variable, overrides the helper path. A timeout terminates the connection, preventing a late reply from being applied to a later request. **Do not blindly retry a timed-out action: inspect its outcome first.**

`apps: ['*']` explicitly enables all running apps. Each request still names one bundle ID, and snapshots, captures, and actions remain scoped to its process. The default is no app access. This uses the apps and logged-in sessions on the current Mac; it creates no VM and copies no credentials.

## Observing

A snapshot contains `snapshot`, `app`, `pid`, `nodes`, `windows`, `truncated`, `elapsedMs`, and `frontmostApp`. Nodes have `id`, `role`, `parent`, available labels/values, `enabled`, `settable`, supported `actions`, and a `frame` in macOS global accessibility coordinates.

Attributes are read in one batched call per element, so a typical window of about a thousand elements reads in well under a second. Trees are bounded to `limit` nodes (default 1200, at most 5000) and 4000 characters per string; `truncated: true` means more exists. Narrow with `{window: index}`, `{root: elementId}`, or the MCP `query` argument rather than raising the limit.

Some apps report rows on a list but expose none as children. Observe then hit-tests the list's visible area, walks what it finds, marks those nodes `via: "hitTest"`, and reports `hitTestDiscovered`. Only rows on screen are found: scroll and observe again for more.

Lists with more than 60 children are read after the rest of the window, so controls beside a long list are never lost to the time budget (`budgetMs`, 1000–15000, default 4000). `windowTitle` selects a window by title instead of index.

Element IDs stay valid across actions. A full or window observe of an app replaces that app's snapshot; `root` and `menu` observations extend the current one and keep existing IDs. Snapshots expire 5 minutes after their last use and are scoped to one process. A stale or foreign ID fails with `STALE_SNAPSHOT`.

### Changed targets

An element ID names an accessibility object, not a position, so an action always reaches the object observe saw. That object can still sit in a tab the person has since left, or on a page that has since changed. Observe records, for every element, the window it was in, that window's title and selected tab (`AXTabButton`), and the web page (`AXWebArea` and its `AXURL`) for web content. Every element action (`click`, `setValue`, `typeText`, `performAction`, `scroll`, `pressKey` with an element, and `root` observes) checks them twice: when the request arrives, and again right before dispatch, after any wait for the person to pause. It refuses with:

| Code | `details.reason` | Meaning |
| --- | --- | --- |
| `STALE_ELEMENT` | | The element no longer exists (its view or page was replaced). |
| `TARGET_CHANGED` | `window-title` | The window title differs from the snapshot's, which in a browser means another tab or page is showing. `details.was` and `details.now` give both. |
| | `tab` | The tab that was selected in that window is no longer selected (catches tabs with identical titles). |
| | `page-url`, `page-closed` | The element's web page navigated or went away. Addresses are reported without query or fragment. |
| | `detached` | The element's page or view is no longer in its window, as happens to a background tab. |
| | `window-closed` | The window closed. |
| | `window-unknown` | `pressKey` without an element: keys would reach a focused window the latest snapshot did not read. |

Both carry `details.dispatched: false`: nothing was sent. Observe again and use the new IDs. Changes the session causes itself (pressing a tab, a click that retitles the page, closing its own tab) update the snapshot, so later actions in that window keep working; old-page elements still fail the page and attachment checks. Changes made while the person was clicking, typing, or scrolling are never absorbed this way. `pressKey` without an element checks the app's focused window against the app's latest snapshot, when one exists.

`clickPoint` resolves a pixel at dispatch time, so the screenshot records the window title, size, and the page at its centre. The point is refused with `TARGET_CHANGED` if the title or size changed, or the pixel now lands on another page; screenshots older than 5 minutes return `SCREENSHOT_REQUIRED`.

A window whose title changes by itself (a ticking timer, an unread counter) makes actions in it fail more often; observe again just before acting.

### Action log

Every helper process writes one JSON Lines file, `~/Library/Logs/OpenComputer/session-<UTC start>-<helper pid>.jsonl` (`OPENCOMPUTER_LOG_DIR` moves it, `OPENCOMPUTER_LOG=0` turns it off). `status` returns its path as `actionLog`. The first line names the session: version, helper pid, the processes above it (`clients`), allowed apps, and agent. Then one line per `configure`, `release`, `open`, `observe`, `screenshot`, and action, written whatever the outcome:

- `time` (UTC, milliseconds), `event` (the method), `app`, `pid`, `snapshot`, `element`, and non-sensitive arguments (`key`, `count`, `direction`, `pages`, `action`, `keys`, `x`, `y`, `waitMs`).
- `target`: the resolved element's `role`, `subrole`, `label`, `identifier` (as observed, if it is gone); `pressed` when a container was pressed instead; `window` (current title), `tab` (the tab the snapshot saw selected), and `page` (address without query or fragment).
- `outcome`: `dispatched`, `ok` (read-only), `refused` (nothing sent), or `failed` (sent, then errored), plus `error` with `code`, `message`, and the reason fields; for dispatched actions `delivery`, `confirmed`, `focusChanged`, `focusRestored`, `frontmostBefore`, `frontmostAfter`, and `elapsedMs`.

Typed text and set values are never written, only `textLength` or `valueLength`; a bare one-character `key` is written as `[character]`. Observe lines carry window titles and a node count, never element values; screenshot lines never carry pixels. Files are created `0600` in a `0700` directory and deleted after 30 days. `opencomputer log [MINUTES] [--app BUNDLE] [--json]` merges every session's log in time order.


Chromium and Electron apps build their accessibility tree on demand. The first observe switches it on (`webAccessibilityEnabled: true`); observe again if page content is missing.

## Acting without the pointer or the foreground

| Action | How it is delivered |
| --- | --- |
| `click`, `clickPoint` | `AXPress` on the element or a pressable container up to three levels up; otherwise `AXSelected`, `AXPick`, or the app's own text focus (`AXFocused`). The result's `delivery` names which, and `pressed` describes the container when it differs. |
| `setValue` | `AXValue`. Numeric controls take numbers. |
| `typeText` | `AXValue` plus `AXSelectedTextRange` when the control exposes both. Otherwise, or with `keys: true`, Unicode key events posted to the target process. Key delivery is limited to 2000 characters per call. |
| `pressKey` | Key events posted to the target process with their own modifier state. Names: `Return`, `Tab`, `Escape`, `Space`, `Delete`, `ForwardDelete`, arrows, `Home`, `End`, `PageUp`, `PageDown`, `F1`–`F12`, or a character, with `cmd`, `ctrl`, `alt`, `shift`, `fn` joined by `+`. |
| `scroll` | `AXScroll*ByPage`, or the enclosing scroll area's scroll bar value. |

Key events are posted to one process ID, never to the login session, so they cannot reach the app the person is typing in. No synthetic mouse events are ever posted, and the real pointer never moves.

Results include `dispatched`, `delivery`, `frontmostBefore`, `frontmostAfter`, `focusChanged`, `focusRestored`, and `verificationRequired`. `confirmed: false` means the app did not reply within three seconds, which is normal for a control that opens a modal dialog or menu. A result reports dispatch, not task success: observe to verify.

### Limits

- **Keys go to the app's own focus.** A background app keeps a focused control per window; `pressKey` and key-typed text land there. Pass `element` to move that focus first. Some apps ignore key events while inactive, and some shortcuts are handled by the system rather than the app. Verify by observing.
- **No hover, drag, right-click, or pixel-exact click.** `clickPoint` resolves a pixel to an accessibility element; canvases, games, and custom-drawn controls with no accessible element return `UNSUPPORTED_TARGET`.
- **`AXShowMenu` and `AXRaise`** return `FOCUS_UNSAFE`: they open a menu under the pointer or raise a window.
- **Secure text fields** are rejected (`SECURE_FIELD`) for values, clicks, and keys.
- Minimized windows, locked screens, and apps with incomplete accessibility support may not work.

Unsupported actions return an error. They never fall back to global input.

## Staying out of the person's way

Each action samples the person's activity immediately before dispatch. Only work in the same place blocks:

| Signal | Behavior |
| --- | --- |
| Activity in other apps, or in another window of the target app | Never blocks. |
| Mouse button held in the target app or over its window | Wait. |
| Key-delivered action while the person used the target app in the last 3 s | Wait (`app-in-use`): keys would land in their focus. |
| Person typed into an editor in the target window in the last 3 s | Wait (`editing-window`). |
| Key held in, or pointer over, the target window | Wait (`keyboard-held`). |
| Pointer on the target control and moved or clicked in the last 1 s | Wait (`pointer-near-target`). |
| Typing / clicking / scrolling in the target window | Wait 1.5 / 0.8 / 0.8 s of quiet. |

An action waits up to `waitMs` (default 2000, at most 10000; `OPENCOMPUTER_WAIT_MS` sets the default) for the conflict to clear, re-sampling every 150 ms, and then runs. If it does not clear, the action returns `USER_BUSY` with `details.reason`, `details.retryAfterMs`, `details.waitedMs`, and `details.dispatched: false`. Nothing is queued. Retry later or work in another window.

Some apps bring themselves forward when a control is pressed. The helper watches for an activation the person did not cause — no click, modifier, or key from them — and hands the foreground back to the app they were in. The result then carries `focusChanged: true` and `focusRestored: true`, and the session stays usable. Late self-activations are undone for 1.5 s after the action returns. A switch the person makes themselves is left alone. This is correction after the fact: a self-activating app can flash forward for a moment, and public macOS APIs cannot prevent that.

### Take over and approvals

The person can stop an agent and approve its consequential actions from the activity card ([details](ACTIVITY.md#take-over)). Both are decided before the activity check and before anything is sent:

| Error | Meaning | What the agent should do |
| --- | --- | --- |
| `PAUSED_BY_USER` | The person pressed **Take over**. Actions and `open` are refused until they press **Resume**; observe and screenshot still work. Resuming drops earlier snapshots. | Stop acting. Tell the person in chat, and observe again after they resume. |
| `APPROVAL_PENDING` | `OPENCOMPUTER_CONFIRM` covers this action and the person has not answered yet (`details.retryAfterMs`). The question stays on screen. | Say in chat what you are waiting for, then retry the same call. It runs once after the person holds **Allow**. |
| `APPROVAL_DENIED` | The person pressed **Deny**. | Do not retry. Ask how to proceed. |
| `APPROVAL_UNAVAILABLE` | Approval is required but `OPENCOMPUTER_OVERLAY=0` hides the card. | Report it; the person must change the configuration. |

All four carry `details.dispatched: false`. `OPENCOMPUTER_CONFIRM` takes `sensitive` (presses on controls labelled Send, Pay, Delete and similar, plus Return, Enter and cmd+Delete), bundle IDs (every action in that app), or `all`, combined with commas. `status().approvals` reports the active rules. An approval wait is capped so the request finishes inside the JavaScript client's default 20-second timeout; a client configured with a shorter `timeoutMs` should keep `OPENCOMPUTER_CONFIRM` off or raise it.

The check and the dispatch are not atomic, and input silence does not prove the person stopped reading. Browser tabs are part of their window; there is no per-tab ownership, but an action never lands on a tab or page other than the one it observed (see [changed targets](#changed-targets)).

## Activity state

Observation, capture, and actions update the indicators. `status().activity` contains `enabled`, `active`, `agent`, `app`, `action`, `windowTitle`, `pillVisible`, `expanded`, `ghostVisible`, `ghostFloating`, `ghostReason`, `stackRow`, `nonActivating`, `clickThrough`, `paused`, `approvalPending`, `steps` (timeline length), `controlsInteractive` (the open card is taking clicks for its buttons), and helper window IDs/geometry for diagnostics. `clickThrough` is false only while the person has the card open. See [activity behavior](ACTIVITY.md).

## MCP

Tools: `status`, `apps`, `open`, `observe`, `screenshot`, `checkInteraction`, `click`, `clickPoint`, `setValue`, `performAction`, `typeText`, `pressKey`, `scroll`, and `release`. Clients add their own server-name prefix. Use `tools/list` for the canonical schemas.

`observe` returns a compact text outline by default, one line per useful element:

```
app com.apple.TextEdit pid 412 snapshot 9F2C…
38 elements in 21 ms; frontmost app: com.apple.Terminal
windows: [0] "Untitled" main

[0] Window "Untitled"
  [4] TextArea ="Hello" editable focused
  [9] Button "Close" actions:Press
```

Unlabelled containers are dropped and their children move up a level. `query` lists only elements whose role, label, identifier, or value contain every word, which is the fastest way to find a control in a large app. `format: "json"` returns every node with its frame.

Screenshots use image blocks plus text metadata. Native errors are `isError: true` tool results with `code`, `message`, and optional `details`. Invalid JSON-RPC or schema arguments return protocol errors.

Only stdio is supported. Requests are serialized per connection. The server supports `initialize`, `ping`, `tools/list`, `tools/call`, and ignores notifications. A request line is limited to 1 MiB.

### Any agent, several at once

Every MCP client starts its own server and helper process, so any number of agents can work at the same time, each with its own indicator. macOS attributes Accessibility and Screen Recording to the app that launched the server, so each agent host needs its own approval once. Two agents acting on the same window are not coordinated with each other.

## Native protocol

The helper accepts newline-delimited JSON with `method` plus arguments and returns one `result` or `error` object per line. The JavaScript client is the supported integration boundary. The helper itself checks the allowlist, macOS permissions, process identity, secure fields, snapshot ownership, expiry, and the target's window, tab, and page, and writes the action log.
