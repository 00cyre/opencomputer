import AppKit
import ApplicationServices
import ScreenCaptureKit

@MainActor
final class Computer {
    let allowed: Set<String>
    let overlay = ActivityOverlay()
    let focus = FocusGuard()
    let interaction = InteractionGuard()
    var snapshotID = ""
    var snapshotPID: pid_t = 0
    var snapshotBundle = ""
    var elements: [AXUIElement] = []
    var snapshotTime = Date.distantPast
    init() {
        allowed = Set((ProcessInfo.processInfo.environment["OPENCOMPUTER_APPS"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
    func target(_ request: [String: Any]) throws -> NSRunningApplication {
        let bundle = try string(request, "app")
        guard allowed.contains(bundle) || allowed.contains("*") else { try fail("APP_NOT_ALLOWED", "Add \(bundle) to OPENCOMPUTER_APPS before starting this process. No apps are allowed by default.") }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).filter { !$0.isTerminated }
        guard apps.count == 1, let app = apps.first else { try fail("APP_NOT_RUNNING", "Open exactly one instance of \(bundle), then try again.") }
        return app
    }
    func trusted() throws {
        guard AXIsProcessTrusted() else { try fail("ACCESSIBILITY_REQUIRED", "Allow the launching host (Terminal, Claude, Grok, or OpenComputer helper) in System Settings > Privacy & Security > Accessibility, then restart it.") }
    }
    func element(_ request: [String: Any], _ app: NSRunningApplication) throws -> AXUIElement {
        guard try string(request, "snapshot") == snapshotID, app.processIdentifier == snapshotPID,
              app.bundleIdentifier == snapshotBundle, Date().timeIntervalSince(snapshotTime) < 60,
              let index = request["element"] as? Int, elements.indices.contains(index) else {
            try fail("STALE_SNAPSHOT", "Observe the app again and use an element from that snapshot. Snapshots expire after 60 seconds or any action.")
        }
        let item = elements[index]
        if attribute(item, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole {
            try fail("SECURE_FIELD", "Secure text fields are excluded from automation.")
        }
        return item
    }
    func observe(_ app: NSRunningApplication, _ request: [String:Any]) throws -> [String: Any] {
        let applicationRoot = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationRoot, 2)
        let windows = attribute(applicationRoot,kAXWindowsAttribute) as? [AXUIElement] ?? []
        var root = applicationRoot
        if request["root"] != nil {
            guard request["window"] == nil, let index = request["root"] as? Int else { try fail("INVALID_ARGUMENT","Use either window or root, not both.") }
            var reference = request; reference["element"] = index
            root = try element(reference,app)
        } else if let index = request["window"] as? Int {
            guard windows.indices.contains(index) else { try fail("INVALID_WINDOW","Choose a window index returned by observe. Window indices may change; verify the returned title.") }
            root = windows[index]
        }
        elements = []
        snapshotID = UUID().uuidString
        snapshotPID = app.processIdentifier
        snapshotBundle = app.bundleIdentifier ?? ""
        snapshotTime = Date()
        var nodes: [[String: Any]] = []
        var truncated = false
        func walk(_ element: AXUIElement, _ depth: Int, _ parent: Int?) {
            guard elements.count < 600, depth <= 24 else { truncated = true; return }
            if elements.contains(where: { CFEqual($0, element) }) { return }
            let index = elements.count
            elements.append(element)
            let role = attribute(element, kAXRoleAttribute) as? String ?? "AXUnknown"
            let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
            let secure = subrole == kAXSecureTextFieldSubrole
            var node: [String: Any] = ["id": index, "role": role, "depth": depth]
            if let parent = parent { node["parent"] = parent }
            if !subrole.isEmpty { node["subrole"] = subrole }
            for (key, name) in [("title", kAXTitleAttribute), ("description", kAXDescriptionAttribute), ("identifier", kAXIdentifierAttribute), ("value", kAXValueAttribute)] {
                if secure && key == "value" { node[key] = "[redacted]"; continue }
                if let value = attribute(element, name) as? String { node[key] = String(value.prefix(4000)) }
                else if let value = attribute(element, name) as? NSNumber { node[key] = value }
            }
            node["enabled"] = (attribute(element, kAXEnabledAttribute) as? Bool) ?? true
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
            node["settable"] = settable.boolValue && !secure
            var actions: CFArray?
            AXUIElementCopyActionNames(element, &actions)
            node["actions"] = actions as? [String] ?? []
            if let raw = attribute(element, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID(),
               let sizeRaw = attribute(element, kAXSizeAttribute), CFGetTypeID(sizeRaw) == AXValueGetTypeID() {
                var point = CGPoint.zero; var size = CGSize.zero
                AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgPoint, &point)
                AXValueGetValue(unsafeBitCast(sizeRaw, to: AXValue.self), .cgSize, &size)
                node["frame"] = ["x": point.x, "y": point.y, "width": size.width, "height": size.height]
            }
            nodes.append(node)
            if !secure {
                for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth + 1, index) }
            }
        }
        walk(root, 0, nil)
        var result: [String:Any] = ["app": snapshotBundle, "pid": snapshotPID, "snapshot": snapshotID, "nodes": nodes, "truncated": truncated, "frontmostApp": frontmost(),
            "windows":windows.enumerated().map { index, window in ["index":index,"title":attribute(window,kAXTitleAttribute) as? String ?? "","minimized":attribute(window,kAXMinimizedAttribute) as? Bool ?? false] as [String:Any] }]
        if let index = request["window"] as? Int { result["selectedWindow"] = index }
        return result
    }
    func screenshot(_ app: NSRunningApplication, _ request: [String: Any]) async throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else { try fail("SCREEN_RECORDING_REQUIRED", "Allow Screen Recording for the launching host in System Settings, then restart it.") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let windows = content.windows.filter { $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1 }
        guard !windows.isEmpty else { try fail("NO_WINDOW", "No capturable window for this app. Restore a window and try again.") }
        let window: SCWindow
        if let id = request["windowId"] as? UInt32 {
            guard let selected = windows.first(where: { $0.windowID == id }) else { try fail("INVALID_WINDOW", "windowId must belong to the allowed app.") }
            window = selected
        } else {
            guard windows.count == 1 else {
                return ["selectionRequired": true, "windows": windows.map { ["windowId": $0.windowID, "title": $0.title ?? ""] as [String: Any] }]
            }
            window = windows[0]
        }
        overlay.track(app,title:window.title,captureWindowID:window.windowID,captureFrame:window.frame,action:"Capturing window")
        if focus.blocked { overlay.markBlocked() }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = min(1, 1600 / max(window.frame.width, window.frame.height))
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { try fail("CAPTURE_FAILED", "Could not encode screenshot") }
        return ["mimeType": "image/png", "data": png.base64EncodedString(), "width": cgImage.width, "height": cgImage.height, "windowId": window.windowID, "app": app.bundleIdentifier ?? ""]
    }
    func handle(_ request: [String: Any]) async throws -> [String: Any] {
        let method = try string(request, "method")
        switch method {
        case "status":
            return ["helperPid":getpid(), "platform": "macOS", "accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess(), "allowedApps": allowed.sorted(), "frontmostApp": frontmost(), "version": "0.3.0", "activity":overlay.state(), "focusProtectionBlocked":focus.blocked]
        case "configure":
            overlay.configure(try string(request,"agent"))
            return ["agent":overlay.view.agent.name]
        case "release":
            overlay.release(); snapshotID = ""; elements = []
            return ["released":true]
        case "apps":
            let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map {
                ["name": $0.localizedName ?? "", "bundleId": $0.bundleIdentifier ?? "", "pid": $0.processIdentifier, "allowed": allowed.contains("*") || allowed.contains($0.bundleIdentifier ?? "")] as [String: Any]
            }
            return ["apps": apps.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }]
        default: break
        }
        guard ["observe", "screenshot", "checkInteraction", "click", "setValue", "performAction", "pressKey", "typeText", "scroll"].contains(method) else { try fail("UNKNOWN_METHOD", method) }
        let app = try target(request)
        if method == "screenshot" { return try await screenshot(app, request) }
        try trusted()
        if method == "observe" {
            let result = try observe(app,request)
            overlay.track(app,element:elements.first,action:"Reading window")
            if focus.blocked { overlay.markBlocked() }
            return result
        }
        let item = try element(request, app)
        try focus.requireAvailable()
        if method == "checkInteraction" { return interaction.assess(app,element:item).json }
        if method == "pressKey" { try fail("FOCUS_UNSAFE", "Raw keyboard injection is disabled to protect user focus. Use semantic accessibility controls or setValue instead.") }
        if method == "performAction", let action = request["action"] as? String, [kAXShowMenuAction,kAXConfirmAction,kAXCancelAction].contains(action) {
            try fail("FOCUS_UNSAFE", "This action can move focus. Use a specific semantic control instead.")
        }
        let label = cleanLabel((attribute(item,kAXTitleAttribute) as? String) ?? (attribute(item,kAXDescriptionAttribute) as? String) ?? "control",limit:45)
        let verbs = ["click":"Clicking", "setValue":"Editing", "typeText":"Editing", "scroll":"Scrolling", "performAction":"Using"]
        overlay.track(app,element:item,action:"\(verbs[method] ?? "Using") \(label)")
        let before = try focus.begin()
        let decision = interaction.assess(app,element:item,foreground:before)
        if !decision.canProceed {
            focus.cancel()
            overlay.markWaiting(decision.message)
            var details = decision.json
            details["dispatched"] = false
            throw Failure(code:"USER_BUSY",message:decision.message + " Re-observe and check again before retrying; this action was not queued.",details:details)
        }
        var dispatchError: Error?
        do {
        // Consume before dispatch: even a partially failed action must be re-observed.
        snapshotID = ""
        switch method {
        case "click": try axCheck(AXUIElementPerformAction(item, kAXPressAction as CFString), "AXPress")
        case "setValue":
            guard let value = request["value"] as? String, value.utf16.count <= 16000 else { try fail("INVALID_ARGUMENT", "value must be a string of at most 16000 UTF-16 units") }
            try axCheck(AXUIElementSetAttributeValue(item, kAXValueAttribute as CFString, value as CFString), "AXValue")
        case "performAction":
            let action = try string(request, "action")
            let supported = [kAXPressAction, kAXIncrementAction, kAXDecrementAction, kAXPickAction]
            guard supported.contains(action) else { try fail("INVALID_ARGUMENT", "Use a supported action listed in the snapshot") }
            try axCheck(AXUIElementPerformAction(item, action as CFString), action)
        case "typeText":
            let text = try string(request,"text")
            guard text.utf16.count <= 16000,
                  let selected = attribute(item,kAXSelectedTextRangeAttribute), CFGetTypeID(selected) == AXValueGetTypeID(),
                  let current = attribute(item,kAXValueAttribute) as? String else { try fail("FOCUS_UNSAFE", "This control does not expose safe text replacement. Use setValue.") }
            var range = CFRange()
            guard AXValueGetValue(unsafeBitCast(selected,to:AXValue.self),.cfRange,&range), range.location >= 0, range.length >= 0,
                  range.location <= (current as NSString).length, range.length <= (current as NSString).length-range.location else { try fail("INVALID_SELECTION", "Observe the text control again") }
            let replacement = (current as NSString).replacingCharacters(in:NSRange(location:range.location,length:range.length),with:text)
            guard replacement.utf16.count <= 16000 else { try fail("INVALID_ARGUMENT", "Result exceeds 16000 UTF-16 units") }
            try axCheck(AXUIElementSetAttributeValue(item,kAXValueAttribute as CFString,replacement as CFString),"AXValue")
        case "scroll":
            let direction = try string(request, "direction")
            let actions = ["up": "AXScrollUpByPage", "down": "AXScrollDownByPage", "left": "AXScrollLeftByPage", "right": "AXScrollRightByPage"]
            guard let action = actions[direction] else { try fail("INVALID_ARGUMENT", "direction must be up/down/left/right") }
            try axCheck(AXUIElementPerformAction(item, action as CFString), action)
        default: try fail("UNKNOWN_METHOD", method)
        }
        } catch { dispatchError = error }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let (after,changed) = focus.finish()
        if changed {
            overlay.markBlocked()
            try fail("FOCUS_CHANGED", "Focus changed during dispatch; the action may have executed. Further actions in this session are blocked. The user's focus was not restored or overridden.")
        }
        if let error = dispatchError { throw error }
        return ["dispatched":true,"method":method,"frontmostBefore":before.bundle,"frontmostAfter":after.bundle,"focusChanged":false,"verificationRequired":true,"activity":overlay.state()]
    }
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let computer = MainActor.assumeIsolated { Computer() }
func write(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]), let text = String(data:data,encoding:.utf8) { print(text); fflush(stdout) }
}
// Read input off the main thread; keep the AppKit event loop alive between tool calls.
// The semaphore serializes dispatch so a connection still owns exactly one snapshot.
DispatchQueue.global(qos:.userInitiated).async {
    while let line = readLine() {
        let completed = DispatchSemaphore(value:0)
        Task { @MainActor in
            defer { completed.signal() }
            do {
                guard line.utf8.count <= 1_048_576 else { try fail("TOO_LARGE","Request exceeds 1 MiB") }
                guard let data = line.data(using:.utf8), let request = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { try fail("INVALID_JSON","Expected a JSON object") }
                write(["result":try await computer.handle(request)])
            } catch let error as Failure {
                var value: [String:Any] = ["code":error.code,"message":error.message]
                if let details = error.details { value["details"] = details }
                write(["error":value])
            }
            catch { write(["error":["code":"NATIVE_ERROR","message":error.localizedDescription]]) }
        }
        completed.wait()
    }
    DispatchQueue.main.async { computer.overlay.shutdown(); application.terminate(nil) }
}
application.run()
