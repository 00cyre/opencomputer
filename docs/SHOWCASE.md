# Product showcase

Both narrated demos use actual native OpenComputer panels and the disposable fixture, assembled with Hyperframes 0.9.19. The recording shows animated dots, the hover reveal, smooth ghost-cursor movement, idle floating, multiple agent indicators, and release cleanup.

| File | Format | Use |
| --- | --- | --- |
| [Widescreen MP4](https://github.com/00cyre/opencomputer/releases/download/v0.2.1/OpenComputer-Showcase-16x9.mp4) | 1920 × 1080, 30 fps, 27.3 seconds | GitHub, product pages, landscape posts |
| [Vertical MP4](https://github.com/00cyre/opencomputer/releases/download/v0.2.1/OpenComputer-Showcase-9x16.mp4) | 1080 × 1920, 30 fps, 27.3 seconds | Reels, Shorts, vertical feeds |
| [Editable project ZIP](https://github.com/00cyre/opencomputer/releases/download/v0.2.1/OpenComputer-Showcase-Hyperframes.zip) | Two Hyperframes projects, bundled media/fonts | Revise copy, timing, framing, or exports |

The native fixture actions and hover positions are choreographed to make the features clear; this is not footage of live model inference. The source capture includes only the explicitly selected demo and overlay windows. The earlier benchmark result card has been removed; the independent [v0.2.0 Claude/Grok benchmark](BENCHMARKS.md) remains documented separately. The motion changes in v0.2.1 have separate native tests.

The recording harness compiles production `ActivityOverlay.swift` and `GhostMotion.swift`, injects hover positions without moving the human’s real pointer, and records explicit window IDs with ScreenCaptureKit. The exported video is reframed with captions and camera moves; product controls are not invented. Some surrounding fixture text is intentionally cropped in close-ups. [Focus limitations](API.md#focus-protection-and-text) still apply.

To edit a project from the ZIP, enter its `widescreen` or `vertical` folder and run:

```sh
npx --yes hyperframes@0.9.19 preview
npx --yes hyperframes@0.9.19 check
npx --yes hyperframes@0.9.19 render --output showcase.mp4 --quality delivery
```

Each project includes its creative spec, asset provenance, review notes, and font/library licenses. The revised films include ElevenLabs narration (Eric, multilingual_v2), three generated sound effects, and the user-provided track “night routine” by Inlirium, ducked under speech. Only the used music excerpt is bundled; third-party music remains subject to its own rights and is not covered by the software’s MIT license. No credentials or unrelated user-app screenshots are included.

The edit uses 0.8–0.85 second eased camera moves, staggered text entrances, and a continuous end-card reveal. Both 27.3-second projects pass Hyperframes lint, runtime, layout, contrast, craft, and audio checks with zero errors or warnings. Sound levels are measured; listening quality has not been independently auditioned.
