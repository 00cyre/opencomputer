import AppKit
import ApplicationServices

struct FocusState {
    let pid: pid_t?
    let bundle: String
    let window: AXUIElement?
    let element: AXUIElement?
    static func capture() -> FocusState {
        let app = NSWorkspace.shared.frontmostApplication
        let root = app.map { AXUIElementCreateApplication($0.processIdentifier) }
        if let root = root { AXUIElementSetMessagingTimeout(root,0.2) }
        return FocusState(pid:app?.processIdentifier,bundle:app?.bundleIdentifier ?? "unknown",
                          window:root.flatMap { axElement(attribute($0,kAXFocusedWindowAttribute)) },
                          element:root.flatMap { axElement(attribute($0,kAXFocusedUIElementAttribute)) })
    }
    func differs(from other: FocusState) -> Bool {
        func same(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
            switch (a,b) { case let (a?,b?): return CFEqual(a,b); case (nil,nil): return true; default: return false }
        }
        return pid != other.pid || !same(window,other.window) || !same(element,other.element)
    }
}

@MainActor
final class FocusGuard {
    var before: FocusState?
    var observer: AXObserver?
    var activationToken: NSObjectProtocol?
    var sawTransition = false
    var blocked = false
    init() {
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self = self, let before = self.before,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != before.pid else { return }
                self.sawTransition = true
            }
        }
    }
    func begin() throws -> FocusState {
        guard !blocked else { try fail("FOCUS_PROTECTION_BLOCKED", "This session is paused after a focus change. Inspect the app and reconnect to continue; no focus restoration is attempted.") }
        let state = FocusState.capture(); before = state; sawTransition = false
        if let pid = state.pid {
            var candidate: AXObserver?
            let callback: AXObserverCallback = { _, _, _, context in
                guard let context = context else { return }
                MainActor.assumeIsolated { Unmanaged<FocusGuard>.fromOpaque(context).takeUnretainedValue().sawTransition = true }
            }
            if AXObserverCreate(pid,callback,&candidate) == .success, let candidate = candidate {
                observer = candidate
                let root = AXUIElementCreateApplication(pid)
                for name in [kAXFocusedWindowChangedNotification,kAXFocusedUIElementChangedNotification] {
                    AXObserverAddNotification(candidate,root,name as CFString,Unmanaged.passUnretained(self).toOpaque())
                }
                CFRunLoopAddSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(candidate),.commonModes)
            }
        }
        return state
    }
    func finish() -> (FocusState,Bool) {
        let after = FocusState.capture()
        let changed = sawTransition || before.map { $0.differs(from:after) } == true
        if let observer = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(observer),.commonModes) }
        observer = nil; before = nil
        if changed { blocked = true }
        return (after,changed)
    }
    func userIsEditing(_ target: NSRunningApplication) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return false }
        return [CGEventType.keyDown,.leftMouseDown,.rightMouseDown].contains { CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:$0) < 0.75 }
    }
}
