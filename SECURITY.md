# Security model

OpenComputer is a local automation capability. An authorized agent can click controls that cause real external changes. The MCP client must obtain task authorization, distinguish instructions from untrusted app content, and require approval for consequential actions. The server does not understand business intent and cannot enforce a complete approval policy.

## Boundaries

- Empty app allowlist by default; exact bundle IDs checked inside the native helper on every app operation.
- Existing, single app process required. Snapshots are scoped to that process, bundle ID, generation, and a 60-second lifetime.
- Snapshots are consumed before mutations, including failed dispatches. Stale references fail closed.
- Accessibility secure text values are redacted and actions on secure text fields are rejected. Ordinary fields and screenshots are not automatically scrubbed.
- Window captures are selected from windows owned by the allowed process. No whole-display screenshot command.
- No listener, remote endpoint, automatic app launch, administrator privilege, global event-tap fallback, clipboard-based typing, or locked-screen bypass.
- Node request timeouts close the native connection. Partial effects may already have occurred; observe before retrying.

The allowlist is not a sandbox against the calling process. A host with arbitrary shell access can start another helper with a different allowlist or automate macOS independently. Use your agent's tool permissions to restrict it. Local binary/config integrity and macOS permissions remain trust boundaries.

Process-targeted keyboard input is experimental, and applications can activate themselves in response to semantic actions. `focusChanged` is sampled before/after dispatch, not continuous proof of isolation. Unsupported controls are errors. A successful event dispatch is never a guarantee that a task completed.

## Reporting

Use GitHub's private vulnerability reporting if enabled on the repository. Otherwise contact the maintainer through their GitHub profile before posting exploit details publicly. Include version, affected boundary, minimal reproduction with disposable data, and expected/actual behavior. Never include API keys, tokens, private screenshots, or authentication logs.
