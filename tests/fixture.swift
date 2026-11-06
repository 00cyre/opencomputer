import AppKit

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let field = NSTextField(string: "")
    let status = NSTextField(labelWithString: "Waiting for submission")
    let consent = NSButton(checkboxWithTitle: "Enable test option", target: nil, action: nil)
    let output = ProcessInfo.processInfo.environment["OPENCOMPUTER_FIXTURE_OUTPUT"] ?? "/tmp/opencomputer-fixture.json"
    var submissions = 0
    var cover: NSWindow?
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
        if ProcessInfo.processInfo.environment["OPENCOMPUTER_FIXTURE_TOP_RIGHT"] == "1", let screen = NSScreen.screens.first {
            window.setFrameOrigin(NSPoint(x:screen.visibleFrame.maxX-window.frame.width,y:screen.visibleFrame.maxY-window.frame.height))
        }
        if ProcessInfo.processInfo.environment["OPENCOMPUTER_FIXTURE_FOCUS_TRAP"] == "1" {
            let trap = NSButton(title:"Focus trap",target:self,action:#selector(focusTrap))
            trap.frame = NSRect(x:250,y:85,width:160,height:34)
            trap.setAccessibilityIdentifier("focus-trap")
            window.contentView!.addSubview(trap)
        }
        if ProcessInfo.processInfo.environment["OPENCOMPUTER_FIXTURE_OVERLAY_TEST"] == "1" {
            let coverButton = NSButton(title:"Cover ghost",target:self,action:#selector(coverGhost))
            coverButton.frame = NSRect(x:250,y:85,width:160,height:34)
            coverButton.setAccessibilityIdentifier("cover-ghost")
            window.contentView!.addSubview(coverButton)
        }
        window.orderFrontRegardless()
        save()
    }
    @objc func coverGhost() {
        let panel = NSPanel(contentRect:window.frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.backgroundColor = .windowBackgroundColor
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless(); cover = panel
        DispatchQueue.main.asyncAfter(deadline:.now()+1) { panel.close(); self.cover = nil }
    }
    @objc func focusTrap() {
        DispatchQueue.main.asyncAfter(deadline:.now()+0.04) {
            NSApp.activate(ignoringOtherApps:true)
            self.window.makeKeyAndOrderFront(nil)
            self.window.makeFirstResponder(self.field)
        }
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
