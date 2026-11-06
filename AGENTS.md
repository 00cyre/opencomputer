# Working on OpenComputer

Read `docs/DEVELOPMENT.md` before changing native behavior, and `docs/API.md` before changing tool schemas or snapshot semantics. For permissions, image handling, or new actions, read `SECURITY.md`.

Run `npm test` and `npm run check` for JavaScript/docs changes. Compile native changes on macOS. Exercise changed UI behavior through `npm run test:integration` when the desktop permissions are available; otherwise record the missing validation.

Use the disposable fixture for live tests. Run live suites serially. Keep benchmark transcripts, credentials, local configuration, and user app screenshots out of Git and release archives. Publish only reviewed aggregate results.

Preserve app scoping and fresh-snapshot checks. Report unsupported background actions explicitly. Document observed compatibility and remaining limitations beside the public API.
