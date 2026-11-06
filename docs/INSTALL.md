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

## Troubleshooting

| Error | Action |
| --- | --- |
| `HELPER_UNAVAILABLE` | Build the source or restore `build/opencomputer-native` from the runtime ZIP. |
| `APP_NOT_ALLOWED` | Add the exact bundle ID to `OPENCOMPUTER_APPS` and restart the server. |
| `APP_NOT_RUNNING` | Open exactly one instance of the target app yourself. |
| `ACCESSIBILITY_REQUIRED` | Approve the launching host and restart it. |
| `SCREEN_RECORDING_REQUIRED` | Approve capture permission or use accessibility-only tools. |
| `STALE_SNAPSHOT` | Observe again. IDs are scoped to one process, app, and snapshot. |
| `AX_ERROR` | Re-observe; the control may not support that action. Use the returned action list. |
| `USER_BUSY` | The user recently typed/clicked in the foreground target. Wait, observe, and retry when idle. |
| `FOCUS_UNSAFE` | Use semantic controls or `setValue`; raw key injection and focus-setting actions are disabled. |
| `FOCUS_CHANGED` / `FOCUS_PROTECTION_BLOCKED` | Inspect the outcome; a dispatched action may have completed. Further writes are paused until reconnect. Focus is never restored automatically. |
| `TIMEOUT` | Create/reconnect the server, then re-observe. The action may have partially executed. |
| `selectionRequired` | Choose a returned window ID, then call `screenshot` again. |

To stop access, stop the MCP server or remove its configuration. Revoke macOS permissions if desired. Uninstall by deleting the extracted folder. There is no daemon, launch agent, system extension, or remote account to remove.
