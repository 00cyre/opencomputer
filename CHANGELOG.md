# Changelog

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
