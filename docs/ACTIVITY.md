# Activity indicators

Enabled by default on macOS. Observation, screenshot capture, and actions start or update a session’s activity indicator. No extra service or login item is installed.

## Three dots, details on hover

The collapsed indicator is a 54 × 30 point pill with three animated dots, placed at the top right of the primary display’s usable area. Hover expands it to 380 × 84 points with the AI icon → app icon, agent/app names, window title, and latest operation. Leaving it collapses the details after a short delay. For a browser, the title comes from its accessibility window title, which commonly contains the selected tab name; this is not a browser DOM integration.

![Collapsed dots](assets/activity-collapsed.png)

![Expanded live panel](assets/activity-expanded.png)

Screenshots above are from the real AppKit implementation using synthetic fixture data. Claude’s icon was loaded from the installed app at runtime. No vendor icon assets are distributed separately. Unknown or uninstalled AI apps use an initial.

Each helper represents one session and its latest target app. Concurrent sessions stack their pills. Indicators remain until `release`, server exit, or target-app exit; they do not imply that the model is continuously dispatching an action. The action label is the latest operation. A paused focus guard stays visibly paused even after read-only inspection.

When a mutation conflicts with your input, the dots turn amber and hover explains the wait: editing, clicking, scrolling, a held gesture, or a nearby pointer. The action was not dispatched or queued. A later fresh observation/action rechecks activity; the helper never replays the action by itself. A focus change remains a separate, latched pause.

## Ghost cursor

![Ghost cursor](assets/ghost-cursor.png)

The colored arrow marks the last targeted control, or a point near the window’s upper left during observation. It eases between targets over 220–500 ms with zero starting/ending velocity. After a brief pause it gently floats by up to 2.4 points vertically and 0.65 points horizontally, with a 2.4-second vertical cycle. These are visual offsets; the real pointer stays untouched. It follows the target window and appears only where that window is exposed. Covering that point, minimizing/hiding the window, or moving it offscreen hides the arrow. It reappears when the target is visible again. Accessibility hit-testing checks only the owner/window identity of the point; it does not read covering apps’ contents.

The arrow is a visual annotation. It does not move the real pointer and is not included in app-window screenshots returned to the agent.

## Focus and settings

Both panels use non-activating AppKit windows, cannot become key/main, ignore mouse events, and sit above ordinary app windows. Hover is read from the pointer location, so clicks keep reaching the window underneath. System/security UI can appear above them. Display/Space/full-screen combinations beyond the documented tests remain unverified.

MCP client identity is detected during initialization. To override it, set `OPENCOMPUTER_AGENT=Claude` or another display name in the server’s environment. Set `OPENCOMPUTER_OVERLAY=0` to disable both visuals; focus protection remains enabled. JavaScript equivalents are `{agent: 'Claude', overlay: false}`. Restart the server after configuration changes.

OpenComputer never activates an app for its own work or moves the pointer. Keys are posted to the target process only. An app can activate itself in response to an action; when the person did not cause it, the helper hands the foreground back to the app they were in. This cannot prevent a brief flash forward. See [staying out of the way](API.md#staying-out-of-the-persons-way).

For stacking, helpers exchange only PID, heartbeat time, and expanded/collapsed state in a per-user temporary directory. No app names, window titles, action text, or input values are written there. Clean release removes the session record; records left by forced termination are ignored after the process dies or heartbeat expires.
