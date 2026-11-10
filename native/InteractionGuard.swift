import AppKit
import ApplicationServices

@MainActor
struct InteractionGuard {
    // The frontmost ordinary window under a point, ignoring this helper's own overlays.
    func topWindow(at point: CGPoint) -> (pid: pid_t, bounds: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] else { return nil }
        for info in list {
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != getpid(),
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let raw = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation:raw as CFDictionary), bounds.contains(point) else { continue }
            return (pid,bounds)
        }
        return nil
    }
    func assess(_ app: NSRunningApplication, element: AXUIElement?, intrusive: Bool = false, foreground: FocusState = .capture()) -> InteractionDecision {
        var s = InteractionSignals()
        s.intrusive = intrusive
        s.foregroundKnown = foreground.pid != nil
        s.sameApp = foreground.pid == app.processIdentifier
        let window = element.flatMap { owningWindow($0) }
        s.sameWindow = s.sameApp && (window == nil || foreground.window == nil || CFEqual(window!,foreground.window!))
        if s.sameWindow, let focused = foreground.element {
            let role = attribute(focused,kAXRoleAttribute) as? String ?? ""
            s.focusedEditable = [kAXTextFieldRole,kAXTextAreaRole,kAXComboBoxRole].contains(role)
                || (attribute(focused,kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole
            // Custom web/native editors can expose a writable value instead of a text role.
            if !s.focusedEditable { s.focusedEditable = isSettable(focused,kAXValueAttribute) && attribute(focused,kAXSelectedTextRangeAttribute) != nil }
        }
        // Hardware state only: events this helper posts to an app never count as the user.
        s.mouseHeld = [CGMouseButton.left,.right,.center].contains { CGEventSource.buttonState(.hidSystemState,button:$0) }
        let modifiers = CGEventSource.flagsState(.hidSystemState).intersection([.maskShift,.maskControl,.maskAlternate,.maskCommand])
        // Only keep an aggregate Boolean, never the identity or contents of a key.
        s.keyboardHeld = !modifiers.isEmpty || (0..<128).contains { code in
            !(54...63).contains(code) && CGEventSource.keyState(.hidSystemState,key:CGKeyCode(code))
        }
        func age(_ events: [CGEventType]) -> Double {
            events.map { CGEventSource.secondsSinceLastEventType(.hidSystemState,eventType:$0) }.filter { $0.isFinite && $0 >= 0 }.min() ?? .infinity
        }
        s.keyAge = age([.keyDown,.keyUp,.flagsChanged])
        s.clickAge = age([.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp])
        s.scrollAge = age([.scrollWheel])
        s.movementAge = age([.mouseMoved,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged])
        // A window of another app covering the same screen coordinates does not conflict.
        if let pointer = CGEvent(source:nil)?.location, let top = topWindow(at:pointer), top.pid == app.processIdentifier {
            let frame = window.flatMap { elementFrame($0) }
            s.pointerOverWindow = frame.map { abs($0.minX-top.bounds.minX) < 3 && abs($0.minY-top.bounds.minY) < 3 && abs($0.width-top.bounds.width) < 3 && abs($0.height-top.bounds.height) < 3 } ?? true
            s.pointerNearTarget = s.pointerOverWindow && (element.flatMap { elementFrame($0) }?.insetBy(dx:-32,dy:-32).contains(pointer) ?? false)
        }
        return InteractionDecision.evaluate(s)
    }
}
