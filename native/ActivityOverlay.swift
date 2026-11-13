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

@MainActor
final class ActivityOverlay {
    let panel = AnnotationPanel(size:NSSize(width:ActivityView.pillWidth,height:ActivityView.pillHeight))
    let ghost = AnnotationPanel(size:GhostView.size)
    let glass = NSVisualEffectView()
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
    var lastGhostX: CGFloat?
    var enabled = ProcessInfo.processInfo.environment["OPENCOMPUTER_OVERLAY"] != "0"
    var registryReady = false
    /// The person pressed Take over: mutations are refused until they press Resume.
    /// Survives release, so an agent cannot end the pause by finishing its session.
    var paused = false
    var approvals = ApprovalDesk()
    /// Serial of the newest step, so a failed request can mark only the steps it started.
    var stepSerial = 0
    var revealFrom: CGFloat = 0
    var revealTo: CGFloat = 0
    var revealStart: TimeInterval = 0
    var cardHeight: CGFloat = 0
    var masks: [Int:NSImage] = [:]
    var actionTitles: [String] = []
    /// Called when the person hands control back, so the helper drops snapshots taken before.
    var onResume: (() -> Void)?
    let pointerLocation: () -> NSPoint
    var sessionURL: URL { registry.appendingPathComponent(sessionID + ".json") }
    init(pointer: @escaping () -> NSPoint = { NSEvent.mouseLocation }) {
        pointerLocation = pointer
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.frame = NSRect(origin:.zero,size:panel.frame.size)
        glass.autoresizingMask = [.width,.height]
        view.frame = glass.bounds
        view.autoresizingMask = [.width,.height]
        glass.addSubview(view)
        panel.contentView = glass
        ghostView.frame = NSRect(origin:.zero,size:ghost.frame.size); ghost.contentView = ghostView
        panel.title = "OpenComputer activity"; ghost.title = "OpenComputer ghost cursor"
        ghost.hasShadow = false
        ghost.setAccessibilityHidden(true)
        ghostView.setAccessibilityHidden(true)
        panel.setAccessibilityLabel("OpenComputer activity. Hover to expand.")
        view.onButton = { [weak self] button in MainActor.assumeIsolated { self?.press(button) } }
        applyMask()
        do {
            try FileManager.default.createDirectory(at:registry,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let attrs = try FileManager.default.attributesOfItem(atPath:registry.path)
            registryReady = attrs[.type] as? FileAttributeType == .typeDirectory && (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
        } catch { registryReady = false }
        configure(ProcessInfo.processInfo.environment["OPENCOMPUTER_AGENT"] ?? "Agent")
        timer = Timer.scheduledTimer(withTimeInterval:1.0/60.0,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }
    func configure(_ label: String) {
        view.agent = AgentIdentity(label); view.agentIcon = view.agent.icon
        ghostView.tint = view.agent.color; ghostView.name = view.agent.name
        view.needsDisplay = true; ghostView.needsDisplay = true
    }
    func track(_ target: NSRunningApplication, element: AXUIElement? = nil, title: String? = nil, captureWindowID: CGWindowID? = nil, captureFrame: CGRect? = nil, action: String) {
        let changed = app?.processIdentifier != target.processIdentifier
        if !active { view.startedAt = Date(); view.steps = [] }
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
        record(view.action)
        lastWindowRefresh = .distantPast
        tick()
    }
    /// Adds a step to the card's timeline; repeating the current step only clears its wait.
    func record(_ text: String) {
        if let last = view.steps.indices.last, view.steps[last].open {
            if view.steps[last].text == text { view.steps[last].state = .running; view.steps[last].detail = nil; return }
            view.steps[last].state = .done
        }
        stepSerial += 1
        view.steps.append(ActivityStep(text:text,detail:nil,state:.running,started:Date(),serial:stepSerial))
        if view.steps.count > 8 { view.steps.removeFirst(view.steps.count - 8) }
    }
    func markWaiting(_ reason: String) {
        view.blocked = true; view.action = cleanLabel(reason)
        if let last = view.steps.indices.last, view.steps[last].open { view.steps[last].state = .waiting; view.steps[last].detail = cleanLabel(reason) }
        view.needsDisplay = true
    }
    /// Shows why a request that started steps did not finish them.
    func settle(since serial: Int, code: String) {
        guard let last = view.steps.indices.last, view.steps[last].serial > serial, view.steps[last].open else { return }
        let reasons = ["PAUSED_BY_USER":"stopped, you took over","APPROVAL_DENIED":"you declined","TARGET_CHANGED":"the page changed",
                       "STALE_ELEMENT":"the control is gone","STALE_SNAPSHOT":"needs a fresh look","UNSUPPORTED_ACTION":"not supported here",
                       "SECURE_FIELD":"secure field","FOCUS_UNSAFE":"would steal focus"]
        switch code {
        case "USER_BUSY", "APPROVAL_PENDING": return
        default:
            view.steps[last].state = .failed
            view.steps[last].detail = reasons[code] ?? code.lowercased().replacingOccurrences(of:"_",with:" ")
        }
        view.needsDisplay = true
    }
    func press(_ button: CardButton) {
        switch button {
        case .takeOver: takeOver()
        case .resume: resume()
        case .allow: approvals.answer(true,now:Date())
        case .deny: approvals.answer(false,now:Date())
        }
        tick()
    }
    func takeOver() {
        paused = true; approvals.cancel()
        if let last = view.steps.indices.last, view.steps[last].open { view.steps[last].state = .done }
        view.needsDisplay = true
    }
    func resume() {
        paused = false; view.blocked = false; view.needsDisplay = true
        // The person may have changed anything while they had control.
        onResume?()
    }
    /// Refuses a mutation while the person has taken over, and shows them how to resume.
    func ensureNotPaused(_ target: NSRunningApplication?) throws {
        guard paused else { return }
        if !active, let target { track(target,action:"Waiting for you to resume") }
        throw Failure(code:"PAUSED_BY_USER",message:"The person pressed Take over on the activity indicator, so nothing was dispatched. Actions stay refused until they press Resume there. Ask them in chat if you need to continue, then observe again before acting.",details:["dispatched":false])
    }
    /// Shows an approval question on the card and waits up to `wait` seconds for an answer.
    /// `.waiting` means no answer yet (or the person took over); the question stays up and a
    /// retry of the same action picks up the answer.
    func requestApproval(key: String, title: String, detail: String, wait: TimeInterval) async -> ApprovalDesk.Outcome {
        let deadline = Date().addingTimeInterval(wait)
        while true {
            if paused { return .waiting }
            let outcome = approvals.ask(key:key,title:cleanLabel(title,limit:120),detail:cleanLabel(detail,limit:160),now:Date())
            tick()
            if outcome != .waiting || Date() >= deadline { return outcome }
            try? await Task.sleep(nanoseconds:100_000_000)
        }
    }
    func release() {
        active = false; app = nil; window = nil; pointOffset = nil; windowID = nil
        panel.orderOut(nil); ghost.orderOut(nil); view.expanded = false
        revealFrom = 0; revealTo = 0; view.reveal = 0; cardHeight = 0
        approvals.cancel(); view.approval = nil; view.steps = []; view.blocked = false
        ghostMotion = GhostMotion(); lastGhostX = nil
        if registryReady { try? FileManager.default.removeItem(at:sessionURL) }
    }
    func shutdown() { timer?.invalidate(); timer = nil; release() }
    func updateRegistry(force: Bool = false) {
        guard registryReady, force || Date().timeIntervalSince(lastRegistryWrite) > 0.5 else { return }
        lastRegistryWrite = Date()
        let height = view.expanded ? Double(view.expandedHeight) : Double(ActivityView.pillHeight)
        let record: [String:Any] = ["pid":getpid(),"updated":Date().timeIntervalSince1970,"expanded":view.expanded,"height":height]
        if let data = try? JSONSerialization.data(withJSONObject:record) {
            try? data.write(to:sessionURL,options:.atomic)
            try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:sessionURL.path)
        }
        let files = (try? FileManager.default.contentsOfDirectory(at:registry,includingPropertiesForKeys:nil)) ?? []
        var peers: [(String,CGFloat)] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf:file), let record = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let pid = record["pid"] as? Int32, let updated = record["updated"] as? Double,
                  Date().timeIntervalSince1970-updated < 3, kill(pid,0) == 0 else { continue }
            // Older helpers report only expanded/collapsed.
            let fallback: CGFloat = (record["expanded"] as? Bool ?? false) ? 84 : 30
            peers.append((file.deletingPathExtension().lastPathComponent,(record["height"] as? Double).map { CGFloat($0) } ?? fallback))
        }
        peers.sort { $0.0 < $1.0 }
        row = peers.firstIndex(where:{$0.0 == sessionID}) ?? 0
        offset = peers.prefix(row).reduce(0) { $0 + $1.1 + 8 }
    }
    func animateReveal(to target: CGFloat) {
        revealFrom = currentReveal(); revealTo = target; revealStart = Date.timeIntervalSinceReferenceDate
    }
    func currentReveal() -> CGFloat {
        let duration = revealTo > revealFrom ? 0.28 : 0.18
        return revealFrom + (revealTo - revealFrom) * easeOut(CGFloat((Date.timeIntervalSinceReferenceDate - revealStart) / duration))
    }
    func applyMask() {
        let radius = Int(ActivityView.radius(view.reveal).rounded())
        if masks[radius] == nil { masks[radius] = ActivityOverlay.mask(radius:CGFloat(radius)) }
        glass.maskImage = masks[radius]
    }
    /// A stretchable rounded rectangle, so the glass keeps its corners at any size.
    static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size:NSSize(width:edge,height:edge),flipped:false) { rect in
            NSColor.black.setFill(); NSBezierPath(roundedRect:rect,xRadius:radius,yRadius:radius).fill(); return true
        }
        image.capInsets = NSEdgeInsets(top:radius,left:radius,bottom:radius,right:radius)
        image.resizingMode = .stretch
        return image
    }
    func tick() {
        guard enabled, active, let app = app, !app.isTerminated else {
            if active && app?.isTerminated == true { release() }
            return
        }
        let now = Date()
        approvals.expire(now)
        view.approval = approvals.pending
        view.paused = paused
        // Polling the pointer gives hover behavior without the dots ever taking a click.
        let pointer = pointerLocation()
        if panel.isVisible && panel.frame.insetBy(dx:-5,dy:-5).contains(pointer) { lastHover = now }
        // An approval question opens the card by itself; otherwise hover opens it.
        let expanded = now.timeIntervalSince(lastHover) < 0.25 || view.approval != nil
        if view.expanded != expanded { view.expanded = expanded; animateReveal(to:expanded ? 1 : 0); updateRegistry(force:true) }
        updateRegistry()
        view.advanceHold(now:now)
        // Assistive apps can stop or decline, never grant: Allow needs a person's held click.
        let offered = view.buttons.filter { !$0.needsHold }
        let titles = offered.map { $0.title }
        if titles != actionTitles {
            actionTitles = titles
            view.setAccessibilityCustomActions(offered.map { button in
                NSAccessibilityCustomAction(name:button.title) { [weak self] in _ = MainActor.assumeIsolated { self?.press(button) }; return true }
            })
        }
        let reveal = currentReveal()
        view.reveal = reveal
        guard let screen = NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        // Height changes (a new step, an approval) glide instead of jumping.
        cardHeight = cardHeight == 0 || reveal < 0.05 ? view.expandedHeight : cardHeight + (view.expandedHeight - cardHeight) * 0.3
        if abs(cardHeight - view.expandedHeight) < 0.5 { cardHeight = view.expandedHeight }
        let size = NSSize(width:round(ActivityView.pillWidth + (ActivityView.cardWidth - ActivityView.pillWidth) * reveal),
                          height:round(ActivityView.pillHeight + (cardHeight - ActivityView.pillHeight) * reveal))
        let target = NSRect(x:frame.maxX-size.width-16,y:frame.maxY-size.height-12-offset,width:size.width,height:size.height)
        if panel.frame != target {
            panel.setFrame(target,display:true)
            applyMask()
            panel.invalidateShadow()
        }
        // Only the fully open card takes clicks, for its buttons. The dots and the ghost never do.
        panel.ignoresMouseEvents = !(view.expanded && reveal > 0.95)
        view.hovered = view.button(at:NSPoint(x:pointer.x - panel.frame.minX,y:panel.frame.maxY - pointer.y))
        if !panel.isVisible { panel.orderFrontRegardless() }
        view.needsDisplay = true
        if Date().timeIntervalSince(lastWindowRefresh) >= 0.15 {
            lastWindowRefresh = Date(); refreshGhost()
        }
        if ghost.isVisible, let point = ghostMotion.position(at:Date.timeIntervalSinceReferenceDate) {
            // Lean a little into horizontal travel, then settle upright.
            let dx = lastGhostX.map { point.x - $0 } ?? 0
            lastGhostX = point.x
            ghostView.tilt += (max(-9,min(9,dx * 0.8)) - ghostView.tilt) * 0.18
            ghost.setFrameOrigin(point)
        } else { lastGhostX = nil; ghostView.tilt = 0 }
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
        let origin = NSPoint(x:cocoa.x-GhostView.tip.x,y:cocoa.y-ghost.frame.height+GhostView.tip.y)
        ghostMotion.move(to:origin,at:Date.timeIntervalSinceReferenceDate,snap:!ghost.isVisible)
        if let point = ghostMotion.position(at:Date.timeIntervalSinceReferenceDate) { ghost.setFrameOrigin(point) }
        if !ghost.isVisible { ghost.orderFrontRegardless() }
    }
    func state() -> [String:Any] {
        ["enabled":enabled,"active":active,"agent":view.agent.name,"app":app?.bundleIdentifier ?? "", "action":view.action,"windowTitle":view.windowTitle,
         "pillVisible":panel.isVisible,"ghostVisible":ghost.isVisible,"ghostFloating":ghost.isVisible && ghostMotion.isFloating(at:Date.timeIntervalSinceReferenceDate),"ghostReason":ghostReason,"expanded":view.expanded,"stackRow":row,
         "nonActivating":!panel.canBecomeKey && !panel.canBecomeMain && !ghost.canBecomeKey,
         "paused":paused,"approvalPending":approvals.pending != nil,"steps":view.steps.count,"controlsInteractive":!panel.ignoresMouseEvents,
         "clickThrough":panel.ignoresMouseEvents && ghost.ignoresMouseEvents,
         "pillWindowId":panel.windowNumber,"ghostWindowId":ghost.windowNumber,
         "pillFrame":["screenY":(NSScreen.screens.first?.frame.maxY ?? 0)-panel.frame.maxY,"x":panel.frame.minX,"y":panel.frame.minY,"width":panel.frame.width,"height":panel.frame.height],
         "buttons":buttonCenters()]
    }
    /// Centers of the open card's buttons in screen points from the top left, for tests and the demo.
    func buttonCenters() -> [[String:Any]] {
        guard view.expanded, view.reveal > 0.9 else { return [] }
        let top = (NSScreen.screens.first?.frame.maxY ?? 0) - panel.frame.maxY
        return view.buttonFrames().map { ["title":$0.0.title,"x":panel.frame.minX + $0.1.midX,"y":top + $0.1.midY] }
    }
}
