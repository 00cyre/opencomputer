<p align="center"><img src="docs/assets/hero.svg" alt="OpenComputer — let your agent work. Keep your desktop." width="100%"></p>

<p align="center"><a href="https://github.com/00cyre/opencomputer/releases/download/v0.2.1/OpenComputer-0.2.1-macOS.zip"><img src="docs/assets/download.svg" alt="Download OpenComputer for macOS" width="320"></a></p>

<p align="center"><a href="#watch-it-work">Watch demo</a> · <a href="#get-started">Get started</a> · <a href="docs/INSTALL.md">Connect your agent</a> · <a href="docs/API.md">API reference</a> · <a href="docs/BENCHMARKS.md">Claude &amp; Grok benchmarks</a></p>

<p align="center">
<a href="https://github.com/00cyre/opencomputer/actions/workflows/ci.yml"><img src="https://github.com/00cyre/opencomputer/actions/workflows/ci.yml/badge.svg" alt="Build and tests"></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-526943" alt="MIT license"></a>
<img src="https://img.shields.io/badge/macOS-14%2B-334b35" alt="macOS 14 or later">
<img src="https://img.shields.io/badge/Node-22%2B-334b35" alt="Node 22 or later">
</p>

**OpenComputer gives AI agents a local interface for working with Mac apps in the background.** Discover apps, read their accessibility trees, change controls, and capture a specific window. Connect it to an MCP client or use the JavaScript API directly. No OpenComputer account, API key, cloud service, or npm dependencies.

## Watch it work

A 27-second showcase with narration, sound effects, and music. Click the preview to watch with sound.

[![OpenComputer: hover details and smooth ghost cursor](docs/assets/showcase.gif)](https://github.com/00cyre/opencomputer/releases/download/v0.2.1/OpenComputer-Showcase-16x9.mp4)

[**Watch with sound · 27 seconds**](https://github.com/00cyre/opencomputer/releases/download/v0.2.1/OpenComputer-Showcase-16x9.mp4) · [Vertical social cut](https://github.com/00cyre/opencomputer/releases/download/v0.2.1/OpenComputer-Showcase-9x16.mp4) · [Editable Hyperframes projects](https://github.com/00cyre/opencomputer/releases/download/v0.2.1/OpenComputer-Showcase-Hyperframes.zip)

Actual native UI with choreographed demo actions. [Recording details](docs/SHOWCASE.md).

## Background control, visible activity

Inspired by the app-scoped workflow of [ChatGPT Computer Use](https://learn.chatgpt.com/docs/computer-use). This is an independent implementation using public macOS APIs. It is **not a drop-in replacement for OpenAI's private runtime**, and it does not provide ChatGPT's approval system or locked-Mac access.

| For your agent | For your desktop |
| :--- | :--- |
| Ten MCP tools with explicit input schemas. | Only exact bundle IDs you allow can be inspected or controlled. |
| Structured accessibility snapshots with element IDs. | Semantic actions do not deliberately activate apps or move the global pointer. |
| Window screenshots, including covered windows. | Captures are scoped to the selected app's window. |
| Native actions with verification metadata. | Focus changes pause further writes; raw keyboard injection is disabled. |
| Agent identity and current action. | Three animated dots expand on hover; a ghost cursor marks the visible target. |

## Get started

**macOS 14+ · Node.js 22+ · Apple Silicon or Intel**

1. **[Download the runtime ZIP](https://github.com/00cyre/opencomputer/releases/download/v0.2.1/OpenComputer-0.2.1-macOS.zip)** and extract it somewhere permanent. It includes the universal native helper; Node.js is installed separately.
2. In that folder, run `node bin/opencomputer.mjs doctor`. Approve Accessibility and Screen Recording for the launching host in **System Settings → Privacy & Security**, then restart that host if needed. [Permission help](docs/INSTALL.md#macos-permissions).
3. Add the MCP server to your agent using its documented configuration. Start with one app you intend to automate:

```json
{
  "mcpServers": {
    "opencomputer": {
      "command": "/absolute/path/to/node",
      "args": ["/absolute/path/to/opencomputer/bin/opencomputer.mjs", "serve"],
      "env": { "OPENCOMPUTER_APPS": "com.apple.TextEdit" }
    }
  }
}
```

Ask your agent to inspect a disposable TextEdit document. Have it read the current state before each action and check the result afterward. **Empty allowlist means no app access.** Use `node bin/opencomputer.mjs apps` to find bundle IDs.

> **Developer runtime:** the native helper is ad-hoc signed, not Apple-notarized. macOS may block downloaded binaries. Follow the normal macOS approval flow or [build from source](docs/DEVELOPMENT.md); OpenComputer never disables Gatekeeper. This release is a developer runtime, not a graphical installer.

[Checksums](https://github.com/00cyre/opencomputer/releases/download/v0.2.1/SHA256SUMS.txt) · [Claude and Grok setup](docs/INSTALL.md) · [Release notes](CHANGELOG.md)

## See what your agent is doing

A small **three-dot animation** sits at the top right while an agent has an app in use. Hover to expand it into **AI icon → app icon**, the agent/app names, current window or browser-tab title, and latest action. Move away to collapse it. Multiple agents get separate, stacked indicators. Icons come from installed apps.

![Expanded activity indicator from the live macOS UI test](docs/assets/activity-expanded.png)

The colored ghost cursor eases between targets and gently floats while idle. It appears at the agent’s target while that part of its window is visible. It follows window movement and disappears when covered, hidden, or minimized. Both overlays stay above ordinary windows, pass clicks through, and cannot become the active window. They never move your real pointer. The agent calls `release` when finished to remove them. [Behavior and settings](docs/ACTIVITY.md).

## A familiar interface

```js
import { createComputer } from './src/computer.mjs';

const computer = createComputer({ apps: ['com.apple.TextEdit'], agent: 'Claude' });
try {
  const app = computer.getApp('com.apple.TextEdit');
  const state = await app.getAXState();
  const field = state.nodes.find(node => node.settable && node.role === 'AXTextArea');
  if (!field) throw new Error('No writable text area in this window');
  await app.setValue(field.id, 'Hello from OpenComputer');
  console.log(await app.getAXState()); // verify the result
} finally {
  computer.close();
}
```

Snapshots expire after 60 seconds and are consumed by actions. Stale IDs fail with a clear error. Screenshots can return a window-selection list; select the intended window and request it again. [Full API](docs/API.md).

## What works today

- **Background semantic control:** reading accessibility trees, `AXPress`, writable values, and supported secondary actions.
- **Window capture:** ScreenCaptureKit captures a selected window without capturing the whole desktop.
- **Agent connections:** local MCP over stdio, plus a JavaScript client with serialized requests and bounded timeouts.
- **Text and scrolling:** semantic value/selection replacement and accessibility page scrolling, where supported. Raw keyboard injection is disabled.
- **Activity and focus protection:** hover-to-expand dots, visible-target ghost cursor, recent-user-input checks, and a session pause after detected focus changes.

**Not implemented:** arbitrary coordinate clicks/dragging, browser DOM automation, Windows/Linux, launching apps, and locked-screen operation. Canvas-only controls, minimized windows, secure fields, and apps with incomplete accessibility support may not work. OpenComputer never activates an app, sets keyboard focus, or restores the foreground window. An app can still activate itself in response to a semantic action; public macOS APIs cannot prevent every such transition. A detected change returns `FOCUS_CHANGED` and blocks further writes until reconnect. [Compatibility and acceptance checks](docs/TESTING.md).

## Quietly local

The server opens no network listener and sends no telemetry. It does not read browser profiles, store screenshots, or use the clipboard for text insertion. Your AI client may send tool output and screenshots to its model provider; that client's data policies apply. Accessible password values are redacted, but screenshots and ordinary text fields may still contain secrets.

The app allowlist is a process-level control, not a sandbox against an agent that can execute arbitrary shell commands. Your MCP client remains responsible for user consent, prompt-injection handling, and approval before consequential actions. [Privacy](PRIVACY.md) · [Security model](SECURITY.md)

## Tested with Claude and Grok

Both installed clients completed the same native fixture task through MCP: fill a field, enable an option, submit once, verify, and capture a window. Each used 11 tool calls with zero errors, preserved focus, displayed the right agent identity, and removed the overlays with `release`. The AI results are from v0.2.0. The v0.2.1 motion update adds nine native animation checks; live activity and UI checks also pass. [Results, methodology, and limitations](docs/BENCHMARKS.md).

## Build, test, contribute

```sh
npm run build              # Swift helper, macOS only
npm test                   # protocol and client behavior
npm run check              # syntax, documentation links, release metadata
npm run fixture:build      # disposable native benchmark app
npm run test:integration   # real accessibility actions + window screenshot
npm run test:activity      # two agents, visibility, cleanup
npm run test:ui            # animated dots, hover, actual panel screenshots
npm run test:focus         # disposable app deliberately changes focus
```

[Developer guide](docs/DEVELOPMENT.md) · [Test coverage](docs/TESTING.md) · [Reproduce the AI benchmark](docs/BENCHMARKS.md) · [Report an issue](https://github.com/00cyre/opencomputer/issues)

---

<p align="center">Let your agent work. Keep your desktop.<br><a href="LICENSE">MIT licensed</a> · <a href="https://github.com/00cyre">00cyre</a></p>
