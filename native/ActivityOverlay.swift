import AppKit
import ApplicationServices

// These windows are visual annotations, never input or activation targets.
final class AnnotationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }
}

func elementFrame(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
          let s = attribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero; var size = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point),
          AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size),
          size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin: point, size: size)
}
func axElement(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}
func cleanLabel(_ value: String, limit: Int = 100) -> String {
    String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && ![0x202A,0x202B,0x202D,0x202E,0x202C,0x2066,0x2067,0x2068,0x2069].contains(Int($0.value)) }.prefix(limit))
}
struct AgentIdentity {
    let name: String
    let bundle: String?
    let color: NSColor
    init(_ raw: String) {
        let value = raw.lowercased()
        if value.contains("claude") { name = "Claude"; bundle = "com.anthropic.claudefordesktop"; color = NSColor(srgbRed:0.93,green:0.60,blue:0.43,alpha:1) }
        else if value.contains("grok") { name = "Grok"; bundle = "com.anysphere.sand"; color = NSColor(srgbRed:0.76,green:0.70,blue:1,alpha:1) }
        else if value.contains("codex") || value.contains("chatgpt") || value.contains("openai") { name = "ChatGPT"; bundle = "com.openai.codex"; color = NSColor(srgbRed:0.43,green:0.85,blue:0.71,alpha:1) }
        else { name = cleanLabel(raw.isEmpty ? "Agent" : raw, limit: 24); bundle = nil; color = .systemTeal }
    }
    var icon: NSImage? {
        guard let bundle = bundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

final class ActivityView: NSView {
    var expanded = false
    var agent = AgentIdentity("Agent")
    var agentIcon: NSImage?
    var appIcon: NSImage?
    var appName = ""
    var windowTitle = ""
    var action = "Working"
    var blocked = false
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    func text(_ value: String, rect: NSRect, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in: rect, withAttributes: [.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:color,.paragraphStyle:paragraph])
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed:0.10,green:0.11,blue:0.13,alpha:0.96).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx:0.5,dy:0.5), xRadius: expanded ? 18 : 15, yRadius: expanded ? 18 : 15)
        path.fill(); NSColor.white.withAlphaComponent(0.13).setStroke(); path.lineWidth = 1; path.stroke()
        let color: NSColor = blocked ? .systemOrange : agent.color
        if !expanded {
            for i in 0..<3 {
                let phase = Date.timeIntervalSinceReferenceDate * 4.5 - Double(i) * 0.7
                color.withAlphaComponent(0.3 + 0.7 * (sin(phase) + 1) / 2).setFill()
                NSBezierPath(ovalIn:NSRect(x:13 + CGFloat(i)*11,y:12,width:5,height:5)).fill()
            }
            return
        }
        let iconRect = NSRect(x:14,y:14,width:30,height:30)
        if let icon = agentIcon { icon.draw(in:iconRect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil) }
        else { color.setFill(); NSBezierPath(ovalIn:iconRect).fill(); text(String(agent.name.prefix(1)),rect:NSRect(x:24,y:20,width:16,height:22),size:14,color:.white,weight:.semibold) }
        text("→",rect:NSRect(x:51,y:20,width:20,height:24),size:16,color:NSColor.white.withAlphaComponent(0.6))
        appIcon?.draw(in:NSRect(x:77,y:16,width:27,height:27),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        text("\(agent.name) → \(appName)",rect:NSRect(x:114,y:13,width:248,height:20),size:12,color:.white,weight:.semibold)
        text(windowTitle.isEmpty ? appName : windowTitle,rect:NSRect(x:114,y:34,width:248,height:18),size:11,color:NSColor.white.withAlphaComponent(0.64))
        color.setFill(); NSBezierPath(ovalIn:NSRect(x:17,y:64,width:5,height:5)).fill()
        text(action,rect:NSRect(x:31,y:58,width:331,height:20),size:11,color:NSColor.white.withAlphaComponent(0.82))
    }
}

final class GhostView: NSView {
    var tint = NSColor.systemTeal
    var pulseUntil = Date.distantPast
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if pulseUntil > Date() {
            tint.withAlphaComponent(0.16).setFill()
            NSBezierPath(ovalIn:NSRect(x:1,y:1,width:38,height:38)).fill()
        }
        let path = NSBezierPath()
        path.move(to:NSPoint(x:9,y:5)); path.line(to:NSPoint(x:10,y:32)); path.line(to:NSPoint(x:17,y:26))
        path.line(to:NSPoint(x:23,y:39)); path.line(to:NSPoint(x:29,y:36)); path.line(to:NSPoint(x:23,y:24))
        path.line(to:NSPoint(x:33,y:24)); path.close()
        NSColor.white.withAlphaComponent(0.94).setStroke(); path.lineWidth = 2.3; path.stroke()
        tint.setFill(); path.fill()
    }
}

@MainActor
final class ActivityOverlay {
    let panel = AnnotationPanel(size:NSSize(width:54,height:30))
    let ghost = AnnotationPanel(size:NSSize(width:44,height:46))
    let view = ActivityView()
    let ghostView = GhostView()
    let sessionID = "\(getpid())-\(UUID().uuidString)"
    let registry = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("cc.opencomputer.activity-\(getuid())",isDirectory:true)
    var app: NSRunningApplication?
    var window: AXUIElement?
    var pointOffset: CGPoint?
    var windowID: CGWindowID?
    var lastRegistryWrite = Date.distantPast
    var lastWindowRefresh = Date.distantPast
    var lastHover = Date.distantPast
    var active = false
    var ghostReason = "idle"
    var row = 0
    var offset: CGFloat = 0
    var timer: Timer?
    var ghostMotion = GhostMotion()
    var enabled = ProcessInfo.processInfo.environment["OPENCOMPUTER_OVERLAY"] != "0"
    var registryReady = false
    let pointerLocation: () -> NSPoint
    var sessionURL: URL { registry.appendingPathComponent(sessionID + ".json") }
    init(pointer: @escaping () -> NSPoint = { NSEvent.mouseLocation }) {
        pointerLocation = pointer
        view.frame = NSRect(origin:.zero,size:panel.frame.size); panel.contentView = view
        ghostView.frame = NSRect(origin:.zero,size:ghost.frame.size); ghost.contentView = ghostView
        panel.title = "OpenComputer activity"; ghost.title = "OpenComputer ghost cursor"
        ghost.hasShadow = false
        ghost.setAccessibilityHidden(true)
        ghostView.setAccessibilityHidden(true)
        panel.setAccessibilityLabel("OpenComputer activity. Hover to expand.")
        do {
            try FileManager.default.createDirectory(at:registry,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let attrs = try FileManager.default.attributesOfItem(atPath:registry.path)
            registryReady = attrs[.type] as? FileAttributeType == .typeDirectory && (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
        } catch { registryReady = false }
        configure(ProcessInfo.processInfo.environment["OPENCOMPUTER_AGENT"] ?? "Agent")
        timer = Timer.scheduledTimer(withTimeInterval:1.0/60.0,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }
    func configure(_ label: String) {
        view.agent = AgentIdentity(label); view.agentIcon = view.agent.icon; ghostView.tint = view.agent.color
        view.needsDisplay = true
    }
    func track(_ target: NSRunningApplication, element: AXUIElement? = nil, title: String? = nil, captureWindowID: CGWindowID? = nil, captureFrame: CGRect? = nil, action: String) {
        let changed = app?.processIdentifier != target.processIdentifier
        app = target; active = true
        view.appName = cleanLabel(target.localizedName ?? target.bundleIdentifier ?? "App",limit:50)
        if changed { view.appIcon = target.bundleURL.map { NSWorkspace.shared.icon(forFile:$0.path) }; pointOffset = nil; window = nil; windowID = nil }
        let root = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        var selectedWindow = element.flatMap { owningWindow($0) }
            ?? axElement(attribute(root,kAXFocusedWindowAttribute))
            ?? (attribute(root,kAXWindowsAttribute) as? [AXUIElement])?.first
        if let captureFrame = captureFrame {
            selectedWindow = (attribute(root,kAXWindowsAttribute) as? [AXUIElement])?.first {
                guard let rect = elementFrame($0) else { return false }
                return abs(rect.minX-captureFrame.minX) < 3 && abs(rect.minY-captureFrame.minY) < 3 && abs(rect.width-captureFrame.width) < 3 && abs(rect.height-captureFrame.height) < 3
            }
            if selectedWindow == nil { window = nil; pointOffset = nil }
        }
        if let selectedWindow = selectedWindow {
            if window == nil || !CFEqual(window!,selectedWindow) { pointOffset = nil; windowID = nil }
            window = selectedWindow
        }
        if let title = title { view.windowTitle = cleanLabel(title) }
        else if let window = window { view.windowTitle = cleanLabel(attribute(window,kAXTitleAttribute) as? String ?? "") }
        if let captureWindowID = captureWindowID { windowID = captureWindowID }
        if let element = element, let rect = elementFrame(element), let window = window, let frame = elementFrame(window) {
            pointOffset = CGPoint(x:rect.midX-frame.minX,y:rect.midY-frame.minY)
            ghostView.pulseUntil = Date().addingTimeInterval(0.6)
        }
        view.action = cleanLabel(action); view.blocked = false
        lastWindowRefresh = .distantPast
        tick()
    }
    func markWaiting(_ reason: String) { view.blocked = true; view.action = cleanLabel(reason); view.needsDisplay = true }
    func release() {
        active = false; app = nil; window = nil; pointOffset = nil; windowID = nil
        panel.orderOut(nil); ghost.orderOut(nil); view.expanded = false
        ghostMotion = GhostMotion()
        if registryReady { try? FileManager.default.removeItem(at:sessionURL) }
    }
    func shutdown() { timer?.invalidate(); timer = nil; release() }
    func updateRegistry(force: Bool = false) {
        guard registryReady, force || Date().timeIntervalSince(lastRegistryWrite) > 0.5 else { return }
        lastRegistryWrite = Date()
        let record: [String:Any] = ["pid":getpid(),"updated":Date().timeIntervalSince1970,"expanded":view.expanded]
        if let data = try? JSONSerialization.data(withJSONObject:record) {
            try? data.write(to:sessionURL,options:.atomic)
            try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:sessionURL.path)
        }
        let files = (try? FileManager.default.contentsOfDirectory(at:registry,includingPropertiesForKeys:nil)) ?? []
        var peers: [(String,Bool)] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf:file), let record = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let pid = record["pid"] as? Int32, let updated = record["updated"] as? Double,
                  Date().timeIntervalSince1970-updated < 3, kill(pid,0) == 0 else { continue }
            peers.append((file.deletingPathExtension().lastPathComponent,record["expanded"] as? Bool ?? false))
        }
        peers.sort { $0.0 < $1.0 }
        row = peers.firstIndex(where:{$0.0 == sessionID}) ?? 0
        offset = peers.prefix(row).reduce(0) { $0 + ($1.1 ? 84 : 30) + 8 }
    }
    func tick() {
        guard enabled, active, let app = app, !app.isTerminated else {
            if active && app?.isTerminated == true { release() }
            return
        }
        // Polling the pointer gives hover behavior while the panel remains entirely click-through.
        let pointer = pointerLocation()
        if panel.isVisible && panel.frame.insetBy(dx:-5,dy:-5).contains(pointer) { lastHover = Date() }
        let expanded = Date().timeIntervalSince(lastHover) < 0.25
        if view.expanded != expanded { view.expanded = expanded; updateRegistry(force:true) }
        updateRegistry()
        guard let screen = NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let size = NSSize(width:expanded ? 380 : 54,height:expanded ? 84 : 30)
        panel.setFrame(NSRect(x:frame.maxX-size.width-16,y:frame.maxY-size.height-12-offset,width:size.width,height:size.height),display:true)
        view.frame = NSRect(origin:.zero,size:size)
        if !panel.isVisible { panel.orderFrontRegardless() }
        view.needsDisplay = true
        if Date().timeIntervalSince(lastWindowRefresh) >= 0.15 {
            lastWindowRefresh = Date(); refreshGhost()
        }
        if ghost.isVisible, let point = ghostMotion.position(at:Date.timeIntervalSinceReferenceDate) { ghost.setFrameOrigin(point) }
        ghostView.needsDisplay = true
    }
    func refreshGhost() {
        guard let app = app, !app.isHidden, let window = window, let frame = elementFrame(window),
              (attribute(window,kAXMinimizedAttribute) as? Bool) != true else { ghostReason = "hidden-or-no-window"; ghost.orderOut(nil); return }
        let title = cleanLabel(attribute(window,kAXTitleAttribute) as? String ?? "")
        if !title.isEmpty { view.windowTitle = title }
        let offset = pointOffset ?? CGPoint(x:min(40,frame.width/2),y:min(65,frame.height/2))
        let point = CGPoint(x:frame.minX+offset.x,y:frame.minY+offset.y)
        guard frame.contains(point) else { ghostReason = "point-outside-window"; ghost.orderOut(nil); return }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as? [[String:Any]] ?? []
        let onScreen = windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                  let bounds = info[kCGWindowBounds as String] as? [String:Any],
                  let rect = CGRect(dictionaryRepresentation:bounds as CFDictionary) else { return false }
            return abs(rect.minX-frame.minX) < 3 && abs(rect.minY-frame.minY) < 3 && abs(rect.width-frame.width) < 3 && abs(rect.height-frame.height) < 3
        }
        // AX hit-testing respects transparent system windows (for example Dock's full-screen surface).
        // Only inspect the hit owner's PID/window identity; never read another app's content.
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(point.x),Float(point.y),&hit)
        var hitPID: pid_t = 0
        if let hit = hit { AXUIElementGetPid(hit,&hitPID) }
        var sameWindow = false
        if let hit = hit, hitPID == app.processIdentifier {
            let hitWindow = axElement(attribute(hit,kAXWindowAttribute)) ?? ((attribute(hit,kAXRoleAttribute) as? String) == kAXWindowRole ? hit : nil)
            sameWindow = hitWindow.map { CFEqual($0,window) } ?? false
        }
        let visible = onScreen && result == .success && hitPID == app.processIdentifier && sameWindow
        ghostReason = visible ? "visible" : !onScreen ? "offscreen" : result != .success ? "hit-test-unavailable" : "occluded"
        guard visible, let primary = NSScreen.screens.first else { ghost.orderOut(nil); return }
        let cocoa = CGPoint(x:point.x,y:primary.frame.maxY-point.y)
        let origin = NSPoint(x:cocoa.x-9,y:cocoa.y-ghost.frame.height+5)
        ghostMotion.move(to:origin,at:Date.timeIntervalSinceReferenceDate,snap:!ghost.isVisible)
        if let point = ghostMotion.position(at:Date.timeIntervalSinceReferenceDate) { ghost.setFrameOrigin(point) }
        if !ghost.isVisible { ghost.orderFrontRegardless() }
    }
    func state() -> [String:Any] {
        ["enabled":enabled,"active":active,"agent":view.agent.name,"app":app?.bundleIdentifier ?? "", "action":view.action,"windowTitle":view.windowTitle,
         "pillVisible":panel.isVisible,"ghostVisible":ghost.isVisible,"ghostFloating":ghost.isVisible && ghostMotion.isFloating(at:Date.timeIntervalSinceReferenceDate),"ghostReason":ghostReason,"expanded":view.expanded,"stackRow":row,
         "nonActivating":!panel.canBecomeKey && !panel.canBecomeMain && !ghost.canBecomeKey,
         "clickThrough":panel.ignoresMouseEvents && ghost.ignoresMouseEvents,
         "pillWindowId":panel.windowNumber,"ghostWindowId":ghost.windowNumber,
         "pillFrame":["screenY":(NSScreen.screens.first?.frame.maxY ?? 0)-panel.frame.maxY,"x":panel.frame.minX,"y":panel.frame.minY,"width":panel.frame.width,"height":panel.frame.height]]
    }
}
