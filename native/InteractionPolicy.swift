import Foundation

// No key contents, pointer history, or app content is retained. The same policy is
// exercised with deterministic signals in tests and fresh OS observations in use.
struct InteractionSignals {
    var foregroundKnown = true
    var sameApp = false
    var sameWindow = false
    // The action posts key events, which land wherever the app's own focus is.
    var intrusive = false
    var focusedEditable = false
    var mouseHeld = false
    var keyboardHeld = false
    var pointerOverWindow = false
    var pointerNearTarget = false
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
    // Only a person working in the same place blocks an action. Activity in other
    // apps, or in another window of the target app, never does.
    static func evaluate(_ s: InteractionSignals) -> InteractionDecision {
        func wait(_ reason: String, _ message: String, _ delay: Int = 500) -> InteractionDecision {
            InteractionDecision(canProceed:false,reason:reason,message:message,retryAfterMs:delay)
        }
        func remaining(_ age: Double, _ interval: Double) -> Int { max(100,Int(ceil((interval-age)*1000))) }
        let here = s.sameWindow || s.pointerOverWindow
        guard s.foregroundKnown else { return wait("foreground-unavailable","Waiting — foreground app is unavailable.",1000) }
        if s.mouseHeld && (s.sameApp || s.pointerOverWindow) { return wait("mouse-button-held","Waiting — you are holding a mouse button in this app.") }
        let active = min(s.keyAge,s.clickAge,s.scrollAge)
        if s.intrusive && s.sameApp && active < 3 { return wait("app-in-use","Waiting — you are using this app, so keys would land in your focus.",remaining(active,3)) }
        if s.sameWindow && s.focusedEditable && s.keyAge < 3 { return wait("editing-window","Waiting — you are editing in this window.",remaining(s.keyAge,3)) }
        if here && s.keyboardHeld { return wait("keyboard-held","Waiting — a key or shortcut is held in this window.") }
        if s.pointerNearTarget && min(s.movementAge,s.clickAge) < 1 { return wait("pointer-near-target","Waiting — your pointer is on this control.",remaining(min(s.movementAge,s.clickAge),1)) }
        if s.sameWindow && s.keyAge < 1.5 { return wait("recent-typing","Waiting — you are typing in this window.",remaining(s.keyAge,1.5)) }
        if here && s.clickAge < 0.8 { return wait("recent-click","Waiting — you are clicking in this window.",remaining(s.clickAge,0.8)) }
        if here && s.scrollAge < 0.8 { return wait("recent-scroll","Waiting — you are scrolling in this window.",remaining(s.scrollAge,0.8)) }
        return InteractionDecision(canProceed:true,reason:s.sameWindow ? "window-idle" : "background-window",message:"No interaction conflict detected. This is a preflight observation, not a reservation.",retryAfterMs:nil)
    }
}
