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

## Activity and focus tests

Run these serially after building the fixture:

```sh
npm run test:activity
npm run test:ui
npm run test:focus
npm run test:motion
```

- Activity: 16 assertions across two real helper sessions, correct Claude/Grok attribution, visible ghost cursor, hiding behind a covering window and returning, stacked non-overlapping pills, click-through/non-activating flags, raw-key rejection, semantic editing, and independent release.
- UI: 12 assertions using the actual AppKit panel, comparing rendered dot frames, expanded content and window title, hover expansion/collapse, click-through behavior, non-key/main status, foreground isolation, and cleanup. Pointer positions are injected into the production hover calculation; the real mouse never moves. It captures only its own panels to PNG, not the desktop. This is a programmatic hover test, not a hardware-mouse walkthrough.
- Focus guard: 7 assertions with a test-only button that deliberately activates the fixture. The helper returns `FOCUS_CHANGED`, retains the pause across observations, rejects further writes, and does not clear the block on `release`. This validates containment after a change, not prevention of every app-side activation.

Nine deterministic native motion checks cover smooth interpolation, no overshoot, bounded idle drift, continuity when retargeting during idle, and stable animation under repeated target refresh. The UI test selects its own fixture PID and clears stale readiness state before launching.

Ten JavaScript unit tests also cover explicit/inferred agent identity, release, and the restricted MCP action schema. See [activity behavior](ACTIVITY.md) for visuals and limitations.

## AI-client benchmark

See [benchmarks](BENCHMARKS.md). Each AI must operate through the OpenComputer MCP server, with no shell/file bypass. The fixture state and audit proxy establish success independently of the model's final response.

## Manual compatibility checks

Record app version and macOS version for each result:

- [ ] Standard AppKit app: set a disposable field, press a button, verify values, and check focus.
- [ ] Electron app: inspect tree quality and confirm semantic controls exist before mutation.
- [ ] Selected-range text: replace Unicode text through `typeText` in supported controls and verify caret/foreground behavior. Raw keyboard input is intentionally rejected.
- [ ] Scrolling: call a supported accessibility scroll action and verify content changed.
- [ ] Screen capture: select among multiple windows, test a covered window, and confirm no unrelated app content appears.
- [ ] Secure field: value is redacted, `settable` false, mutation rejected. Screenshots are not redacted.
- [ ] Lifecycle: quit/restart target app; old snapshot must fail. Observe another app; old IDs must fail.
- [ ] Permissions: revoke Accessibility or Screen Recording and verify clear errors without fallback.
- [ ] Multiple displays, Spaces, full-screen transitions, minimized/hidden windows, and long accessibility trees.
- [ ] Cancellation: stop the MCP process and confirm its native helper exits.

Unperformed manual cases are limitations, not passes. Selected-range typing across apps, scrolling, Electron compatibility, minimized/hidden windows, and multi-display behavior are not established by the fixture benchmark. Ghost occlusion is tested with a real covering fixture panel; arbitrary apps and Spaces can expose different accessibility behavior. Native runtime execution is tested on Apple Silicon; Intel is cross-compiled and signature-checked, not run on Intel hardware.
