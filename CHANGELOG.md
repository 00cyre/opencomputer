# Changelog

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
