import AppKit
import ApplicationServices

@MainActor
struct InteractionGuard {
    func assess(_ app: NSRunningApplication, element: AXUIElement, foreground: FocusState = .capture()) -> InteractionDecision {
        var s = InteractionSignals()
        s.foregroundKnown = foreground.pid != nil
        let window = owningWindow(element)
        s.targetWindowKnown = window != nil
        s.sameWindow = foreground.pid == app.processIdentifier && (window == nil || foreground.window == nil || CFEqual(window!,foreground.window!))
        if s.sameWindow && (foreground.window == nil || foreground.element == nil) { s.inputAvailable = false }
        if s.sameWindow, let focused = foreground.element {
            let role = attribute(focused,kAXRoleAttribute) as? String ?? ""
            s.focusedEditable = [kAXTextFieldRole,kAXTextAreaRole,kAXComboBoxRole].contains(role)
                || (attribute(focused,kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole
            // Custom web/native editors can expose a writable value instead of a text role.
            if !s.focusedEditable {
                var writable: DarwinBoolean = false
                AXUIElementIsAttributeSettable(focused,kAXValueAttribute as CFString,&writable)
                s.focusedEditable = writable.boolValue && attribute(focused,kAXSelectedTextRangeAttribute) != nil
            }
        }
        s.mouseHeld = NSEvent.pressedMouseButtons != 0
        let modifiers = CGEventSource.flagsState(.combinedSessionState).intersection([.maskShift,.maskControl,.maskAlternate,.maskCommand,.maskSecondaryFn])
        // Only keep an aggregate Boolean, never the identity or contents of a key.
        s.keyboardHeld = !modifiers.isEmpty || (0..<128).contains { code in
            !(54...63).contains(code) && CGEventSource.keyState(.combinedSessionState,key:CGKeyCode(code))
        }
        func age(_ events: [CGEventType]) -> Double {
            let values = events.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:$0) }
            if values.contains(where: { !$0.isFinite || $0 < 0 }) { s.inputAvailable = false }
            return values.min() ?? .infinity
        }
        s.keyAge = age([.keyDown,.keyUp,.flagsChanged])
        s.clickAge = age([.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp])
        s.scrollAge = age([.scrollWheel])
        s.movementAge = age([.mouseMoved,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged])
        if let window, let frame = elementFrame(window), let pointer = CGEvent(source:nil)?.location {
            if frame.contains(pointer) {
                let system = AXUIElementCreateSystemWide()
                AXUIElementSetMessagingTimeout(system,0.2)
                var hit: AXUIElement?
                let result = AXUIElementCopyElementAtPosition(system,Float(pointer.x),Float(pointer.y),&hit)
                // Fail conservatively when hit testing is unavailable. A window in
                // another app covering the same screen coordinates does not conflict.
                if result != .success { s.pointerOverWindow = true }
                else if let hit {
                    var pid: pid_t = 0
                    AXUIElementGetPid(hit,&pid)
                    s.pointerOverWindow = pid == app.processIdentifier && (owningWindow(hit).map { CFEqual($0,window) } ?? true)
                }
                s.pointerNearTarget = s.pointerOverWindow && (elementFrame(element)?.insetBy(dx:-64,dy:-64).contains(pointer) ?? true)
            }
        } else { s.inputAvailable = false }
        return InteractionDecision.evaluate(s)
    }
}
