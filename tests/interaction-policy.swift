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
        check("background-window",true)
        check("background-window",true) { $0.keyAge = 0; $0.keyboardHeld = true; $0.clickAge = 0; $0.scrollAge = 0; $0.movementAge = 0 }
        check("window-idle",true) { $0.sameWindow = true }
        check("foreground-unavailable") { $0.foregroundKnown = false }
        check("target-window-unavailable") { $0.targetWindowKnown = false }
        check("mouse-button-held") { $0.mouseHeld = true }
        check("input-state-unavailable") { $0.inputAvailable = false }
        check("editing-window") { $0.sameWindow = true; $0.focusedEditable = true }
        check("background-window",true) { $0.focusedEditable = true }
        check("keyboard-held") { $0.sameWindow = true; $0.keyboardHeld = true }
        check("keyboard-held") { $0.pointerOverWindow = true; $0.keyboardHeld = true }
        check("pointer-near-target") { $0.pointerOverWindow = true; $0.pointerNearTarget = true }
        check("recent-typing") { $0.sameWindow = true; $0.keyAge = 1.999 }
        check("window-idle",true) { $0.sameWindow = true; $0.keyAge = 2 }
        check("recent-click") { $0.sameWindow = true; $0.clickAge = 0.5 }
        check("recent-click") { $0.pointerOverWindow = true; $0.clickAge = 0.5 }
        check("recent-scroll") { $0.sameWindow = true; $0.scrollAge = 1.49 }
        check("recent-scroll") { $0.pointerOverWindow = true; $0.scrollAge = 0.5 }
        check("pointer-moving") { $0.pointerOverWindow = true; $0.movementAge = 0.5 }
        check("background-window",true) { $0.pointerOverWindow = true; $0.movementAge = 0.8 }
        // Clearing a gesture resumes without a reconnect or a delayed queued action.
        var signals = InteractionSignals(); signals.mouseHeld = true
        precondition(!InteractionDecision.evaluate(signals).canProceed)
        signals.mouseHeld = false
        precondition(InteractionDecision.evaluate(signals).canProceed); checks += 1
        print("Interaction policy: \(checks) scenarios passed")
    }
}
