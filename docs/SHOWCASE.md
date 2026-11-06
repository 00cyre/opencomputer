# Product showcase

Both silent, captioned demos use actual native OpenComputer panels and the disposable fixture, assembled with Hyperframes 0.9.19. The recording shows animated dots, the hover reveal, smooth ghost-cursor movement, idle floating, multiple agent indicators, and release cleanup.

| File | Format | Use |
| --- | --- | --- |
| [Widescreen MP4](https://github.com/00cyre/opencomputer/releases/download/v0.2.1/OpenComputer-Showcase-16x9.mp4) | 1920 × 1080, 30 fps, 31 seconds | GitHub, product pages, landscape posts |
| [Vertical MP4](https://github.com/00cyre/opencomputer/releases/download/v0.2.1/OpenComputer-Showcase-9x16.mp4) | 1080 × 1920, 30 fps, 31 seconds | Reels, Shorts, vertical feeds |
| [Editable project ZIP](https://github.com/00cyre/opencomputer/releases/download/v0.2.1/OpenComputer-Showcase-Hyperframes.zip) | Two Hyperframes projects, bundled media/fonts | Revise copy, timing, framing, or exports |

The native fixture actions and hover positions are choreographed to make the features clear; this is not footage of live model inference. The source capture includes only the explicitly selected demo and overlay windows. The AI result card cites the independent [v0.2.0 Claude/Grok benchmark](BENCHMARKS.md). The motion changes in v0.2.1 have separate native tests.

The recording harness compiles production `ActivityOverlay.swift` and `GhostMotion.swift`, injects hover positions without moving the human’s real pointer, and records explicit window IDs with ScreenCaptureKit. The exported video is reframed with captions and camera moves; product controls are not invented. Some surrounding fixture text is intentionally cropped in close-ups. [Focus limitations](API.md#focus-protection-and-text) still apply.

To edit a project from the ZIP, enter its `widescreen` or `vertical` folder and run:

```sh
npx --yes hyperframes@0.9.19 preview
npx --yes hyperframes@0.9.19 check
npx --yes hyperframes@0.9.19 render --output showcase.mp4 --quality delivery
```

Each project includes its creative spec, asset provenance, review notes, and font/library licenses. No cloud media generation, voiceover, music, or user-app screenshots are included.
