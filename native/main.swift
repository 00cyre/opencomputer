import AppKit
import ApplicationServices
import ScreenCaptureKit

struct Failure: Error { let code: String; let message: String }
func fail(_ code: String, _ message: String) throws -> Never { throw Failure(code: code, message: message) }
func string(_ request: [String: Any], _ key: String) throws -> String {
    guard let value = request[key] as? String, !value.isEmpty else { try fail("INVALID_ARGUMENT", "\(key) must be a nonempty string") }
    return value
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func axCheck(_ result: AXError, _ operation: String) throws {
    guard result == .success else { try fail("AX_ERROR", "\(operation) failed (AXError \(result.rawValue)). Observe again; the app may not support this action.") }
}
func frontmost() -> String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown" }

final class Computer {
    let allowed: Set<String>
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
        guard allowed.contains(bundle) else { try fail("APP_NOT_ALLOWED", "Add \(bundle) to OPENCOMPUTER_APPS before starting this process. No apps are allowed by default.") }
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
    func observe(_ app: NSRunningApplication) -> [String: Any] {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2)
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
        return ["app": snapshotBundle, "pid": snapshotPID, "snapshot": snapshotID, "nodes": nodes, "truncated": truncated, "frontmostApp": frontmost()]
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
            return ["platform": "macOS", "accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess(), "allowedApps": allowed.sorted(), "frontmostApp": frontmost(), "version": "0.1.0"]
        case "apps":
            let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map {
                ["name": $0.localizedName ?? "", "bundleId": $0.bundleIdentifier ?? "", "pid": $0.processIdentifier, "allowed": allowed.contains($0.bundleIdentifier ?? "")] as [String: Any]
            }
            return ["apps": apps.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }]
        default: break
        }
        guard ["observe", "screenshot", "click", "setValue", "performAction", "pressKey", "typeText", "scroll", "drag"].contains(method) else { try fail("UNKNOWN_METHOD", method) }
        let app = try target(request)
        if method == "screenshot" { return try await screenshot(app, request) }
        try trusted()
        if method == "observe" { return observe(app) }
        let item = try element(request, app)
        let before = frontmost()
        // Consume before dispatch: even a partially failed action must be re-observed.
        snapshotID = ""
        switch method {
        case "click": try axCheck(AXUIElementPerformAction(item, kAXPressAction as CFString), "AXPress")
        case "setValue":
            guard let value = request["value"] as? String, value.utf16.count <= 16000 else { try fail("INVALID_ARGUMENT", "value must be a string of at most 16000 UTF-16 units") }
            try axCheck(AXUIElementSetAttributeValue(item, kAXValueAttribute as CFString, value as CFString), "AXValue")
        case "performAction":
            let action = try string(request, "action")
            let supported = [kAXPressAction, kAXConfirmAction, kAXCancelAction, kAXIncrementAction, kAXDecrementAction, kAXShowMenuAction, kAXPickAction]
            guard supported.contains(action) else { try fail("INVALID_ARGUMENT", "Use a supported action listed in the snapshot") }
            try axCheck(AXUIElementPerformAction(item, action as CFString), action)
        case "pressKey", "typeText":
            try axCheck(AXUIElementSetAttributeValue(item, kAXFocusedAttribute as CFString, kCFBooleanTrue), "AXFocused")
            if method == "typeText" {
                let text = try string(request, "text")
                guard text.utf16.count <= 16000 else { try fail("INVALID_ARGUMENT", "text is too long") }
                // Target the process; never post to the session-wide event tap or clipboard.
                for chunk in text.utf16.map({ $0 }).chunked(20) {
                    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { try fail("EVENT_FAILED", "Could not create keyboard event") }
                    down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    down.postToPid(app.processIdentifier); up.postToPid(app.processIdentifier)
                }
            } else {
                let key = try string(request, "key")
                let codes: [String: CGKeyCode] = ["Return":36,"Tab":48,"Escape":53,"Backspace":51,"Delete":117,"Space":49,"Left":123,"Right":124,"Down":125,"Up":126,"Home":115,"End":119,"PageUp":116,"PageDown":121,"a":0,"c":8,"v":9,"x":7,"z":6]
                let parts = key.split(separator: "+").map(String.init)
                guard let last = parts.last, let code = codes[last] else { try fail("INVALID_ARGUMENT", "Unsupported key. See docs/API.md") }
                var flags: CGEventFlags = []
                for modifier in parts.dropLast() {
                    switch modifier.lowercased() {
                    case "super", "cmd", "meta": flags.insert(.maskCommand)
                    case "ctrl", "control": flags.insert(.maskControl)
                    case "shift": flags.insert(.maskShift)
                    case "alt", "option": flags.insert(.maskAlternate)
                    default: try fail("INVALID_ARGUMENT", "Unknown key modifier")
                    }
                }
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { try fail("EVENT_FAILED", "Could not create key event") }
                    event.flags = flags; event.postToPid(app.processIdentifier)
                }
            }
        case "scroll":
            let direction = try string(request, "direction")
            let actions = ["up": "AXScrollUpByPage", "down": "AXScrollDownByPage", "left": "AXScrollLeftByPage", "right": "AXScrollRightByPage"]
            guard let action = actions[direction] else { try fail("INVALID_ARGUMENT", "direction must be up/down/left/right") }
            try axCheck(AXUIElementPerformAction(item, action as CFString), action)
        case "drag":
            try fail("UNSUPPORTED", "Background coordinate dragging is not supported in 0.1. Use semantic controls or a dedicated app integration.")
        default: try fail("UNKNOWN_METHOD", method)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let after = frontmost()
        return ["dispatched": true, "method": method, "frontmostBefore": before, "frontmostAfter": after, "focusChanged": before != after, "verificationRequired": true]
    }
}
extension Array {
    func chunked(_ size: Int) -> [[Element]] { stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) } }
}

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let computer = Computer()
func write(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text); fflush(stdout) }
}
// A serial line protocol keeps snapshot ownership deterministic.
while let line = readLine() {
    guard line.utf8.count <= 1_048_576 else { write(["error": ["code": "TOO_LARGE", "message": "Request exceeds 1 MiB"]]); continue }
    do {
        guard let data = line.data(using: .utf8), let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { try fail("INVALID_JSON", "Expected a JSON object") }
        let result = try await computer.handle(request)
        write(["result": result])
    } catch let error as Failure { write(["error": ["code": error.code, "message": error.message]]) }
    catch { write(["error": ["code": "NATIVE_ERROR", "message": error.localizedDescription]]) }
}
