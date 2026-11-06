<p align="center"><img src="docs/assets/hero.svg" alt="OpenComputer — let your agent work. Keep your desktop." width="100%"></p>

<p align="center"><a href="https://github.com/00cyre/opencomputer/releases/download/v0.1.0/OpenComputer-0.1.0-macOS.zip"><img src="docs/assets/download.svg" alt="Download OpenComputer for macOS" width="320"></a></p>

<p align="center"><a href="#get-started">Get started</a> · <a href="docs/INSTALL.md">Connect your agent</a> · <a href="docs/API.md">API reference</a> · <a href="docs/BENCHMARKS.md">Claude &amp; Grok benchmarks</a></p>

<p align="center">
<a href="https://github.com/00cyre/opencomputer/actions/workflows/ci.yml"><img src="https://github.com/00cyre/opencomputer/actions/workflows/ci.yml/badge.svg" alt="Build and tests"></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-526943" alt="MIT license"></a>
<img src="https://img.shields.io/badge/macOS-14%2B-334b35" alt="macOS 14 or later">
<img src="https://img.shields.io/badge/Node-22%2B-334b35" alt="Node 22 or later">
</p>

**OpenComputer gives AI agents a local interface for working with Mac apps in the background.** Discover apps, read their accessibility trees, change controls, and capture a specific window. Connect it to an MCP client or use the JavaScript API directly. No OpenComputer account, API key, cloud service, or npm dependencies.

Inspired by the app-scoped workflow of [ChatGPT Computer Use](https://learn.chatgpt.com/docs/computer-use). This is an independent implementation using public macOS APIs. It is **not a drop-in replacement for OpenAI's private runtime**, and it does not provide ChatGPT's approval system or locked-Mac access.

| For your agent | For your desktop |
| :--- | :--- |
| Ten MCP tools with explicit input schemas. | Only exact bundle IDs you allow can be inspected or controlled. |
| Structured accessibility snapshots with element IDs. | Semantic actions do not deliberately activate apps or move the global pointer. |
| Window screenshots, including covered windows. | Captures are scoped to the selected app's window. |
| Native actions with verification metadata. | Each action reports foreground focus before and after. |

## Get started

**macOS 14+ · Node.js 22+ · Apple Silicon or Intel**

1. **[Download the runtime ZIP](https://github.com/00cyre/opencomputer/releases/download/v0.1.0/OpenComputer-0.1.0-macOS.zip)** and extract it somewhere permanent. It includes the universal native helper; Node.js is installed separately.
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

> **First release:** the native helper is ad-hoc signed, not Apple-notarized. macOS may block downloaded binaries. Follow the normal macOS approval flow or [build from source](docs/DEVELOPMENT.md); OpenComputer never disables Gatekeeper. This release is a developer runtime, not a graphical installer.

[Checksums](https://github.com/00cyre/opencomputer/releases/download/v0.1.0/SHA256SUMS.txt) · [Claude and Grok setup](docs/INSTALL.md) · [Release notes](CHANGELOG.md)

## A familiar interface

```js
import { createComputer } from './src/computer.mjs';

const computer = createComputer({ apps: ['com.apple.TextEdit'] });
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
- **Keyboard and scrolling:** process-targeted typing/keys and accessibility page scrolling. These depend on app support; keyboard input is experimental. A dispatched event is not proof that the app handled it.

**Not implemented:** arbitrary coordinate clicks/dragging, browser DOM automation, Windows/Linux, launching apps, and locked-screen operation. Canvas-only controls, minimized windows, secure fields, and apps with incomplete accessibility support may not work. Some controls can activate their own app; check `focusChanged` and stop if that disrupts your work. [Compatibility and acceptance checks](docs/TESTING.md).

## Quietly local

The server opens no network listener and sends no telemetry. It does not read browser profiles, store screenshots, or use the clipboard for text insertion. Your AI client may send tool output and screenshots to its model provider; that client's data policies apply. Accessible password values are redacted, but screenshots and ordinary text fields may still contain secrets.

The app allowlist is a process-level control, not a sandbox against an agent that can execute arbitrary shell commands. Your MCP client remains responsible for user consent, prompt-injection handling, and approval before consequential actions. [Privacy](PRIVACY.md) · [Security model](SECURITY.md)

## Tested with Claude and Grok

Both installed clients completed the same native fixture task through MCP: fill a field, enable an option, submit once, verify, and capture a window. Each used 10 tool calls with zero errors; all mutations ran in the background without changing focus. Eight unit tests and thirteen real macOS assertions also passed. [Results, methodology, and limitations](docs/BENCHMARKS.md).

## Build, test, contribute

```sh
npm run build              # Swift helper, macOS only
npm test                   # protocol and client behavior
npm run check              # syntax, documentation links, release metadata
npm run fixture:build      # disposable native benchmark app
npm run test:integration   # real accessibility actions + window screenshot
```

[Developer guide](docs/DEVELOPMENT.md) · [Test coverage](docs/TESTING.md) · [Reproduce the AI benchmark](docs/BENCHMARKS.md) · [Report an issue](https://github.com/00cyre/opencomputer/issues)

---

<p align="center">Let your agent work. Keep your desktop.<br><a href="LICENSE">MIT licensed</a> · <a href="https://github.com/00cyre">00cyre</a></p>
