import Foundation

// No key contents, pointer history, or app content is retained. The same policy is
// exercised with deterministic signals in tests and fresh OS observations in use.
struct InteractionSignals {
    var foregroundKnown = true
    var targetWindowKnown = true
    var sameWindow = false
    var focusedEditable = false
    var mouseHeld = false
    var keyboardHeld = false
    var pointerOverWindow = false
    var pointerNearTarget = false
    var inputAvailable = true
    var keyAge = Double.infinity
    var clickAge = Double.infinity
    var scrollAge = Double.infinity
    var movementAge = Double.infinity
}

struct InteractionDecision {
    let canProceed: Bool
    let reason: String
    let message: String
    let retryAfterMs: Int?
    var json: [String: Any] {
        var value: [String: Any] = ["canProceed":canProceed,"reason":reason,"message":message]
        if let retryAfterMs { value["retryAfterMs"] = retryAfterMs }
        return value
    }
    static func evaluate(_ s: InteractionSignals) -> InteractionDecision {
        func wait(_ reason: String, _ message: String, _ delay: Int = 500) -> InteractionDecision {
            InteractionDecision(canProceed:false,reason:reason,message:message,retryAfterMs:delay)
        }
        func remaining(_ age: Double, _ interval: Double) -> Int { max(100,Int(ceil((interval-age)*1000))) }
        guard s.foregroundKnown else { return wait("foreground-unavailable","Waiting — foreground app is unavailable.",1000) }
        guard s.targetWindowKnown else { return wait("target-window-unavailable","Waiting — this control has no identifiable window.",1000) }
        // A held button may be dragging between apps, so protect the entire gesture.
        if s.mouseHeld { return wait("mouse-button-held","Waiting — you are holding a mouse button.") }
        if !s.inputAvailable { return wait("input-state-unavailable","Waiting — input activity could not be checked.",1000) }
        if s.sameWindow && s.focusedEditable { return wait("editing-window","Waiting — you are editing in this window.",1000) }
        if (s.sameWindow || s.pointerOverWindow) && s.keyboardHeld { return wait("keyboard-held","Waiting — a key or shortcut is held in this window.") }
        if s.pointerNearTarget { return wait("pointer-near-target","Waiting — your pointer is near this control.") }
        if s.sameWindow && s.keyAge < 2 { return wait("recent-typing","Waiting — you are typing in this window.",remaining(s.keyAge,2)) }
        if (s.sameWindow || s.pointerOverWindow) && s.clickAge < 1.2 { return wait("recent-click","Waiting — you are clicking in this window.",remaining(s.clickAge,1.2)) }
        if (s.sameWindow || s.pointerOverWindow) && s.scrollAge < 1.5 { return wait("recent-scroll","Waiting — you are scrolling in this window.",remaining(s.scrollAge,1.5)) }
        if s.pointerOverWindow && s.movementAge < 0.8 { return wait("pointer-moving","Waiting — your pointer is moving in this window.",remaining(s.movementAge,0.8)) }
        return InteractionDecision(canProceed:true,reason:s.sameWindow ? "window-idle" : "background-window",message:"No interaction conflict detected. This is a preflight observation, not a reservation.",retryAfterMs:nil)
    }
}
