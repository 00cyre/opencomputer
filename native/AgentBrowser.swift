import AppKit

// The agent browser: a second Google Chrome instance with its own profile folder.
// Agents open and drive their pages there, so they never add tabs to the person's
// windows, switch their tabs, or wait on them, and the person's browsing never moves
// an agent's target. It renders while covered, hidden, or behind a fullscreen app.
enum AgentBrowser {
    static let name = "agent-browser"
    static let bundle = "com.google.Chrome"
    static var profile: String {
        if let custom = ProcessInfo.processInfo.environment["OPENCOMPUTER_AGENT_PROFILE"], !custom.isEmpty { return (custom as NSString).standardizingPath }
        return (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/OpenComputer/AgentBrowser")
    }
    static var profileFlag: String { "--user-data-dir=\(profile)" }
    // Background windows keep painting and running timers; the page accessibility tree
    // exists from the start, so the first observe already sees page content.
    static let flags = ["--no-first-run","--no-default-browser-check","--disable-backgrounding-occluded-windows",
                        "--disable-renderer-backgrounding","--disable-background-timer-throttling","--force-renderer-accessibility=complete"]

    /// The command line of a process, read without spawning anything.
    static func arguments(_ pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }   // executable path
        while index < size, buffer[index] == 0 { index += 1 }   // padding
        var result: [String] = []
        while result.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            result.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }
    /// The app in front shows a fullscreen window (a game, a fullscreen video). Starting
    /// Chrome or making a window can pull the display away from it, so that waits.
    static func fullscreenInFront() -> String? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let root = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        if let window = axElement(attribute(root, kAXFocusedWindowAttribute)) ?? axElement(attribute(root, kAXMainWindowAttribute)),
           attribute(window, "AXFullScreen") as? Bool == true { return front.bundleIdentifier ?? front.localizedName ?? "app" }
        // Games draw a display-sized window instead, often above normal windows (League of
        // Legends uses layer 1000).
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for info in list where (info[kCGWindowOwnerPID as String] as? Int32) == front.processIdentifier && ((info[kCGWindowLayer as String] as? Int) ?? -1) >= 0 {
            guard let raw = info[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { continue }
            if NSScreen.screens.contains(where: { abs($0.frame.width - bounds.width) < 2 && abs($0.frame.height - bounds.height) < 2 }) { return front.bundleIdentifier ?? "app" }
        }
        return nil
    }
    static func isAgent(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == bundle && arguments(app.processIdentifier).contains(profileFlag)
    }
    static func running() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first { !$0.isTerminated && $0.activationPolicy == .regular && isAgent($0) }
    }
    /// First launch only: a named profile, so the person can tell this window from their own.
    static func prepareProfile() {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: profile) else { return }
        try? manager.createDirectory(atPath: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let state: [String: Any] = ["profile": ["info_cache": ["Default": ["name": "Agent", "is_using_default_name": false]]]]
        if let data = try? JSONSerialization.data(withJSONObject: state) { manager.createFile(atPath: (profile as NSString).appendingPathComponent("Local State"), contents: data) }
    }
    static func launch(_ url: URL?) async throws -> NSRunningApplication {
        guard let location = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { try fail("APP_NOT_FOUND", "The agent browser needs Google Chrome installed.") }
        prepareProfile()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        config.createsNewApplicationInstance = true
        config.arguments = [profileFlag] + flags + (url.map { [$0.absoluteString] } ?? [])
        return try await NSWorkspace.shared.openApplication(at: location, configuration: config)
    }
    /// A running instance takes the link as a new tab in its own window; the launcher
    /// process hands it over and exits. Nothing reaches the person's Chrome.
    static func openTab(_ url: URL) throws {
        guard let location = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle),
              let executable = Bundle(url: location)?.executableURL else { try fail("APP_NOT_FOUND", "The agent browser needs Google Chrome installed.") }
        let process = Process()
        process.executableURL = executable
        process.arguments = [profileFlag, url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        if process.isRunning { process.terminate(); try fail("OPEN_FAILED", "The agent browser did not take the link within 10 s.") }
    }
    /// A new tab through the instance's own accessibility tree and keys posted to its
    /// process: nothing is handed over between processes, so Chrome has no reason to come
    /// forward. Returns false when the window or address field cannot be found.
    @MainActor static func openTabInPlace(_ app: NSRunningApplication, _ url: URL) async -> Bool {
        let pid = app.processIdentifier
        let root = AXUIElementCreateApplication(pid)
        // No window left (the last tab was closed): Chrome must make one, and making a
        // window brings Chrome forward for a moment; the focus guard hands it back.
        var fresh = false
        if ((attribute(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []).isEmpty {
            guard let stroke = try? Keys.parse("cmd+n") else { return false }
            Keys.post(stroke, to: pid)
            await waitForWindow(app, seconds: 5)
            fresh = true
        }
        guard let window = (attribute(root, kAXWindowsAttribute) as? [AXUIElement])?.first(where: { attribute($0, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole }) else { return false }
        func addressField() -> AXUIElement? {
            var queue = [window], seen = 0
            while !queue.isEmpty, seen < 400 {
                let item = queue.removeFirst(); seen += 1
                let role = attribute(item, kAXRoleAttribute) as? String
                if role == "AXWebArea" { continue }
                if role == kAXTextFieldRole { return item }
                queue += (attribute(item, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            }
            return nil
        }
        func tabCount() -> Int {
            var queue = [window], count = 0, seen = 0
            while !queue.isEmpty, seen < 400 {
                let item = queue.removeFirst(); seen += 1
                let role = attribute(item, kAXRoleAttribute) as? String
                if role == "AXWebArea" { continue }
                if role == kAXRadioButtonRole || attribute(item, kAXSubroleAttribute) as? String == "AXTabButton" { count += 1; continue }
                queue += (attribute(item, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            }
            return count
        }
        var opened = fresh
        if !fresh {
            let before = tabCount()
            guard let stroke = try? Keys.parse("cmd+t") else { return false }
            Keys.post(stroke, to: pid)
            for _ in 0..<30 { try? await Task.sleep(nanoseconds: 100_000_000); if tabCount() > before { opened = true; break } }
        }
        guard opened, let field = addressField() else { return false }
        _ = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, url.absoluteString as CFString) == .success,
              let enter = try? Keys.parse("Return") else { return false }
        try? await Task.sleep(nanoseconds: 80_000_000)
        Keys.post(enter, to: pid)
        return true
    }
    @MainActor static func waitForWindow(_ app: NSRunningApplication, seconds: Double = 15) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !((attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement]) ?? []).isEmpty { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
