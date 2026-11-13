import AppKit
import ApplicationServices

// Accessibility notifications from an app the session has observed. They time the read
// after an action (wait until the app goes quiet) and tell an action that changed nothing
// from one whose effect the outline cannot show. Nothing about the content is kept, only
// how many notifications of each kind arrived and when the last one did.
final class ChangeWatch {
    static let notifications = [kAXCreatedNotification, kAXUIElementDestroyedNotification, kAXValueChangedNotification, kAXTitleChangedNotification,
                                kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification, kAXSheetCreatedNotification,
                                kAXSelectedChildrenChangedNotification, kAXRowCountChangedNotification, kAXMenuOpenedNotification, "AXElementBusyChanged"]
    private var observer: AXObserver?
    private var root: AXUIElement?
    let pid: pid_t
    private(set) var last = Date.distantPast
    private(set) var counts: [String:Int] = [:]
    init?(_ pid: pid_t) {
        self.pid = pid
        var made: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            Unmanaged<ChangeWatch>.fromOpaque(refcon).takeUnretainedValue().noted(notification as String)
        }
        guard AXObserverCreate(pid, callback, &made) == .success, let made else { return nil }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Registered on the application element, a notification arrives for any element in it.
        var registered = 0
        for name in ChangeWatch.notifications where AXObserverAddNotification(made, app, name as CFString, refcon) == .success { registered += 1 }
        guard registered > 0 else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(made), CFRunLoopMode.commonModes)
        observer = made
        root = app
    }
    func noted(_ name: String) { last = Date(); counts[name.replacingOccurrences(of: "AX", with: ""), default: 0] += 1 }
    func reset() { counts = [:] }
    var total: Int { counts.values.reduce(0, +) }
    func stop() {
        guard let observer, let root else { return }
        for name in ChangeWatch.notifications { AXObserverRemoveNotification(observer, root, name as CFString) }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), CFRunLoopMode.commonModes)
        self.observer = nil
        self.root = nil
    }
}

extension Computer {
    // Starts watching an app the first time it is observed, and starts its count again.
    func watchChanges(_ pid: pid_t) {
        if let existing = watches[pid] { existing.reset(); return }
        // A handful of apps at most; the oldest watch makes room.
        if watches.count >= 8, let oldest = watchOrder.first { watches.removeValue(forKey: oldest)?.stop(); watchOrder.removeFirst() }
        guard let watch = ChangeWatch(pid) else { return }
        watches[pid] = watch
        watchOrder.append(pid)
    }
    // Waits until the app has sent no notification for quietMs (at least that long), or
    // maxMs passes, and reports what arrived since the app was last observed.
    func settle(_ app: NSRunningApplication, _ request: [String:Any]) async -> [String:Any] {
        let quiet = Double(min(2000, max(50, request["quietMs"] as? Int ?? 200))) / 1000
        let most = Double(min(10000, max(100, request["maxMs"] as? Int ?? 1500))) / 1000
        let started = Date()
        guard let watch = watches[app.processIdentifier] else {
            try? await Task.sleep(nanoseconds: UInt64(quiet * 1_000_000_000))
            return ["watched": false, "waitedMs": Int(Date().timeIntervalSince(started) * 1000)]
        }
        var calm = 0.0
        while true {
            calm = Date().timeIntervalSince(max(watch.last, started))
            if calm >= quiet || Date().timeIntervalSince(started) >= most { break }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return ["watched": true, "settled": calm >= quiet, "waitedMs": Int(Date().timeIntervalSince(started) * 1000),
                "notifications": watch.total, "kinds": watch.counts]
    }
    func stopWatching() {
        for watch in watches.values { watch.stop() }
        watches = [:]
        watchOrder = []
    }
}
