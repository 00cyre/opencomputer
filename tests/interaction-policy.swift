import Foundation

@main
struct Tests {
    static func main() {
        var checks = 0
        func check(_ expected: String, _ allowed: Bool = false, _ setup: (inout InteractionSignals) -> Void = { _ in }) {
            var s = InteractionSignals(); setup(&s)
            let result = InteractionDecision.evaluate(s)
            precondition(result.reason == expected && result.canProceed == allowed,"Expected \(expected), got \(result.reason)")
            precondition(allowed ? result.retryAfterMs == nil : (result.retryAfterMs ?? 0) > 0)
            checks += 1
        }
        // Work in another app never blocks, whatever the person is doing there.
        check("background-window",true)
        check("background-window",true) { $0.keyAge = 0; $0.keyboardHeld = true; $0.clickAge = 0; $0.scrollAge = 0; $0.movementAge = 0; $0.mouseHeld = true }
        check("background-window",true) { $0.intrusive = true; $0.keyAge = 0; $0.keyboardHeld = true; $0.clickAge = 0 }
        check("background-window",true) { $0.focusedEditable = true; $0.keyAge = 0 }
        // Another window of the same app stays available while the person types.
        check("background-window",true) { $0.sameApp = true; $0.keyAge = 0; $0.keyboardHeld = true }
        check("window-idle",true) { $0.sameApp = true; $0.sameWindow = true }
        check("window-idle",true) { $0.sameApp = true; $0.sameWindow = true; $0.focusedEditable = true; $0.keyAge = 3 }
        check("foreground-unavailable") { $0.foregroundKnown = false }
        check("mouse-button-held") { $0.mouseHeld = true; $0.sameApp = true }
        check("mouse-button-held") { $0.mouseHeld = true; $0.pointerOverWindow = true }
        // Keys land in the app's own focus, so they wait while the person is active in it.
        check("app-in-use") { $0.intrusive = true; $0.sameApp = true; $0.keyAge = 1 }
        check("app-in-use") { $0.intrusive = true; $0.sameApp = true; $0.clickAge = 2.9 }
        check("background-window",true) { $0.intrusive = true; $0.sameApp = true; $0.keyAge = 3; $0.clickAge = 3; $0.scrollAge = 3 }
        check("editing-window") { $0.sameApp = true; $0.sameWindow = true; $0.focusedEditable = true; $0.keyAge = 2.9 }
        check("keyboard-held") { $0.sameApp = true; $0.sameWindow = true; $0.keyboardHeld = true }
        check("keyboard-held") { $0.pointerOverWindow = true; $0.keyboardHeld = true }
        check("pointer-near-target") { $0.pointerOverWindow = true; $0.pointerNearTarget = true; $0.movementAge = 0.5 }
        check("background-window",true) { $0.pointerOverWindow = true; $0.pointerNearTarget = true; $0.movementAge = 1 }
        check("background-window",true) { $0.pointerOverWindow = true; $0.movementAge = 0 }
        check("recent-typing") { $0.sameApp = true; $0.sameWindow = true; $0.keyAge = 1.4 }
        check("window-idle",true) { $0.sameApp = true; $0.sameWindow = true; $0.keyAge = 1.5 }
        check("recent-click") { $0.sameApp = true; $0.sameWindow = true; $0.clickAge = 0.5 }
        check("recent-click") { $0.pointerOverWindow = true; $0.clickAge = 0.5 }
        check("recent-scroll") { $0.pointerOverWindow = true; $0.scrollAge = 0.5 }
        check("window-idle",true) { $0.sameApp = true; $0.sameWindow = true; $0.clickAge = 0.8; $0.scrollAge = 0.8 }
        // Clearing a gesture resumes without a reconnect or a delayed queued action.
        var signals = InteractionSignals(); signals.mouseHeld = true; signals.sameApp = true
        precondition(!InteractionDecision.evaluate(signals).canProceed)
        signals.mouseHeld = false
        precondition(InteractionDecision.evaluate(signals).canProceed); checks += 1
        print("Interaction policy: \(checks) scenarios passed")
    }
}
