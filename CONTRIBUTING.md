# Contributing to OpenComputer

Thanks for taking a look. OpenComputer is a small project, and the most useful help right now is evidence from real Macs: which apps work, which don't, and why.

## Ways to help

- **Tell us how an app behaves.** Open an [app compatibility report](https://github.com/00cyre/opencomputer/issues/new?template=app-compatibility.yml) with the app, its version, your macOS version, and what worked or failed (observe, click, typing, keys, scroll, screenshot). Reports for popular apps help everyone.
- **Report a bug.** Include `node bin/opencomputer.mjs doctor` output, the error code you got, and the smallest steps that reproduce it. Use disposable data: never paste tokens, private screenshots, or real message contents.
- **Send a pull request.** Small, focused changes are easiest to review. For anything that changes tool schemas, permissions, or how actions are delivered, open an issue first so we can agree on the approach.

## Set up

You need macOS 14 or later, the Xcode command line tools (Swift), and Node.js 22 or later. There are no npm dependencies.

```sh
git clone https://github.com/00cyre/opencomputer.git
cd opencomputer
npm run build    # compiles and ad-hoc signs the Swift helper
npm test         # protocol and client tests (these also run on Linux)
npm run check    # syntax, local documentation links, release metadata
```

Live tests drive a disposable fixture app and need a logged-in, unlocked desktop with Accessibility and Screen Recording approved for the app that launches them. Run them one at a time:

```sh
npm run fixture:build
npm run test:integration
npm run test:guard
npm run test:activity
npm run test:ui
```

[Developer guide](docs/DEVELOPMENT.md) explains the layout. [Testing and acceptance](docs/TESTING.md) lists what each suite proves.

## Design rules

These keep the project's promises to the person at the Mac. A change that breaks one needs an issue and a discussion first.

- **Your pointer and focus are not ours.** Clicks are accessibility actions and keys are posted to the target process only. No synthetic mouse events and no hidden foreground fallback to make an unsupported control work.
- **Public macOS APIs only.**
- **App scoping stays default-deny.** An empty allowlist means no access.
- **Act only on what was observed.** Keep the fresh-snapshot and changed-target checks; new actions must require re-observation.
- **Report what really happened.** Results must say truthfully whether anything was dispatched. Unsupported background actions are refused with a clear error, never faked.
- **Keep secrets out of logs.** Typed text and values are recorded as lengths; app payloads stay out of diagnostics.
- **No npm dependencies** in the runtime.

## Pull requests

- Add or update tests with the change. JavaScript changes need `npm test` and `npm run check` to pass; native changes must compile on macOS (CI builds both arm64 and x86_64).
- Update `docs/API.md` when a tool, option, or error changes, and add a line to `CHANGELOG.md` under "Unreleased".
- In the description, say what you validated on a real Mac and what you couldn't. That's normal for UI work, and it helps the review.
- Keep benchmark transcripts, credentials, local configuration, and screenshots of your own apps out of commits.

## Good places to start

- Compatibility notes for an app you use every day, with what fails and the error code.
- Richer accessibility verbs and hover substitutes for controls that only respond to hover.
- Turning the action log into replayable scripts (record and replay).
- Smaller outlines for very large windows.
- Packaging: an installer or a one-step setup for common MCP clients.

## Security

Please report vulnerabilities privately as described in [SECURITY.md](SECURITY.md), not in a public issue.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
