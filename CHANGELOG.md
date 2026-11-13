# Changelog

## 0.5.0 — 2026-11-13

Ideas from other computer-use projects, rebuilt for background control on the Mac: every action reports what changed and whether it took effect, shortcuts reach background apps through their menus, screenshots show what the outline cannot, and access can be read-only or click-only, never including the agent's own app.

### See, stop, and approve

The activity indicator now shows what the agent has been doing and lets you stop it or approve what matters.

- **Activity card.** The three dots sit in a glass pill and open on hover into a card that grows out of them: the app's icon badged with the agent, "Claude is using Notes", the window title, elapsed time, and the last three steps as a timeline (current step pulsing, earlier ones checked, failures crossed out with a reason). It follows light and dark mode, and stacked sessions make room for an open card.
- **Take over.** A button on the card pauses the session. Actions and `open` answer `PAUSED_BY_USER` with nothing sent until you press **Resume**; observing still works. Resuming drops earlier snapshots so the agent looks again. The pause outlives `release`.
- **Approvals (`OPENCOMPUTER_CONFIRM`).** `sensitive` asks before presses on controls labelled Send, Pay, Delete, Post and similar, and before Return, Enter and cmd+Delete; a bundle ID asks before every action in that app; `all` asks before everything. The card opens with **Deny** / **Hold to allow**: Allow counts only after a half-second held press and is never offered to assistive or automation tools. Unanswered requests return `APPROVAL_PENDING` and run once when retried after Allow; **Deny** returns `APPROVAL_DENIED`. Approved actions are marked in the action log. `status().approvals` shows the rules.
- **Ghost cursor.** Redrawn with a white outline, soft shadow, colour gradient and the agent's name tag. It leans into horizontal travel and dips with a ripple when an action lands.
- `npm run test:approval` covers the approval rules and question lifecycle; CI also compiles the UI harness, and a new "Overlay screenshots" workflow runs the live UI test on a GitHub macOS runner and can commit refreshed screenshots to `docs/assets`.

### Actions that check themselves

- **`changes` on observe and every action.** The server re-reads the app's last scope into the same snapshot and returns only what was added (`+`), removed (`-`), or reads differently (`~`, with what it was). IDs stay valid, so one call acts and verifies. Built on the helper's new `observe` `refresh` mode, which keeps element IDs across re-reads.
- **`waitFor`.** Re-reads about three times a second until an element matches a query, or with `gone` until none does, then returns the matches with usable IDs, or `WAIT_TIMEOUT`.
- **Screenshot `marks`, `region`, and `ocr`.** Marks draw the latest snapshot's element IDs on the picture. A region zooms into the previous screenshot at up to display density, and `clickPoint` follows the zoomed picture. OCR returns Vision text lines with pixel boxes; MCP `image: false` returns the text alone.
- **`readText`.** An element's full value, or a container's text in reading order, in pages of up to 100,000 UTF-16 units.
- **`menu`.** Runs a menu bar command by path, such as `File > Export as PDF…`, without opening the menu. Menu items now report their keyboard shortcut (`keys:cmd+shift+s`).
- **`batch`.** Up to 20 tool calls in one request, all validated first, stopping at the first error.
- **Read-only apps.** `OPENCOMPUTER_APPS` entries ending in `:read`, including `*:read`, allow observing, screenshots, and reading but refuse actions and URLs with `READ_ONLY_APP`. An explicit `bundle:read` entry overrides `*`.
- **Settle on the app's own notifications.** From its first observe of an app the helper listens to that app's accessibility notifications, keeping only counts. After an action the server waits until the app goes quiet (200 ms of silence, at most 1.5 s) instead of a fixed 300 ms, and the diff says how many notifications arrived. So "no change" now tells apart an action with no effect (the app reported nothing) from one whose effect the outline cannot show.
- **Diffs by default.** Once an app has been observed, actions return what changed without asking; `changes: false` skips it. `batch` compares only after its last action. A default comparison never replaces the agent's snapshot: when the old one is gone it says so instead.
- **`expect` and `verify`.** Actions and batch steps take conditions (`element` or `query`, `value`, `valueContains`, `enabled`, `selected`, `focused`, `windowTitle`, `exists`), re-read until they hold or `expectMs` passes, and report `confirmed`, `deviation`, or `unverifiable`. A deviation stops a batch with `EXPECTATION_FAILED`. The read-only `verify` tool checks the same conditions without acting.
- **`pressKey` via `"menu"`.** Presses the menu bar item that has the shortcut, which apps in the background honour more reliably than keys. A shortcut that changed nothing suggests it.
- **Dialogs and focus.** Outlines flag an open sheet or dialog at the top; diffs name the focused element.
- **Error advice.** Every MCP error carries `retrySafe`, and often `next` (the call most likely to help) and `hint`.
- **Click-only apps.** `bundle:click` and `*:click` allow clicks and scrolling, and refuse text, values, keys, and URLs with `CLICK_ONLY_APP`.
- **The agent's own app is protected.** Under `*`, the apps above the helper in its process chain (the terminal, editor, or chat app running the agent) are read-only and refuse actions with `HOST_APP_PROTECTED`, unless listed by name. `status` reports them as `protectedHosts`.
- **Session summary and a checkable log.** `release` returns what the session did (actions sent, refused, failed, apps). Action log lines carry a hash of the line before; `opencomputer log --verify` checks the chain and `opencomputer log --summary` prints one line per session.
- `screenshot` takes `maxEdge` (200–4000, default 1600) to make pictures smaller. Menu shortcuts now read with `cmd` first (`cmd+shift+s`), as `pressKey` takes them.
- JavaScript: `getAXState({refresh})`, `getScreenshot(windowId, {marks, region, ocr, maxEdge})`, `readText`, `waitFor`, `chooseMenu`, `verify`, and `pressKey(key, {via: 'menu'})`; `apps` accepts `:read` and `:click` entries. `ComputerError` moved to `src/errors.mjs` and is still exported from `src/computer.mjs`.
- `npm run test:perception` exercises these on the fixture, which gains an optional menu bar. The helper now links the Vision framework.

Validation: the helper and fixture compile for arm64 and x86_64 in CI and `npm test` covers the server side; the live overlay UI test passes on a GitHub macOS runner; the live fixture test has not yet been run on a Mac.

## 0.4.4 — 2026-11-12

Open and save panels on big folders, and steadier window choice.

- **Long lists are read last.** A list, table, outline, browser, or grid with more than 60 children is walked after the rest of the window, so a file panel on a big folder (641 items in Downloads) still returns its OK, Cancel, and Where controls before the time budget runs out. `observe` takes `budgetMs` (1000–15000, default 4000).
- **`clickPoint` inside open and save panels.** The host app's hit test stops at the panel's container; OpenComputer now descends the bridged tree to the smallest element under the point, so a pixel on Cancel presses Cancel.
- **`windowTitle`** picks the window whose title equals, or else contains, the text, so a transient untitled window no longer shifts the window you meant.
- **`AXOpen`** joins the actions `performAction` accepts, for rows and file-name fields that list it.

Not fixed: keys still do not reach an open panel of a background app (neither the host nor the panel's own service accepts them), and screenshots of a Chrome sheet were not reproduced here.

## 0.4.3 — 2026-11-12

The MCP server survives helper timeouts and picks up rebuilt helpers.

- **`ReconnectingComputer`.** `opencomputer serve` starts a new helper on the next request after a `TIMEOUT` or a helper exit, instead of answering `CLOSED` until the client restarts. It also moves to a rebuilt helper binary between requests. Either way snapshots are lost, so the agent sees `STALE_SNAPSHOT` and observes again.

## 0.4.2 — 2026-11-12

Screenshots stop hanging, and lists that hide their rows become readable.

- **Screenshots from a protected folder.** ScreenCaptureKit waits forever on `replayd` when the helper binary lives in `~/Documents`, `~/Desktop`, `~/Downloads`, or iCloud Drive, even with Screen Recording granted. The JavaScript client now runs a copy staged in `~/Library/Application Support/OpenComputer/helper/`, and capture answers `CAPTURE_TIMEOUT` after 12 s instead of hanging.
- **Hidden list rows.** A list, table, outline, or scroll area that exposes no children (Telegram's message and chat lists report rows but list none) is hit-tested across its visible area; what it finds is walked like any other element and marked `via: "hitTest"`. The observe result carries `hitTestDiscovered`.

## 0.4.1 — 2026-11-11

Actions only ever land on the page they observed, and every session leaves a record.

- **`TARGET_CHANGED`.** Element actions refuse when the element's window title, selected tab, or web page changed since the snapshot, or the element left its window (a background tab); `STALE_ELEMENT` when it no longer exists. Checked when the request arrives and again just before dispatch. `pressKey` without an element checks the app's focused window; `clickPoint` checks the screenshot's window title, size, and page. Changes the session caused itself keep the snapshot valid.
- **Action log.** One JSON Lines file per helper in `~/Library/Logs/OpenComputer`: time, method, resolved element, app, window, tab, page (no query), and outcome, including refusals. Typed text and values are recorded as a length only. `status().actionLog` gives the path; `opencomputer log` merges all sessions.
- Chrome for Testing is treated as a Chromium browser.
- `npm run test:guard` exercises both with the fixture's new browser-like tabs.

## 0.4.0 — 2026-11-10

Background control that works on real apps, without interrupting the person at the Mac.

- **Keys and typing in the background.** `pressKey` and key-delivered `typeText` post events to the target process only, so they never reach the app in use. `pressKey` is back in MCP discovery.
- **Clicks that land.** `click` presses the element or its pressable container, or selects or focuses it. `clickPoint` does the same for a pixel of the last screenshot. No synthetic mouse events.
- **`open`** launches an allowed app or opens a URL in it without activating it.
- **Fast, compact observation.** Batched attribute reads; a default text outline with `query` search; `menu` and `limit` options; Chromium/Electron accessibility switched on automatically.
- **Element IDs survive actions.** A snapshot lasts until the next full observe of that app, or 5 minutes; `root` and `menu` observations extend it.
- **No more dead sessions.** An app that brings itself forward is sent back and the previous foreground app restored (`focusRestored`). `FOCUS_CHANGED` and `FOCUS_PROTECTION_BLOCKED` are gone.
- **Far fewer `USER_BUSY` results.** Only activity in the same window blocks, and actions wait up to `waitMs` (default 2 s) for a pause before giving up.
- `scroll` falls back to the scroll bar and takes `pages`; `performAction` adds `AXConfirm`, `AXCancel`, `AXScrollToVisible`; `getApp` takes `pid` for multi-instance apps.
- The build replaces the helper binary atomically; `OPENCOMPUTER_NATIVE` selects another helper.

**Changed:** `app.pressKey(key, {element})` replaces `pressKey(element, key)`. MCP `observe` returns text unless `format: "json"`. Hover, drag, right-click, and canvas-only controls remain unsupported.

## 0.3.0 — 2026-11-07

- Check user activity before every mutation: window ownership, focused editing, held gestures/keys, pointer proximity, and recent typing, clicks, scrolling, or pointer movement.
- `USER_BUSY` returns a conflict reason, retry interval, and explicit no-dispatch evidence. The amber pill explains the wait; no actions are queued or automatically replayed.
- Keep unrelated background windows available, including another window in the same app. Preserve the separate focus-change latch and never restore focus.
- Read-only `checkInteraction` preflight, optional window/subtree observations, and explicit all-app access with `OPENCOMPUTER_APPS=*`.
- Twenty-one deterministic interaction scenarios and expanded live tests protecting a focused editor while another window is edited.

Runs on the existing Mac and its logged-in applications. Browser tab ownership, arbitrary coordinate control, and universal app compatibility are not provided by this update.

## 0.2.1 — 2026-11-06

- Smooth ghost-cursor travel between targets with eased starts and stops.
- Gentle idle floating, without moving the user’s real pointer or changing the actual action target.
- 60 Hz visual updates, nine deterministic motion checks, and a fixture-startup race fix in the UI test.
- Product-showcase videos in widescreen and vertical formats, assembled in Hyperframes from the actual native UI.

## 0.2.0 — 2026-11-06

- Default top-right animated three-dot indicator; hover reveals AI/app icons, window title, and latest action. Multiple sessions stack independently.
- Ghost cursor at the visible target; follows the window and hides behind other windows. Both panels are non-activating and click-through.
- Client-inferred or explicit agent identity, optional overlay opt-out, and a `release` tool for task completion.
- Removed raw key injection and focus-setting input. `typeText` now uses semantic selected-range replacement; MCP no longer advertises `pressKey`.
- App/window/control focus guard pauses writes after a detected transition. Recent user activity in the foreground target blocks dispatch. No focus restoration.
- Real activity, hover/rendering, and adversarial focus tests; refreshed Claude/Grok MCP benchmarks.

Apps can still activate themselves in response to semantic actions; the guard detects and contains observed transitions, not every possible delayed activation. See [activity behavior](docs/ACTIVITY.md) and [API migration details](docs/API.md).

## 0.1.0 — 2026-11-06

Initial public developer release for macOS 14+.

- App-scoped accessibility snapshots and background semantic actions.
- Window screenshots through ScreenCaptureKit.
- JavaScript client and ten-tool stdio MCP server.
- Native allowlist, snapshot expiry, secure-field handling, and bounded client requests.
- Disposable macOS fixture, real integration checks, and Claude/Grok benchmark runner.
- OpenLocker-style README, install, development, test, privacy, and security documentation.

Experimental: process-targeted keyboard input and app-dependent scrolling. No coordinate dragging, browser DOM layer, locked-screen support, Windows/Linux backend, graphical installer, or notarization. See `docs/BENCHMARKS.md` for actual validation rather than assuming universal app compatibility.
