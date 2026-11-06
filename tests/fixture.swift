import AppKit

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let field = NSTextField(string: "")
    let status = NSTextField(labelWithString: "Waiting for submission")
    let consent = NSButton(checkboxWithTitle: "Enable test option", target: nil, action: nil)
    let output = ProcessInfo.processInfo.environment["OPENCOMPUTER_FIXTURE_OUTPUT"] ?? "/tmp/opencomputer-fixture.json"
    var submissions = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect:NSRect(x:80,y:80,width:520,height:300), styleMask:[.titled,.closable,.miniaturizable], backing:.buffered, defer:false)
        window.title = "OpenComputer Test Fixture"
        window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString:"Background control benchmark")
        title.font = .systemFont(ofSize:22,weight:.semibold)
        title.frame = NSRect(x:28,y:240,width:460,height:30)
        field.frame = NSRect(x:28,y:180,width:460,height:32)
        field.placeholderString = "Enter benchmark token"
        field.setAccessibilityIdentifier("benchmark-input")
        field.setAccessibilityLabel("Benchmark token")
        consent.frame = NSRect(x:28,y:135,width:460,height:28)
        consent.setAccessibilityIdentifier("benchmark-option")
        let button = NSButton(title:"Submit benchmark", target:self, action:#selector(submit))
        button.frame = NSRect(x:28,y:85,width:200,height:34)
        button.setAccessibilityIdentifier("benchmark-submit")
        status.frame = NSRect(x:28,y:32,width:460,height:35)
        status.setAccessibilityIdentifier("benchmark-status")
        for view in [title,field,consent,button,status] { window.contentView!.addSubview(view) }
        window.orderFrontRegardless()
        save()
    }
    @objc func submit() {
        submissions += 1
        status.stringValue = "Submitted: \(field.stringValue) | option: \(consent.state == .on ? "on" : "off")"
        save()
    }
    func save() {
        let state: [String:Any] = ["token":field.stringValue,"option":consent.state == .on,"submissions":submissions,"frontmostApp":NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"]
        if let data = try? JSONSerialization.data(withJSONObject:state, options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:URL(fileURLWithPath:output), options:.atomic) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
// Accessory launch avoids taking foreground focus before the benchmark starts.
app.setActivationPolicy(.accessory)
app.run()
