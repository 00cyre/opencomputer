# Developing OpenComputer

Swift with AppKit, ApplicationServices, and ScreenCaptureKit. Plain JavaScript on Node 22+. No npm packages. The runtime targets macOS 14+; unit tests also run on Linux.

```sh
git clone https://github.com/00cyre/opencomputer.git
cd opencomputer
npm run build
npm test
npm run check
```

## Layout

| Path | Responsibility |
| --- | --- |
| `native/main.swift` | App allowlist, Accessibility tree/actions, window capture, native line protocol. |
| `native/ActivityOverlay.swift` | Non-activating dot/hover panel, visible-target ghost cursor, session stacking. |
| `native/FocusGuard.swift` | Foreground app/window/control observations and mutation pause. |
| `native/NativeSupport.swift` | Shared accessibility helpers and native errors. |
| `src/computer.mjs` | Native process lifecycle, serialization, timeout handling, app handles. |
| `src/protocol.mjs` | MCP schemas, validation, protocol responses, image blocks. |
| `bin/opencomputer.mjs` | stdio server and diagnostic CLI. |
| `tests/` | Client/protocol tests, disposable native fixture, live integration, benchmark audit proxy. |
| `scripts/` | Build, checks, packaging, and AI benchmark runner. |
| `docs/` | Installation, API, acceptance checks, benchmark evidence. |

Keep the accessibility-first boundary explicit. Never add a hidden foreground fallback to fix an unsupported control. New actions must report dispatch truthfully and require re-observation. Keep potentially sensitive app payloads out of diagnostic logs.

The helper runs an accessory AppKit application with a main event loop. Input is read off the main thread and dispatched serially onto the main actor, keeping animations and focus observers alive between requests. Build scripts compile all `native/*.swift` files. The helper initializes AppKit before ScreenCaptureKit. Without that initialization, capture from a command-line process can fail with `CGS_REQUIRE_INIT`. The real integration test captures a PNG through the production helper and guards this failure.

## Checks and packaging

```sh
npm run fixture:build
npm run test:integration
npm run test:activity
npm run test:ui
npm run test:focus
npm run package
```

Integration needs a logged-in macOS desktop, Accessibility, and Screen Recording. It uses only a disposable test app. The focus suite deliberately activates that fixture once to verify the guard. The UI suite injects pointer positions into the production hover calculation without moving the user’s mouse, and captures only its own annotation windows. Set `OPENCOMPUTER_UI_OUTPUT` to choose its output directory. Do not run integration and AI benchmarks concurrently: they share the fixture bundle ID. User interaction can change foreground focus while a run is measured; repeat interrupted runs and record the reason.

Packaging compiles both `arm64` and `x86_64`, combines them with `lipo`, ad-hoc signs the universal binary, and copies an explicit runtime file list into a ZIP. It also exports a source archive from the current Git commit and produces checksums. Commit tested source before packaging so the source ZIP matches the release. Native binaries and local AI transcripts stay out of Git.

CI runs Node tests/checks on Linux and builds each Mac architecture on macOS. It does not claim interactive accessibility validation on hosted runners. Real desktop and AI-client results belong in the benchmark report with environment, date, outcome, and limitations.

## Sources

- [Apple AXUIElement](https://developer.apple.com/documentation/applicationservices/axuielement): accessibility attributes and actions.
- [Apple nonactivatingPanel](https://developer.apple.com/documentation/appkit/nswindow/stylemask/nonactivatingpanel): panels that do not activate their owning app.
- [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit): app/window-scoped capture.
- [ChatGPT Computer Use](https://learn.chatgpt.com/docs/computer-use): the user-facing workflow that inspired this project; not an implementation dependency.
- Installed Claude/Grok CLI help and Grok's bundled README were used to validate client invocation on the versions recorded in the benchmark report.

No private ChatGPT code, authentication material, runtime binaries, or OS permission database modifications are included.
