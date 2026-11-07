# Security model

OpenComputer is a local automation capability. An authorized agent can click controls that cause real external changes. The MCP client must obtain task authorization, distinguish instructions from untrusted app content, and require approval for consequential actions. The server does not understand business intent and cannot enforce a complete approval policy.

## Boundaries

- Empty app allowlist by default; exact bundle IDs checked inside the native helper on every app operation. The host can explicitly set `OPENCOMPUTER_APPS=*` for all running apps; operations remain scoped to one requested bundle ID/process. The agent cannot change this setting through an MCP tool.
- Existing, single app process required. Snapshots are scoped to that process, bundle ID, generation, and a 60-second lifetime.
- Snapshots are consumed before mutations, including failed dispatches. Stale references fail closed.
- Accessibility secure text values are redacted and actions on secure text fields are rejected. Ordinary fields and screenshots are not automatically scrubbed.
- Window captures are selected from windows owned by the allowed process. No whole-display screenshot command.
- No listener, remote endpoint, automatic app launch, administrator privilege, global event-tap fallback, clipboard-based typing, or locked-screen bypass.
- Node request timeouts close the native connection. Partial effects may already have occurred; observe before retrying.

The allowlist is not a sandbox against the calling process. A host with arbitrary shell access can start another helper with a different allowlist or automate macOS independently. Use your agent's tool permissions to restrict it. Local binary/config integrity and macOS permissions remain trust boundaries.

Raw keyboard injection, accessibility focus setters, and menu-show/confirm/cancel actions are disabled. Text is replaced through semantic values/selected ranges. Before each mutation, a window-aware check reserves focused editors, protects held mouse gestures, and checks held keys, recent input, and pointer proximity. It uses current OS state and event ages, not recorded keystrokes or input history. Unavailable required state blocks writes. `USER_BUSY` means no dispatch and no queued replay; clients must re-observe before retrying. The delay hint is not a reservation or authorization. Annotation windows cannot become key/main, ignore mouse events, and never reposition the user’s pointer.

Applications can still activate themselves in response to semantic actions. The guard watches app activation and focused window/control notifications during dispatch, compares focus before/after, and waits 150 ms before finishing. A detected change blocks further writes for that connection. It never restores focus, since the change may have been the user’s choice. App notifications can be absent and activation can be delayed; this is not continuous proof of isolation or a guarantee against the first focus change. A successful dispatch is never proof that a task completed.

Input silence cannot establish that a user has stopped reading. Preflight checks and dispatch are not atomic, and browser tabs share a window for conflict detection. These limitations cannot be fixed by silently falling back to global input or a different computer-control tool.

Agent labels and installed icons are display metadata, not verified identities. Session-stacking records contain only PID, timestamp, and expansion state in a per-user temporary directory. The visuals are not a security boundary; hosts can disable them.

## Reporting

Use GitHub's private vulnerability reporting if enabled on the repository. Otherwise contact the maintainer through their GitHub profile before posting exploit details publicly. Include version, affected boundary, minimal reproduction with disposable data, and expected/actual behavior. Never include API keys, tokens, private screenshots, or authentication logs.
