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
4. Insert text at the caret, then send Return and typed keys to the background field, all from one snapshot.
5. Reject an unknown snapshot and a window-raising action; read back the changed value.
6. Click a checkbox, then press the submit button through a screenshot point.
7. Verify the fixture's independent on-disk state: expected token, checkbox on, exactly one submit.
8. Check foreground focus during actions and submission.
9. Select the fixture's actual window and validate its captured PNG signature.

The script reports 13 assertions. Screenshots are kept only if `OPENCOMPUTER_TEST_IMAGE` names an output path. The fixture's own result file is outside the agent's task and is deleted after the integration test.

## Changed targets and the action log

```sh
npm run test:guard
```

Launches the fixture with two browser-like tabs whose window title follows the selected tab. A signal to the fixture plays the person switching tabs, outside OpenComputer. 26 assertions: a control in the tab the person left, a window control, keys to the focused window, a same-title tab switch, and a screenshot point are all refused with nothing reaching the fixture; a fresh snapshot acts; the agent's own tab press keeps the snapshot valid for window controls but not for the tab it left; the foreground is unchanged; and the session log names targets, windows, and outcomes while containing no typed values.

A manual run against a throwaway Chrome for Testing window (separate app and profile) on 2026-11-11 passed 20 checks: page buttons, the address bar, and bare `Return` refused after a tab switch (`window-title`), the same between two tabs titled identically (`tab`), the old page refused after the agent's own tab switch (`detached`) and after the person navigated (`STALE_ELEMENT`), `clickPoint` refused after a tab switch, and closing the agent's own tab then reselecting the person's tab from one snapshot allowed.

## Activity and focus tests

Run these serially after building the fixture:

```sh
npm run test:activity
npm run test:ui
npm run test:focus
npm run test:motion
npm run test:interaction
npm run test:approval
```

- Activity: 16 assertions across two real helper sessions, correct Claude/Grok attribution, visible ghost cursor, hiding behind a covering window and returning, stacked non-overlapping pills, click-through/non-activating flags, menu-action rejection, semantic editing, and independent release.
- UI: 26 assertions using the actual AppKit panel, comparing rendered dot frames, the step timeline, expanded content and window title, hover expansion/collapse and button highlight, Take over and Resume (including the `PAUSED_BY_USER` refusal), an approval question opening the card and Allow approving the waiting action once, click-through behavior of the dots and ghost, non-key/main status, foreground isolation, and cleanup. Set `OPENCOMPUTER_UI_APPEARANCE=dark` or `light` to capture either appearance. Pointer positions are injected into the production hover calculation; the real mouse never moves. It captures only its own panels to PNG, not the desktop. This is a programmatic hover test, not a hardware-mouse walkthrough.
- Focus and interaction: a test-only button deliberately activates the fixture. The helper reports `focusChanged` and `focusRestored`, the previous foreground app is back in front, and the same session and snapshot keep working. It then edits a second window of the same app, exercising window selection, subtree expansion that keeps element IDs, and preflight checks through the production helper. This validates restoration after a change, not prevention of every app-side activation.
- Interaction policy: 26 deterministic scenarios covering held mouse gestures and keys, focused editors, pointer proximity, recent typing/clicking/scrolling/movement, missing state, unrelated windows, quiet-time boundaries, and resumption after a gesture ends. These simulate signals without injecting global input.

Approval policy: 30 deterministic checks of `OPENCOMPUTER_CONFIRM` parsing, whole-word label matching, submitting keys, per-app and all-action rules, and the question lifecycle (one answer per question, used once, never inherited by another action, lapsing after two minutes unanswered or one minute unused).

Nine deterministic native motion checks cover smooth interpolation, no overshoot, bounded idle drift, continuity when retargeting during idle, and stable animation under repeated target refresh. The UI test selects its own fixture PID and clears stale readiness state before launching.

Thirteen JavaScript unit tests also cover explicit/inferred agent identity, release, interaction metadata, protective-pause audit classification, preflight snapshot preservation, scoped observation arguments, and the restricted MCP action schema. See [activity behavior](ACTIVITY.md) for visuals and limitations.

The 0.3.0 live runs on 2026-11-07 passed integration, focus/interaction, activity, and UI checks, plus motion and interaction-policy scenarios. An earlier integration run returned `USER_BUSY` for real pointer movement in the fixture before dispatch; a fresh serial run passed. Keep working in other windows while tests run; a conflict is an intentional pause, not permission to disable the guard. A test interrupted by human activity must start fresh, not replay stale references.

## AI-client benchmark

See [benchmarks](BENCHMARKS.md). Each AI must operate through the OpenComputer MCP server, with no shell/file bypass. The fixture state and audit proxy establish success independently of the model's final response.

## Manual compatibility checks

Record app version and macOS version for each result:

- [ ] Standard AppKit app: set a disposable field, press a button, verify values, and check focus.
- [ ] Electron app: inspect tree quality and confirm semantic controls exist before mutation.
- [ ] Selected-range text: replace Unicode text through `typeText` in supported controls and verify caret/foreground behavior. Check `keys: true` and `pressKey` against a background window of the same app.
- [ ] Scrolling: call a supported accessibility scroll action and verify content changed.
- [ ] Screen capture: select among multiple windows, test a covered window, and confirm no unrelated app content appears.
- [ ] Secure field: value is redacted, `settable` false, mutation rejected. Screenshots are not redacted.
- [ ] Lifecycle: quit/restart target app; old snapshot must fail. Observe another app; old IDs must fail.
- [ ] Permissions: revoke Accessibility or Screen Recording and verify clear errors without fallback.
- [ ] Multiple displays, Spaces, full-screen transitions, minimized/hidden windows, and long accessibility trees.
- [ ] Cancellation: stop the MCP process and confirm its native helper exits.

Unperformed manual cases are limitations, not passes. Selected-range typing across apps, scrolling, Electron compatibility, minimized/hidden windows, and multi-display behavior are not established by the fixture benchmark. Ghost occlusion is tested with a real covering fixture panel; arbitrary apps and Spaces can expose different accessibility behavior. Native runtime execution is tested on Apple Silicon; Intel is cross-compiled and signature-checked, not run on Intel hardware.
