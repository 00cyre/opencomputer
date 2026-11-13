# API reference

A `Computer` instance owns a serial native helper connection. `getApp(bundleId)` creates a handle. Every operation names one explicitly allowed app, and nothing the helper does moves the pointer, takes keyboard focus, or brings an app forward.

## JavaScript

| Method | Result |
| --- | --- |
| `computer.status()` | Permissions, allowed bundle IDs, version, foreground app, activity state, default `waitMs`, and `focusRestorations`. |
| `computer.getState()` | Running regular apps: name, bundle ID, PID, frontmost, hidden, allowlist status. |
| `computer.getApp(bundleId, {pid}?)` | App handle. Pass `pid` when several instances of one bundle run. |
| `app.open(url?)` | Launch the app, or open an `http`, `https`, or `file` URL in it, without activating it. |
| `app.getAXState({window?, windowTitle?, root?, menu?, limit?, budgetMs?, refresh?}?)` | Snapshot, node array, and window list. Select a window, expand a subtree, or read the menu bar. `refresh: true` re-reads into the current snapshot so element IDs keep working. |
| `app.getScreenshot(windowId?, {marks?, region?, ocr?, maxEdge?}?)` | PNG data/metadata, or `selectionRequired` with candidate windows. See [screenshots](#screenshots-marks-zoom-and-text). |
| `app.readText(element, {offset?, length?}?)` | The element's full value, or the text inside a container, in pages. |
| `app.waitFor(query, {gone?, timeoutMs?, window?, windowTitle?}?)` | Re-reads until an element matches (or none does); resolves with the read and its `matches`. |
| `app.chooseMenu(path, {waitMs?}?)` | Presses a menu bar command by path, such as `'File > Export as PDF…'`. |
| `app.verify(expect, {timeoutMs?, window?, windowTitle?}?)` | Checks conditions against a fresh read; resolves with `outcome` (`confirmed`, `deviation`, or `unverifiable`), each condition's `results`, and the read. See [verifying](#verifying). |
| `app.click(element)` | Press, select, or focus the element, or the control containing it. No pointer. |
| `app.clickPoint(x, y)` | The same press on the element under a pixel of the last screenshot of this app. |
| `app.setValue(element, value)` | Replace a writable accessibility value (text or number). |
| `app.typeText(element, text, {keys}?)` | Insert at the caret through `AXValue`; falls back to key events sent to this app only. |
| `app.pressKey(key, {element?, count?, via?}?)` | Send a key or shortcut to this app only. `via: 'menu'` presses the menu item that has this shortcut instead. |
| `app.scroll(element, direction, pages?)` | Scroll the area containing the element by pages. |
| `app.performSecondaryAction(element, action)` | `AXPress`, `AXIncrement`, `AXDecrement`, `AXPick`, `AXConfirm`, `AXCancel`, or `AXScrollToVisible`, if the element lists it. |
| `app.checkInteraction(element?, {intrusive}?)` | Read-only conflict check. Actions repeat it themselves. |
| `computer.release()` | Hide this session's indicators and drop its snapshots. Returns a `summary`: `actions` sent, `refused`, `failed`, and the `apps` acted in since the session began or was last released. |
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

Append `:read` to an entry for read-only access: `apps: ['com.apple.Mail:read']`, or `'*:read'` for every app. Read-only apps can be observed, captured, read with `readText`, waited on, and launched, but every action and `open` with a URL refuses with `READ_ONLY_APP` (`details.dispatched: false`) before anything is resolved. An explicit `bundle:read` entry wins over `*`, so `['*', 'com.apple.Mail:read']` opens everything except Mail, and `['*:read', 'com.apple.TextEdit']` lets the agent read everything and act only in TextEdit. `apps` reports each app's `access` (`full`, `click`, `read`, or `none`).

Append `:click` for click-only access: `click`, `clickPoint`, `performAction`, `scroll`, and `menu` work, but `setValue`, `typeText`, `pressKey`, and `open` with a URL refuse with `CLICK_ONLY_APP` (`details.dispatched: false`). `*:click` applies it to every app.

`*` never lets the agent act in the app it runs in. At start the helper records the apps above it in its process chain, such as the terminal, editor, or chat app that started the MCP server. Under `*` or `*:click` those apps are read-only and actions in them refuse with `HOST_APP_PROTECTED`, so an agent cannot press its own approval prompts or type into its own conversation. Listing the app by name allows it. `status` returns them as `protectedHosts`; the action log's first line records them as `hosts`.

`apps: ['*']` explicitly enables all running apps. Each request still names one bundle ID, and snapshots, captures, and actions remain scoped to its process. The default is no app access. This uses the apps and logged-in sessions on the current Mac; it creates no VM and copies no credentials.

## The agent browser

`app: "agent-browser"` names a second Google Chrome instance with its own profile folder (`~/Library/Application Support/OpenComputer/AgentBrowser`; `OPENCOMPUTER_AGENT_PROFILE` moves it). Agents browse there instead of in the person's Chrome:

- `open({app: "agent-browser", url})` starts it in the background, or opens the link as a new tab in its window. The result carries `launched`, `via` (`launch`, `new-tab`, or `handoff`), and `profile`.
- It runs with occluded-window and renderer backgrounding turned off and the page accessibility tree always on, so it keeps working while covered or behind a fullscreen app.
- Every other method takes `app: "agent-browser"` like any app, and `agent-browser:read` or `agent-browser:click` limit it like any other entry. `com.google.Chrome` without a `pid` always means the person's Chrome, and `apps` lists the agent instance as `agent-browser`.
- It has its own cookies and sign-ins. Sign in once per site in its window; agents never type passwords (`SECURE_FIELD`).
- While a fullscreen app is in front, `open` on it refuses with `USER_BUSY` and `details.reason: "fullscreen-app"`. Navigate an existing agent tab through its address bar instead.
- Starting it, or making a window after its last one closed, can bring Chrome forward for a moment before the focus guard hands the foreground back. Keep one agent tab open.

## Observing

A snapshot contains `snapshot`, `app`, `pid`, `nodes`, `windows`, `truncated`, `elapsedMs`, and `frontmostApp`. Nodes have `id`, `role`, `parent`, available labels/values, `enabled`, `settable`, supported `actions`, and a `frame` in macOS global accessibility coordinates.

Attributes are read in one batched call per element, so a typical window of about a thousand elements reads in well under a second. Trees are bounded to `limit` nodes (default 1200, at most 5000) and 4000 characters per string; `truncated: true` means more exists. Narrow with `{window: index}`, `{root: elementId}`, or the MCP `query` argument rather than raising the limit.

Some apps report rows on a list but expose none as children. Observe then hit-tests the list's visible area, walks what it finds, marks those nodes `via: "hitTest"`, and reports `hitTestDiscovered`. Only rows on screen are found: scroll and observe again for more.

Lists with more than 60 children are read after the rest of the window, so controls beside a long list are never lost to the time budget (`budgetMs`, 1000–15000, default 4000). `windowTitle` selects a window by title instead of index.

Element IDs stay valid across actions. A full or window observe of an app replaces that app's snapshot; `root` and `menu` observations extend the current one and keep existing IDs. Snapshots expire 5 minutes after their last use and are scoped to one process. A stale or foreign ID fails with `STALE_SNAPSHOT`.

### Re-reading and changes

`observe` with `refresh: true` and the current `snapshot` re-reads the same scope into that snapshot instead of starting a new one: elements seen before keep their IDs, new ones get new IDs, and the result carries `refreshed: true`. Without a current snapshot it fails with `STALE_SNAPSHOT`.

The MCP server builds on it. `observe` with `changes: true` re-reads the scope of that app's last full or window observe and lists only what differs. Actions do the same by default once the app has been observed in the session: the server first waits for the app to settle, then compares. Pass `changes: false` to skip it, or `changes: true` to get the full outline when there is nothing to compare with.

```
app com.apple.TextEdit pid 412 snapshot 9F2C… (re-read; earlier ids still apply)
41 elements in 18 ms; frontmost app: com.apple.Terminal
changes since the last read: 1 added, 1 changed, 0 removed

+ [57] Sheet "Save"
~ [4] TextArea ="Hello world" editable focused
    was: TextArea ="Hello" editable
```

`+` is new, `-` went away, `~` reads differently, with what it was. A truncated read never reports removals. One call then both acts and verifies, and the IDs in the diff work with the next action. When the earlier snapshot is gone (after `release` or a reconnect), an action's default comparison says so and reads nothing, so the agent's IDs are never replaced behind its back; an explicit `changes: true` returns the full outline instead.

**Settling.** From its first observe of an app, the helper listens to that app's accessibility notifications (elements created and destroyed, values, titles, focus, windows, sheets, selection, rows, menus, busy state), keeping only counts. After an action the server calls the helper's `settle`, which returns once the app has sent nothing for 200 ms, or after 1.5 s. The diff then says how long it waited and what arrived:

```
settled after 240 ms; the app sent 3 accessibility notifications (ValueChanged 2, FocusedUIElementChanged 1)
focused: [4] TextArea ="Hello world" editable focused
```

When the outline shows no change, that line tells the two cases apart. No notifications means the action most likely had no effect (for a shortcut, the diff suggests `via: "menu"`). Notifications without a visible change mean the effect is somewhere the read did not reach: another window, a menu, or past the read limit. Apps differ in how much they report, so treat this as evidence, not proof. Up to 8 apps are watched per session; `release` stops them all.

**Dialogs.** Outlines and diffs start with an `open dialog:` line when a sheet, dialog, or system dialog is in the read, because controls behind it usually do not respond until it is answered.

### Verifying

Actions take `expect`, a list of up to 10 conditions, and the read-only `verify` tool takes the same list. A condition names elements by `element` ID and/or `query` words, with optional `value` (exact), `valueContains` (ignoring case), `enabled`, `selected`, and `focused`; or names a window by `windowTitle` words alone. `exists: false` turns it into "nothing like this is there".

```json
{"app":"com.apple.TextEdit","snapshot":"9F2C…","element":9,"expect":[{"query":"Sheet Save","exists":false},{"windowTitle":"report.txt"}],"expectMs":3000}
```

After the action settles, the server re-reads until every condition holds or `expectMs` passes (default 0: one read; at most 30000), and starts the result with the outcome:

```
outcome: confirmed. Expectations met: 2 of 2.
ok {"query":"Sheet Save","exists":false}: nothing matches
ok {"windowTitle":"report.txt"}: found window "report.txt"
```

`deviation` means a condition does not hold, with what was found instead. `unverifiable` means the read was cut short, so absence could not be proved. In `batch`, a deviation stops the remaining steps with `EXPECTATION_FAILED` (`details.dispatched: true`, since that step ran). `verify` re-reads into the same snapshot when it can and says whether earlier IDs still apply; `timeoutMs` keeps it re-reading until the conditions hold.

### Waiting

`waitFor` re-reads the app about three times a second, keeping IDs, until an element matches `query` (the same word matching as observe), or with `gone: true` until none matches. It returns the matching lines and how long it waited, or `WAIT_TIMEOUT` with `details.reads` and `details.matches` after `timeoutMs` (default 10000, at most 60000). Use it after an action that opens a sheet, loads a page, or finishes a download, instead of observing in a loop. A truncated read never counts as gone.

### Reading text

`readText` returns the full `AXValue` of an element (`source: "value"`), or for a container with no text value, such as a web area, message, or table, the text inside it in reading order (`source: "contents"`): static text, field values, and the labels of leaf buttons and links, with pieces on one visual line joined by spaces. Secure fields are skipped and refused. Pages are given in UTF-16 units: `offset` (default 0) and `length` (default 20000, at most 100000); `more: true` means there is text after this page. It is cheaper than an outline for reading an article or a long document. The action log records only the length.

### Menus

Menu items read with `menu: true` carry their keyboard shortcut as `shortcut` in `pressKey` syntax (`cmd+shift+s`), shown in the outline as `keys:cmd+shift+s`. The MCP `menu` tool, and `app.chooseMenu`, take a path such as `"File > Export as PDF…"` or `"Format > Font > Bold"`: they read the menu bar and press that item with `AXPress`, without opening the menu or bringing the app forward. Matching ignores case and a trailing ellipsis, and falls back to the first title that starts with the step. `MENU_ITEM_NOT_FOUND` lists the titles available at the step that failed (`details.available`); `MENU_ITEM_DISABLED` means the item is greyed out; a path ending on a submenu is refused with its items. Some apps only update a menu's items when it is opened by hand, and some ignore presses while in the background: verify the effect.

`pressKey` with `via: "menu"` (JavaScript: `{via: 'menu'}`) looks for the menu bar item whose shortcut is that key, ignoring modifier order and case, and presses it instead of sending keys. macOS hands menu key equivalents to the front app, so many apps in the background ignore a shortcut sent as keys but run the same command from its menu item. The result carries `delivery: "menu"`, `menuItem` (its path), and `shortcut`. A shortcut no menu item has fails with `MENU_ITEM_NOT_FOUND`; a disabled item with `MENU_ITEM_DISABLED`; neither sends anything. The menu read adds to the current snapshot, so earlier IDs stay valid.

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

Typed text and set values are never written, only `textLength` or `valueLength`; a bare one-character `key` is written as `[character]`. Observe lines carry window titles and a node count, never element values; screenshot lines never carry pixels. Files are created `0600` in a `0700` directory and deleted after 30 days. `opencomputer log [MINUTES] [--app BUNDLE] [--json]` merges every session's log in time order, and `--summary` prints one line per session instead: actions sent, refused, and failed, reads, and the apps acted in.

Each line also carries `prev`, the first 32 hex digits of the SHA-256 of the line before it (empty on the first line). `opencomputer log --verify` checks every session file and exits non-zero if a line inside one was changed or removed. The chain cannot show that lines were cut from the end of a file or that a whole file was deleted, and anyone who can write the file can recompute it, so it catches accidental and casual edits, not a determined attacker with your account. Logs written before this version have no chain and are reported as such.


Chromium and Electron apps build their accessibility tree on demand. The first observe switches it on (`webAccessibilityEnabled: true`); observe again if page content is missing.

## Screenshots: marks, zoom, and text

`screenshot` takes three options, together or apart:

- **`marks: true`** draws each pressable, pickable, or editable element of the app's latest snapshot that lies in the captured window as a coloured box with its element ID. A model that reads the picture can name the control it means and act with `click`, without guessing coordinates. Window-sized containers are left out; at most 300 marks. The result carries `marked`; without a current snapshot it carries `marked: 0` and `marksNote`.
- **`region: {x, y, width, height}`** zooms in: it captures only that rectangle, given in pixels of the most recent screenshot of the app, of the same window, at up to the display's pixel density (at most `maxEdge` px on the long side), so small text becomes legible. The result carries `zoomed: true`. `clickPoint`, and the next `region`, then use the zoomed picture's pixels, so zooming twice narrows further. The window must have kept its title and size since that screenshot.
- **`ocr: true`** runs Vision text recognition on the picture and adds `lines`: `{text, x, y, width, height, confidence}` in its pixels, in reading order. The MCP server returns them as a separate text block (`[x,y,width,height] text`). It reads canvases, images, and custom-drawn controls the outline cannot see. MCP `image: false` leaves the picture out and returns only metadata and text, which costs far fewer tokens.

Recognition runs on the Mac; neither recognized text nor pixels are logged or stored.

`maxEdge` (200–4000, default 1600) caps the picture's long side in pixels. A whole window is captured at one pixel per point at most, so `maxEdge` mainly makes pictures smaller, which costs fewer tokens.

When ScreenCaptureKit does not answer within 6 s, the window is taken with the system `screencapture` tool for the next two minutes and the result carries `captureTool: "screencapture"`. `marks`, `ocr`, and `maxEdge` work the same there; `region` is not supported on that path, so the whole window comes back with `regionIgnored: true`. `OPENCOMPUTER_CAPTURE=screencapture` forces that path.

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

Tools: `status`, `apps`, `open`, `observe`, `screenshot`, `readText`, `waitFor`, `verify`, `checkInteraction`, `click`, `clickPoint`, `setValue`, `performAction`, `typeText`, `pressKey`, `scroll`, `menu`, `batch`, and `release`. Clients add their own server-name prefix. Use `tools/list` for the canonical schemas. Every action tool also takes `changes` (see [re-reading and changes](#re-reading-and-changes)) and `expect` with `expectMs` (see [verifying](#verifying)).

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

`batch` runs up to 20 tool calls in order, each `{tool, arguments}` with the same names and arguments as a single call, and stops at the first error. Every step is validated before the first runs, so a typo in a late step sends nothing; each step still waits for the person and checks its target as usual. On failure the content holds the finished steps' results followed by the error, whose `details` name the failing `step`, its `tool`, and how many steps `completed`. Only the last action in a batch compares by default, so a form fill returns one diff; a step can still pass `changes: true`. A step whose `expect` does not hold stops the batch with `EXPECTATION_FAILED`. A batch is one tool call to your client, so a client that approves tool calls one at a time approves the whole sequence at once.

Screenshots use image blocks plus text metadata. Native errors are `isError: true` tool results with `code`, `message`, and optional `details`, plus advice for the agent: `retrySafe` (true when nothing reached the app, so repeating the call cannot double an effect; false after a timeout or when the action was sent), `next` (the call most likely to help, such as `{"tool":"observe","arguments":{"app":"…"}}` after `STALE_SNAPSHOT`, or the same call with `afterMs` after `USER_BUSY`), and `hint` (for example, to ask the person when an app is not allowed). Invalid JSON-RPC or schema arguments return protocol errors.

Only stdio is supported. Requests are serialized per connection. The server supports `initialize`, `ping`, `tools/list`, `tools/call`, and ignores notifications. A request line is limited to 1 MiB.

### Any agent, several at once

Every MCP client starts its own server and helper process, so any number of agents can work at the same time, each with its own indicator. macOS attributes Accessibility and Screen Recording to the app that launched the server, so each agent host needs its own approval once. Two agents acting on the same window are not coordinated with each other.

## Native protocol

The helper accepts newline-delimited JSON with `method` plus arguments and returns one `result` or `error` object per line. The JavaScript client is the supported integration boundary. The helper itself checks the allowlist, macOS permissions, process identity, secure fields, snapshot ownership, expiry, and the target's window, tab, and page, and writes the action log.

`settle` (`{app, pid?, quietMs?, maxMs?}`) is read-only: it waits until the app has sent no accessibility notification for `quietMs` (default 200, 50–2000) or `maxMs` passes (default 1500, 100–10000), and returns `watched`, `settled`, `waitedMs`, `notifications` (the count since the app was last observed), and `kinds` (counts by notification). Apps not yet observed in the session return `watched: false` after a `quietMs` pause.
