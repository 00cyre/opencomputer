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
}

// Some apps activate themselves when a control is pressed. The helper never asks for
// that, so an activation the user did not cause is undone by handing the foreground
// back to the app they were in. The session stays usable either way.
@MainActor
final class FocusGuard {
    private var previous: NSRunningApplication?
    private var target: pid_t?
    private var watchUntil = Date.distantPast
    private var activationToken: NSObjectProtocol?
    private var changed = false
    private var restored = false
    private(set) var restorations = 0
    init() {
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.activated(app)
            }
        }
    }
    // A real click, or a modifier just pressed or released (Cmd-Tab, Dock, Spotlight),
    // means the person switched apps themselves.
    // A key press counts only when some app other than the action's target came forward
    // (a launcher or shortcut), since typing elsewhere says nothing about the target.
    private func userInitiated(_ activated: pid_t? = nil) -> Bool {
        func age(_ events: [CGEventType]) -> Double {
            events.map { CGEventSource.secondsSinceLastEventType(.hidSystemState,eventType:$0) }.filter { $0.isFinite && $0 >= 0 }.min() ?? .infinity
        }
        if age([.leftMouseDown,.leftMouseUp,.rightMouseDown,.otherMouseDown]) < 0.5 || age([.flagsChanged]) < 0.4
            || CGEventSource.flagsState(.hidSystemState).contains(.maskCommand) { return true }
        if let activated, activated != target { return age([.keyDown]) < 0.5 }
        return false
    }
    private func activated(_ app: NSRunningApplication) {
        guard Date() < watchUntil, let previous, !previous.isTerminated,
              app.processIdentifier != previous.processIdentifier, app.processIdentifier != getpid() else { return }
        if userInitiated(app.processIdentifier) { watchUntil = .distantPast; return }
        changed = true
        restored = true; restorations += 1
        previous.activate(options:[])
        let pid = previous.processIdentifier
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15) {
            MainActor.assumeIsolated {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid, !self.userInitiated() else { return }
                AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid),kAXFrontmostAttribute as CFString,kCFBooleanTrue)
            }
        }
    }
    func expect(_ pid: pid_t) { target = pid }
    func begin(target pid: pid_t?) -> FocusState {
        previous = NSWorkspace.shared.frontmostApplication
        target = pid
        changed = false; restored = false
        watchUntil = Date().addingTimeInterval(30)
        return FocusState.capture()
    }
    func cancel() { watchUntil = .distantPast }
    func finish(settleMs: Int) async -> (after: String, changed: Bool, restored: Bool) {
        if settleMs > 0 { try? await Task.sleep(nanoseconds:UInt64(settleMs)*1_000_000) }
        // The notification can trail the switch; treat a different foreground app the same way.
        if !changed, let current = NSWorkspace.shared.frontmostApplication { activated(current) }
        if restored, let previous {
            for _ in 0..<12 where NSWorkspace.shared.frontmostApplication?.processIdentifier != previous.processIdentifier {
                try? await Task.sleep(nanoseconds:25_000_000)
            }
        }
        // Late self-activations are still undone for a short while after the action returns.
        watchUntil = Date().addingTimeInterval(1.5)
        return (frontmost(),changed,restored)
    }
}
