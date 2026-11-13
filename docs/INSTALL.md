# Install and connect OpenComputer

Requires macOS 14+ and Node 22+. OpenComputer is a local tool provider; your existing AI client supplies the model and authentication.

## Runtime ZIP

Download the macOS ZIP from [Releases](https://github.com/00cyre/opencomputer/releases), check it against `SHA256SUMS.txt` with `shasum -a 256`, and extract it to a stable folder. The ZIP contains the JavaScript server and a universal Apple Silicon/Intel helper. Node is not bundled.

Run these commands inside the extracted folder:

```sh
node bin/opencomputer.mjs doctor
node bin/opencomputer.mjs apps
```

No `npm install` is needed. For source checkouts, run `npm run build` first; that requires Apple's Command Line Tools (`xcode-select --install`).

## macOS permissions

Open **System Settings → Privacy & Security**:

- **Accessibility:** allow the app launching the helper, such as your terminal or AI desktop client. macOS may attribute permission to the host or the helper. The exact entry depends on how it is launched.
- **Screen Recording / Screen & System Audio Recording:** allow the same host if you want window screenshots.

Restart the host, then run `doctor` from that host's environment. Its booleans are authoritative for that process. The helper checks permission but does not approve prompts, edit the TCC database, request administrator access, or install a background login item.

If macOS blocks the ad-hoc signed download, use the normal **Privacy & Security → Open Anyway** approval after reviewing the source, or build locally. Never disable Gatekeeper. Rebuilding changes the binary identity and can invalidate prior permission; stop clients before rebuilding and re-check `doctor` afterward.

## Claude Code

Use the `mcpServers` JSON example in the README, replacing both paths with absolute paths. Test the configuration for one invocation:

```sh
claude --strict-mcp-config --mcp-config /absolute/path/to/mcp.json
```

Or register it with Claude's own MCP configuration command/UI. For Claude Desktop, merge the `opencomputer` entry into the existing `mcpServers` object in its developer configuration, then restart Claude. Preserve your other server entries. Client UI and permission settings vary by version.

## Grok Build

Grok supports stdio MCP servers. From the intended project:

```sh
grok mcp add --scope project opencomputer \
  -e OPENCOMPUTER_APPS=com.apple.TextEdit \
  -- /absolute/path/to/node /absolute/path/to/opencomputer/bin/opencomputer.mjs serve
```

Trust the project through Grok's own flow before running it. Untrusted project servers are skipped. If using a persistent Grok leader, reconnect/restart that session after changing MCP configuration. Check `grok mcp list` and `grok mcp doctor` before asking the model to use it. The benchmark script uses an isolated configuration and leader so existing sessions are not changed.

## Other MCP clients

Configure a stdio command using the same executable, arguments, and environment. Protocol negotiation supports the MCP `2024-11-05` baseline. Tool output includes native image content blocks; select a vision-capable model for screenshot interpretation. No HTTP/SSE server is exposed.

## Activity indicators

The three-dot animation and ghost cursor are enabled by default. Hover the dots for agent → app, window/tab title, and current action. Identity comes from the MCP client name; optionally add `OPENCOMPUTER_AGENT` to the server environment to choose a display label. `OPENCOMPUTER_OVERLAY=0` disables both visuals while keeping focus protection. Reconnect after updating the runtime or settings. [Details and screenshots](ACTIVITY.md).

The open card has **Take over**, which pauses the agent until you press **Resume**. To approve consequential actions before they run, add `OPENCOMPUTER_CONFIRM` to the server environment: `sensitive` asks before buttons such as Send, Pay, or Delete and before Return; a bundle ID asks before every action in that app; `all` asks before everything. Combine them with commas, e.g. `"OPENCOMPUTER_CONFIRM": "sensitive,com.apple.mail"`. [How approvals work](ACTIVITY.md#approve-before-it-acts).

## Direct access to your Mac

Set `OPENCOMPUTER_APPS` to `*` to explicitly allow all running apps, or keep a comma-separated list of exact bundle IDs. Add `:read` to any entry for read-only access, for example `*:read,com.apple.TextEdit` to let the agent read every app but act only in TextEdit, or `:click` to allow clicks and scrolling but no typing or keys. With `*`, the app your agent runs in (its terminal, editor, or chat app) stays read-only unless you list it by name. In the JavaScript client, use `apps: ['*']`. Each operation still targets a specific app and its own windows. Existing app/browser logins remain in place; there is no separate desktop, VM, profile copy, or new login flow.

For Codex, register the local stdio server with its installed CLI:

```sh
codex mcp add opencomputer --env 'OPENCOMPUTER_APPS=*' -- \
  /absolute/path/to/node /absolute/path/to/opencomputer/bin/opencomputer.mjs serve
```

Restart/reconnect your AI client after changing its configuration. Configure its instructions to use OpenComputer for computer control, wait and re-observe on `USER_BUSY`, stop on `PAUSED_BY_USER`, and report unsupported actions instead of falling back to focus-stealing tools. Registering the server does not remove other installed plugins or hot-load tools into an existing conversation. Accessibility remains app-dependent, and a running browser's tabs share the same window for interaction checks.

## Troubleshooting

| Error | Action |
| --- | --- |
| `HELPER_UNAVAILABLE` | Build the source or restore `build/opencomputer-native` from the runtime ZIP. |
| `APP_NOT_ALLOWED` | Add the exact bundle ID to `OPENCOMPUTER_APPS` and restart the server. |
| `APP_NOT_RUNNING` | Call `open`, or start the app yourself. With several instances, pass `pid`. |
| `ACCESSIBILITY_REQUIRED` | Approve the launching host and restart it. |
| `SCREEN_RECORDING_REQUIRED` | Approve capture permission or use accessibility-only tools. |
| `STALE_SNAPSHOT` | Observe again. IDs last until the next full observe of that app, or 5 minutes. |
| `AX_ERROR` | Re-observe; the control may not support that action. Use the returned action list. |
| `USER_BUSY` | You are working in that same window and did not pause within `waitMs`. Nothing was dispatched or queued. Retry after `details.retryAfterMs`, or work in another window. |
| `PAUSED_BY_USER` | You pressed Take over. Press Resume on the activity card to hand control back. |
| `APPROVAL_PENDING` / `APPROVAL_DENIED` | The action is waiting for, or was refused by, your answer on the activity card. |
| `APPROVAL_UNAVAILABLE` | `OPENCOMPUTER_CONFIRM` is set but `OPENCOMPUTER_OVERLAY=0` hides the card; enable one or drop the other. |
| `FOCUS_UNSAFE` | `AXShowMenu` and `AXRaise` open a menu at the pointer or raise a window. Use a specific control. |
| `UNSUPPORTED_ACTION` / `UNSUPPORTED_TARGET` | The control exposes nothing pressable or scrollable. Try a nearby element, `pressKey`, or `clickPoint`. |
| `TIMEOUT` | Create/reconnect the server, then re-observe. The action may have partially executed. |
| `selectionRequired` | Choose a returned window ID, then call `screenshot` again. |

To stop access, stop the MCP server or remove its configuration. Revoke macOS permissions if desired. Uninstall by deleting the extracted folder. There is no daemon, launch agent, system extension, or remote account to remove.
