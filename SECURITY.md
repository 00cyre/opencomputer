# Security model

OpenComputer is a local automation capability. An authorized agent can click controls that cause real external changes. The MCP client must obtain task authorization, distinguish instructions from untrusted app content, and require approval for consequential actions. The server does not understand business intent and cannot enforce a complete approval policy.

## Boundaries

- Empty app allowlist by default; exact bundle IDs checked inside the native helper on every app operation. The host can explicitly set `OPENCOMPUTER_APPS=*` for all running apps; operations remain scoped to one requested bundle ID/process. The agent cannot change this setting through an MCP tool.
- Snapshots are scoped to one process and bundle ID and expire 5 minutes after their last use. A full observe replaces the previous snapshot. Stale references fail closed.
- Accessibility secure text values are redacted and actions on secure text fields are rejected. Ordinary fields and screenshots are not automatically scrubbed.
- Window captures are selected from windows owned by the allowed process. No whole-display screenshot command.
- No listener, remote endpoint, administrator privilege, global event-tap fallback, synthetic mouse events, clipboard-based typing, or locked-screen bypass. `open` launches only allowlisted apps and accepts only `http`, `https`, and `file` URLs.
- Node request timeouts close the native connection. Partial effects may already have occurred; observe before retrying.

The allowlist is not a sandbox against the calling process. A host with arbitrary shell access can start another helper with a different allowlist or automate macOS independently. Use your agent's tool permissions to restrict it. Local binary/config integrity and macOS permissions remain trust boundaries.

Key events are posted to the allowlisted target process only (`CGEvent.postToPid`), never to the login session, and carry their own modifier state. They reach whatever control has that app's own focus, so an agent with key access can drive anything in the app that a keyboard can, including shortcuts. Keys are refused while the app's focus is in a secure text field. `AXShowMenu` and `AXRaise` stay disabled. Before each action, a window-aware check protects editors the person is typing in, held mouse gestures and keys, recent input, and pointer proximity. It uses current OS state and event ages, not recorded keystrokes or input history. `USER_BUSY` means no dispatch and no queued replay. Annotation windows cannot become key/main, ignore mouse events, and never reposition the user’s pointer.

Applications can still activate themselves in response to an action. The guard watches app activations during dispatch and for 1.5 seconds afterwards. An activation with no recent click, modifier, or key press from the person is treated as app-initiated, and the helper re-activates the app the person was in. This is the one case where the helper changes the foreground app, and it only ever returns to the previous one. A switch the person makes is left alone. The heuristic can misjudge: a self-activation that coincides with the person's own input is left in place, and a restored app can flash behind the other for a moment. A successful dispatch is never proof that a task completed.

Input silence cannot establish that a user has stopped reading. Preflight checks and dispatch are not atomic, and browser tabs share a window for conflict detection. These limitations cannot be fixed by silently falling back to global input or a different computer-control tool.

Agent labels and installed icons are display metadata, not verified identities. Session-stacking records contain only PID, timestamp, and expansion state in a per-user temporary directory. The visuals are not a security boundary; hosts can disable them.

## Reporting

Use GitHub's private vulnerability reporting if enabled on the repository. Otherwise contact the maintainer through their GitHub profile before posting exploit details publicly. Include version, affected boundary, minimal reproduction with disposable data, and expected/actual behavior. Never include API keys, tokens, private screenshots, or authentication logs.
