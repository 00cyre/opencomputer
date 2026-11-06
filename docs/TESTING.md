# Testing and acceptance

Tests make different claims. Unit tests do not prove live app behavior; the native fixture does not prove compatibility with every Mac app.

## Automated checks

`npm test` exercises MCP negotiation, tool schemas, error propagation, screenshot blocks, native process lifecycle, request serialization, missing-helper behavior, and fail-closed timeouts. It uses a fake helper only for the process/client boundary.

`npm run check` validates JavaScript syntax, repository documentation links, required files, and version consistency. `npm run build` compiles and signs the actual native helper.

## Real macOS integration

```sh
npm run build
npm run fixture:build
npm run test:integration
```

Run on an unlocked Mac with Accessibility and Screen Recording already approved. The test launches a disposable AppKit fixture (launched as an accessory app to avoid taking focus at startup) and uses the production native helper to:

1. Verify the fixture exists and Accessibility is available.
2. Reject an app outside the allowlist.
3. Read a writable text control and replace its value in the background.
4. Reject reuse of the consumed snapshot.
5. Read back the changed value.
6. Click a checkbox and submit button.
7. Verify the fixture's independent on-disk state: expected token, checkbox on, exactly one submit.
8. Check foreground focus during actions and submission.
9. Select the fixture's actual window and validate its captured PNG signature.

The script reports 13 assertions. Screenshots are kept only if `OPENCOMPUTER_TEST_IMAGE` names an output path. The fixture's own result file is outside the agent's task and is deleted after the integration test.

## AI-client benchmark

See [benchmarks](BENCHMARKS.md). Each AI must operate through the OpenComputer MCP server, with no shell/file bypass. The fixture state and audit proxy establish success independently of the model's final response.

## Manual compatibility checks

Record app version and macOS version for each result:

- [ ] Standard AppKit app: set a disposable field, press a button, verify values, and check focus.
- [ ] Electron app: inspect tree quality and confirm semantic controls exist before mutation.
- [ ] Background keyboard: target a disposable field, type Unicode text, use a key chord, and verify both the target and foreground app are unaffected unexpectedly.
- [ ] Scrolling: call a supported accessibility scroll action and verify content changed.
- [ ] Screen capture: select among multiple windows, test a covered window, and confirm no unrelated app content appears.
- [ ] Secure field: value is redacted, `settable` false, mutation rejected. Screenshots are not redacted.
- [ ] Lifecycle: quit/restart target app; old snapshot must fail. Observe another app; old IDs must fail.
- [ ] Permissions: revoke Accessibility or Screen Recording and verify clear errors without fallback.
- [ ] Multiple displays, Spaces, full-screen transitions, minimized/hidden windows, and long accessibility trees.
- [ ] Cancellation: stop the MCP process and confirm its native helper exits.

Unperformed manual cases are limitations, not passes. Background typing, scrolling, Electron compatibility, minimized/hidden windows, and multi-display behavior are not established by the initial fixture benchmark. Native runtime execution is tested on Apple Silicon; Intel is cross-compiled and signature-checked, not run on Intel hardware.
