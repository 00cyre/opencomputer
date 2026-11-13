// CI only: answers the macOS question "'Terminal' is requesting to bypass the system private
// window picker and directly access your screen and audio" with Allow, as the person at a
// real Mac does once, so the recorded demo is not covered by it. scripts/ci-allow-terminal.sh
// compiles it to work/ci-capture-alert and scripts/record-demo.sh runs it after a first
// screenshot from Terminal, before recording. It waits up to the given seconds (default 15)
// for the question. With --check it only reports whether the question is on screen.
// Exits 0 when no question is left on screen and 1 when one is.
import AppKit
import ApplicationServices

let arguments = CommandLine.arguments.dropFirst()
let checkOnly = arguments.contains("--check")
let waitSeconds = arguments.compactMap { Double($0) }.first ?? 15

struct Question { let owner: String; let pid: pid_t; let text: String; let buttons: [(title: String, element: AXUIElement)] }

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func onScreenWindows() -> [[String: Any]] {
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
}
func collect(_ element: AXUIElement, depth: Int, texts: inout [String], buttons: inout [(title: String, element: AXUIElement)]) {
    guard depth < 10 else { return }
    let role = attribute(element, kAXRoleAttribute) as? String ?? ""
    let title = attribute(element, kAXTitleAttribute) as? String ?? ""
    let description = attribute(element, kAXDescriptionAttribute) as? String ?? ""
    if role == kAXButtonRole {
        buttons.append((title.isEmpty ? description : title, element))
    } else if role != kAXTextAreaRole {
        // A terminal's text area holds its whole scrollback, which is not a question.
        let value = attribute(element, kAXValueAttribute) as? String ?? ""
        texts += [title, value, description].filter { !$0.isEmpty }
    }
    for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        collect(child, depth: depth + 1, texts: &texts, buttons: &buttons)
    }
}
func findQuestion() -> Question? {
    var seen = Set<pid_t>()
    for window in onScreenWindows() {
        guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, seen.insert(pid).inserted else { continue }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        for axWindow in (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            var texts: [String] = [], buttons: [(title: String, element: AXUIElement)] = []
            collect(axWindow, depth: 0, texts: &texts, buttons: &buttons)
            let text = texts.joined(separator: " ")
            if text.localizedCaseInsensitiveContains("private window picker")
                || (text.localizedCaseInsensitiveContains("bypass") && text.localizedCaseInsensitiveContains("screen")) {
                return Question(owner: window[kCGWindowOwnerName as String] as? String ?? "?", pid: pid, text: text, buttons: buttons)
            }
        }
    }
    return nil
}
func listWindows() {
    print("On-screen windows:")
    for window in onScreenWindows() {
        let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let size = "\(bounds["Width"] ?? 0)x\(bounds["Height"] ?? 0) at \(bounds["X"] ?? 0),\(bounds["Y"] ?? 0)"
        print("  \(window[kCGWindowOwnerName as String] ?? "?") pid \(window[kCGWindowOwnerPID as String] ?? 0) layer \(window[kCGWindowLayer as String] ?? 0) \(size) \"\(window[kCGWindowName as String] ?? "")\"")
    }
}
func frame(_ element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else { return nil }
    var origin = CGPoint.zero, extent = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin), AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &extent) else { return nil }
    return CGRect(origin: origin, size: extent)
}
func click(_ point: CGPoint) {
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(type == .mouseMoved ? 300_000 : 120_000)
    }
}
// What macOS stored for the answer, for the CI log.
func showApprovals() {
    let plutil = Process()
    plutil.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
    plutil.arguments = ["-p", NSHomeDirectory() + "/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"]
    try? plutil.run()
    plutil.waitUntilExit()
}
func gone(within seconds: Double) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    repeat { if findQuestion() == nil { return true }; usleep(250_000) } while Date() < end
    return false
}

print("Accessibility for this tool: \(AXIsProcessTrusted())")
var question = findQuestion()
let deadline = Date().addingTimeInterval(checkOnly ? 0 : waitSeconds)
while question == nil && Date() < deadline { usleep(250_000); question = findQuestion() }
guard let found = question else {
    print(checkOnly ? "No screen capture question on screen." : "No screen capture question came up within \(Int(waitSeconds)) s.")
    exit(0)
}
print("Screen capture question from \(found.owner) (pid \(found.pid)): \(found.text.prefix(240))")
print("Buttons: \(found.buttons.map { $0.title })")
if checkOnly { listWindows(); exit(1) }
guard let allow = found.buttons.first(where: { $0.title.localizedCaseInsensitiveCompare("Allow") == .orderedSame }) else {
    print("It has no Allow button."); listWindows(); exit(1)
}
let pressed = AXUIElementPerformAction(allow.element, kAXPressAction as CFString)
print("Pressed Allow through accessibility: \(pressed == .success ? "ok" : "error \(pressed.rawValue)")")
if gone(within: 3) { print("The question is answered."); showApprovals(); exit(0) }
if let rect = frame(allow.element) {
    print("Clicking Allow at \(Int(rect.midX)),\(Int(rect.midY)).")
    click(CGPoint(x: rect.midX, y: rect.midY))
    if gone(within: 3) { print("The question is answered."); showApprovals(); exit(0) }
}
print("The question is still on screen.")
listWindows()
exit(1)
