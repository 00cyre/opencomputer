import AppKit
import ApplicationServices
import ScreenCaptureKit

// Element IDs stay valid until the next full observe of the same app; expanding a
// subtree adds to the snapshot instead of replacing it.
final class Snapshot {
    let id = UUID().uuidString
    let pid: pid_t
    let bundle: String
    var elements: [AXUIElement] = []
    var index: [CFHashCode:[Int]] = [:]
    var time = Date()
    // What observe saw around each element; TargetGuard checks it before every dispatch.
    var parents: [Int:Int] = [:]
    var places: [Int:Place] = [:]
    var windows: [Int:WindowMark] = [:]
    var pages: [Int:PageMark] = [:]
    // Role and label as observed, for logging an element that has since gone away.
    var described: [Int:[String:Any]] = [:]
    init(pid: pid_t, bundle: String) { self.pid = pid; self.bundle = bundle }
    func contains(_ element: AXUIElement) -> Bool { index[CFHash(element)]?.contains(where: { CFEqual(elements[$0],element) }) ?? false }
    func register(_ element: AXUIElement) -> Int {
        let hash = CFHash(element)
        if let found = index[hash]?.first(where: { CFEqual(elements[$0],element) }) { return found }
        elements.append(element)
        index[hash,default:[]].append(elements.count-1)
        return elements.count-1
    }
}

@MainActor
final class Computer {
    let allowed: Set<String>
    let overlay = ActivityOverlay()
    let focus = FocusGuard()
    let interaction = InteractionGuard()
    var snapshots: [pid_t:Snapshot] = [:]
    var captures: [pid_t:Capture] = [:]
    var webEnabled: Set<pid_t> = []
    let defaultWait: Int
    let log = ActionLog(ProcessInfo.processInfo.environment)
    let approvalPolicy = ApprovalPolicy(ProcessInfo.processInfo.environment["OPENCOMPUTER_CONFIRM"])
    static let observed = [kAXRoleAttribute,kAXSubroleAttribute,kAXTitleAttribute,kAXDescriptionAttribute,kAXIdentifierAttribute,kAXValueAttribute,
                           kAXEnabledAttribute,kAXFocusedAttribute,kAXSelectedAttribute,kAXPlaceholderValueAttribute,kAXPositionAttribute,kAXSizeAttribute,kAXChildrenAttribute]
    static let rowRoles: Set<String> = [kAXListRole,kAXTableRole,kAXOutlineRole,kAXScrollAreaRole,"AXCollection"]
    static let textRoles = [kAXTextFieldRole,kAXTextAreaRole,kAXComboBoxRole,"AXSearchField"]
    // Chromium and Firefox build their web accessibility tree only when asked.
    static let browsers = ["com.google.Chrome","com.brave.Browser","com.microsoft.edgemac","company.thebrowser.Browser","com.vivaldi.Vivaldi","com.operasoftware.Opera","org.chromium.Chromium","com.google.chrome.for.testing","org.mozilla.firefox","ai.perplexity.comet","com.openai.atlas"]
    init() {
        let env = ProcessInfo.processInfo.environment
        allowed = Set((env["OPENCOMPUTER_APPS"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        defaultWait = min(10000,max(0,Int(env["OPENCOMPUTER_WAIT_MS"] ?? "") ?? 2000))
        log.write(["event":"session","version":Computer.version,"helperPid":getpid(),"clients":ancestry(getppid()),"apps":allowed.sorted(),"agent":cleanLabel(env["OPENCOMPUTER_AGENT"] ?? "Agent",limit:100)])
        // After the person had control, element IDs from before are stale: the agent must look again.
        overlay.onResume = { [weak self] in self?.snapshots = [:]; self?.captures = [:] }
    }
    static let version = "0.4.4"
    func permit(_ request: [String: Any]) throws -> String {
        let bundle = try string(request, "app")
        guard allowed.contains(bundle) || allowed.contains("*") else { try fail("APP_NOT_ALLOWED", "Add \(bundle) to OPENCOMPUTER_APPS before starting this process. No apps are allowed by default.") }
        return bundle
    }
    func target(_ request: [String: Any]) throws -> NSRunningApplication {
        let bundle = try permit(request)
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).filter { !$0.isTerminated }
        if let pid = request["pid"] as? Int {
            guard let app = apps.first(where: { Int($0.processIdentifier) == pid }) else { try fail("APP_NOT_RUNNING", "No running instance of \(bundle) has pid \(pid). Call apps for current pids.") }
            return app
        }
        if let id = request["snapshot"] as? String, let snapshot = snapshots.values.first(where: { $0.id == id && $0.bundle == bundle }),
           let app = apps.first(where: { $0.processIdentifier == snapshot.pid }) { return app }
        guard !apps.isEmpty else { try fail("APP_NOT_RUNNING", "\(bundle) is not running. Call open to launch it in the background, then observe.") }
        // Helper and background instances share a bundle ID with the app people see.
        let regular = apps.filter { $0.activationPolicy == .regular }
        let pool = regular.isEmpty ? apps : regular
        if pool.count == 1 { return pool[0] }
        return pool.first { !((attribute(AXUIElementCreateApplication($0.processIdentifier),kAXWindowsAttribute) as? [AXUIElement]) ?? []).isEmpty } ?? pool[0]
    }
    func trusted() throws {
        guard AXIsProcessTrusted() else { try fail("ACCESSIBILITY_REQUIRED", "Allow the launching host (Terminal, Claude, Grok, or OpenComputer helper) in System Settings > Privacy & Security > Accessibility, then restart it.") }
    }
    func resolve(_ request: [String: Any], _ app: NSRunningApplication, key: String = "element") throws -> (snapshot: Snapshot, index: Int, element: AXUIElement) {
        guard let snapshot = snapshots[app.processIdentifier], (request["snapshot"] as? String) == snapshot.id,
              Date().timeIntervalSince(snapshot.time) < 300, let index = request[key] as? Int, snapshot.elements.indices.contains(index) else {
            try fail("STALE_SNAPSHOT", "Observe the app again and use an element from that snapshot. A snapshot is replaced by the next full observe of the same app and expires after 5 minutes.")
        }
        let item = snapshot.elements[index]
        if key == "element" { note?.merge(["target":isAlive(item) ? describeForLog(item) : snapshot.described[index] ?? [:]].merging(whereabouts(item,in:snapshot)) { a, _ in a }) }
        try snapshot.verify(index)
        if attribute(item, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole {
            try fail("SECURE_FIELD", "Secure text fields are excluded from automation.")
        }
        return (snapshot,index,item)
    }
    func element(_ request: [String: Any], _ app: NSRunningApplication, key: String = "element") throws -> AXUIElement { try resolve(request,app,key:key).element }
    func label(_ element: AXUIElement) -> String {
        let names = [kAXTitleAttribute,kAXDescriptionAttribute].compactMap { attribute(element,$0) as? String }.filter { !$0.isEmpty }
        return cleanLabel(names.first ?? roleOf(element).replacingOccurrences(of:"AX",with:""),limit:45)
    }
    func describe(_ element: AXUIElement) -> [String:Any] { ["role":roleOf(element),"label":label(element)] }
    func enableWeb(_ app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        guard !webEnabled.contains(pid) else { return false }
        webEnabled.insert(pid)
        let root = AXUIElementCreateApplication(pid)
        var enabled = AXUIElementSetAttributeValue(root,"AXManualAccessibility" as CFString,kCFBooleanTrue) == .success
        if let bundle = app.bundleIdentifier, Computer.browsers.contains(where: { bundle.hasPrefix($0) }) {
            enabled = AXUIElementSetAttributeValue(root,"AXEnhancedUserInterface" as CFString,kCFBooleanTrue) == .success || enabled
        }
        return enabled
    }
    // One IPC round trip per element instead of one per attribute.
    func values(_ element: AXUIElement) -> [CFTypeRef?] {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element,Computer.observed as CFArray,AXCopyMultipleAttributeOptions(rawValue:0),&raw) == .success,
              let list = raw as? [AnyObject], list.count == Computer.observed.count else { return Computer.observed.map { attribute(element,$0) } }
        return list.map { value in
            if value is NSNull { return nil }
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(unsafeBitCast(value,to:AXValue.self)) == .axError { return nil }
            return value
        }
    }
    func observe(_ app: NSRunningApplication, _ request: [String:Any]) async throws -> [String: Any] {
        let started = Date()
        let pid = app.processIdentifier
        let applicationRoot = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(applicationRoot, 2)
        let webJustEnabled = enableWeb(app)
        if webJustEnabled { try? await Task.sleep(nanoseconds:350_000_000) }
        let windows = attribute(applicationRoot,kAXWindowsAttribute) as? [AXUIElement] ?? []
        let main = axElement(attribute(applicationRoot,kAXMainWindowAttribute)) ?? axElement(attribute(applicationRoot,kAXFocusedWindowAttribute))
        let menu = request["menu"] as? Bool ?? false
        var request = request
        if let title = request["windowTitle"] as? String, !title.isEmpty {
            guard request["window"] == nil else { try fail("INVALID_ARGUMENT","Use window or windowTitle, not both.") }
            let titles = windows.map { (attribute($0,kAXTitleAttribute) as? String ?? "") }
            guard let index = titles.firstIndex(where: { $0 == title }) ?? titles.firstIndex(where: { $0.localizedCaseInsensitiveContains(title) }) else {
                throw Failure(code:"INVALID_WINDOW",message:"No window title contains \(quoted(title)).",details:["titles":titles])
            }
            request["window"] = index
        }
        guard [request["root"] != nil, request["window"] != nil, menu].filter({ $0 }).count <= 1 else { try fail("INVALID_ARGUMENT","Use only one of window, root, or menu.") }
        var roots: [AXUIElement]
        var snapshot = snapshots[pid]
        // A subtree expansion inherits the window and page its root was seen in.
        var start = (parent: Int?.none, place: Place())
        if request["root"] != nil {
            let root = try resolve(request,app,key:"root")
            roots = [root.element]
            start = (root.snapshot.parents[root.index],root.snapshot.places[root.index] ?? Place())
        } else if menu {
            guard let bar = axElement(attribute(applicationRoot,kAXMenuBarAttribute)) else { try fail("UNSUPPORTED_TARGET","This app does not expose a menu bar.") }
            roots = [bar]
            if snapshot == nil || Date().timeIntervalSince(snapshot!.time) >= 300 { snapshot = nil }
        } else {
            if let index = request["window"] as? Int {
                guard windows.indices.contains(index) else { try fail("INVALID_WINDOW","Choose a window index returned by observe. Window indices may change; verify the returned title.") }
                roots = [windows[index]]
            } else {
                roots = windows.sorted { a, _ in main.map { CFEqual(a,$0) } ?? false }
                if roots.isEmpty { roots = [applicationRoot] }
            }
            snapshot = nil
        }
        let current = snapshot ?? Snapshot(pid:pid,bundle:app.bundleIdentifier ?? "")
        current.time = Date()
        snapshots[pid] = current
        let limit = min(5000,max(1,request["limit"] as? Int ?? 1200))
        let budget = Double(min(15000,max(1000,request["budgetMs"] as? Int ?? 4000)))/1000
        let deadline = started.addingTimeInterval(budget)
        var nodes: [[String: Any]] = []
        var seen: Set<Int> = []
        var truncated = false
        var hidden: [(index:Int,depth:Int,place:Place,frame:CGRect)] = []
        var deferred: [(index:Int,depth:Int,place:Place,children:[AXUIElement])] = []
        // Moves nodes appended since `from` to just after their container, in reading order.
        func placeAfter(_ container: Int, from: Int) {
            guard nodes.count > from else { return }
            let moved = Array(nodes[from...])
            nodes.removeSubrange(from...)
            if let at = nodes.firstIndex(where: { ($0["id"] as? Int) == container }) { nodes.insert(contentsOf:moved,at:at+1) }
            else { nodes.append(contentsOf:moved) }
        }
        func walk(_ element: AXUIElement, _ depth: Int, _ parent: Int?, _ inherited: Place) {
            guard nodes.count < limit, depth <= 60, Date() < deadline else { truncated = true; return }
            let index = current.register(element)
            guard seen.insert(index).inserted else { return }
            let v = values(element)
            let role = v[0] as? String ?? "AXUnknown"
            let subrole = v[1] as? String ?? ""
            let secure = subrole == kAXSecureTextFieldSubrole
            var place = inherited
            if role == kAXWindowRole {
                place = Place(window:index,page:nil)
                current.windows[index] = WindowMark(title:v[2] as? String ?? "")
            } else if role == "AXWebArea" {
                place.page = index
                if let url = pageURL(element) { current.pages[index] = PageMark(url:url) }
            } else if subrole == "AXTabButton", let w = place.window {
                if current.windows[w]?.tabs.contains(index) == false { current.windows[w]?.tabs.append(index) }
                if current.windows[w]?.tab == nil, (v[5] as? NSNumber)?.intValue == 1 || v[8] as? Bool == true {
                    current.windows[w]?.tab = index
                    current.windows[w]?.tabTitle = v[2] as? String ?? ""
                }
            }
            current.note(index,parent:parent,place:place)
            var seenAs: [String:Any] = ["role":role]
            if !subrole.isEmpty { seenAs["subrole"] = subrole }
            if let name = [v[2],v[3]].compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) { seenAs["label"] = cleanLabel(name,limit:80) }
            if let identifier = v[4] as? String, !identifier.isEmpty { seenAs["identifier"] = cleanLabel(identifier,limit:60) }
            current.described[index] = seenAs
            var node: [String: Any] = ["id": index, "role": role, "depth": depth]
            if let parent = parent { node["parent"] = parent }
            if !subrole.isEmpty { node["subrole"] = subrole }
            for (key, value) in [("title",v[2]),("description",v[3]),("identifier",v[4]),("value",v[5]),("placeholder",v[9])] {
                if secure && key == "value" { node[key] = "[redacted]"; continue }
                if let text = value as? String { if !text.isEmpty || key == "value" { node[key] = String(text.prefix(4000)) } }
                else if let number = value as? NSNumber { node[key] = number }
            }
            node["enabled"] = (v[6] as? Bool) ?? true
            if v[7] as? Bool == true { node["focused"] = true }
            if v[8] as? Bool == true { node["selected"] = true }
            let text = Computer.textRoles.contains(role)
            node["settable"] = !secure && role != kAXStaticTextRole && (text || v[5] != nil) && isSettable(element,kAXValueAttribute)
            node["actions"] = role == kAXStaticTextRole ? [] : actionNames(element)
            if let p = v[10], let s = v[11], CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() {
                var point = CGPoint.zero; var size = CGSize.zero
                AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point)
                AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size)
                node["frame"] = ["x": point.x, "y": point.y, "width": size.width, "height": size.height]
            }
            nodes.append(node)
            let children = v[12] as? [AXUIElement] ?? []
            if !secure {
                // Long lists (a file panel on a big folder) wait until the rest of the window
                // is read, so its buttons are never lost to the time budget.
                if children.count > 60, Computer.rowRoles.contains(role) || role == "AXBrowser" || role == "AXGrid" {
                    deferred.append((index,depth,place,children))
                } else {
                    for child in children { walk(child, depth + 1, index, place) }
                }
            }
            // Some apps (Telegram) report rows on a list but expose none as children.
            if children.isEmpty, Computer.rowRoles.contains(role), let frame = node["frame"] as? [String:CGFloat] {
                hidden.append((index,depth,place,CGRect(x:frame["x"]!,y:frame["y"]!,width:frame["width"]!,height:frame["height"]!)))
            }
        }
        for root in roots { walk(root, 0, start.parent, start.place) }
        for list in deferred {
            let before = nodes.count
            for child in list.children { walk(child, list.depth + 1, list.index, list.place) }
            placeAfter(list.index, from:before)
        }
        // Recover those rows by hit-testing the list's visible area, then walk each find.
        var discovered = 0
        for list in hidden {
            var visible = list.frame
            if let w = list.place.window, let wf = elementFrame(current.elements[w]) { visible = visible.intersection(wf) }
            if let p = current.parents[list.index], let pf = elementFrame(current.elements[p]), pf.width > 1, pf.height > 1 { visible = visible.intersection(pf) }
            guard !visible.isNull, visible.width >= 8, visible.height >= 8 else { continue }
            var found: [(AXUIElement,CGPoint)] = []
            var probes = 0
            var y = visible.minY + 4
            while y < visible.maxY, probes < 4000, Date() < deadline {
                var x = visible.minX + 12
                while x < visible.maxX, probes < 4000 {
                    probes += 1
                    var hit: AXUIElement?
                    if AXUIElementCopyElementAtPosition(applicationRoot,Float(x),Float(y),&hit) == .success, let hit,
                       !current.contains(hit), !found.contains(where: { CFEqual($0.0,hit) }),
                       ![kAXWindowRole,kAXApplicationRole].contains(roleOf(hit)) {
                        found.append((hit,elementFrame(hit)?.origin ?? CGPoint(x:x,y:y)))
                    }
                    x += 24
                }
                y += 8
            }
            guard !found.isEmpty else { continue }
            found.sort { ($0.1.y,$0.1.x) < ($1.1.y,$1.1.x) }
            let before = nodes.count
            for (element,_) in found { walk(element, list.depth + 1, list.index, list.place) }
            guard nodes.count > before else { continue }
            for i in before..<nodes.count { nodes[i]["via"] = "hitTest" }
            discovered += nodes.count - before
            placeAfter(list.index, from:before)
        }
        var result: [String:Any] = ["app": current.bundle, "pid": pid, "snapshot": current.id, "nodes": nodes, "truncated": truncated, "frontmostApp": frontmost(),
            "elapsedMs": Int(Date().timeIntervalSince(started)*1000),
            "windows":windows.enumerated().map { index, window in ["index":index,"title":attribute(window,kAXTitleAttribute) as? String ?? "","minimized":attribute(window,kAXMinimizedAttribute) as? Bool ?? false,"main":main.map { CFEqual(window,$0) } ?? false] as [String:Any] }]
        if let index = request["window"] as? Int { result["selectedWindow"] = index }
        if webJustEnabled { result["webAccessibilityEnabled"] = true }
        if discovered > 0 { result["hitTestDiscovered"] = discovered }
        overlay.track(app,element:roots.first.flatMap { owningWindow($0) },action:"Reading window")
        return result
    }
    func screenshot(_ app: NSRunningApplication, _ request: [String: Any]) async throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else { try fail("SCREEN_RECORDING_REQUIRED", "Allow Screen Recording for the launching host in System Settings, then restart it.") }
        let content = try await captureDeadline { try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
        let windows = content.windows.filter { $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1 }
        guard !windows.isEmpty else { try fail("NO_WINDOW", "No capturable window for this app. Restore a window and try again.") }
        let window: SCWindow
        if let id = request["windowId"] as? UInt32 {
            guard let selected = windows.first(where: { $0.windowID == id }) else { try fail("INVALID_WINDOW", "windowId must belong to the allowed app.") }
            window = selected
        } else {
            // Apps keep invisible utility windows around; one visible window needs no selection.
            let visible = windows.filter { $0.isOnScreen }
            let candidates = visible.isEmpty ? windows : visible
            guard candidates.count == 1 else {
                return ["selectionRequired": true, "windows": candidates.map { ["windowId": $0.windowID, "title": $0.title ?? "", "onScreen": $0.isOnScreen] as [String: Any] }]
            }
            window = candidates[0]
        }
        overlay.track(app,title:window.title,captureWindowID:window.windowID,captureFrame:window.frame,action:"Capturing window")
        note?.merge(["window":cleanLabel(window.title ?? "",limit:160)])
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = min(1, 1600 / max(window.frame.width, window.frame.height))
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        let cgImage = try await captureDeadline { try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { try fail("CAPTURE_FAILED", "Could not encode screenshot") }
        // The page at the window's centre identifies which tab the picture shows.
        var capture = Capture(window:window.windowID,scale:scale,title:window.title,size:window.frame.size)
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(app.processIdentifier),Float(window.frame.midX),Float(window.frame.midY),&hit) == .success, let hit,
           let frame = owningWindow(hit).flatMap({ elementFrame($0) }), abs(frame.minX-window.frame.minX) <= 3, abs(frame.minY-window.frame.minY) <= 3,
           let page = webArea(hit) {
            capture.page = page; capture.url = pageURL(page)
        }
        captures[app.processIdentifier] = capture
        return ["mimeType": "image/png", "data": png.base64EncodedString(), "width": cgImage.width, "height": cgImage.height, "scale": scale, "windowId": window.windowID, "app": app.bundleIdentifier ?? ""]
    }
    // Screenshot pixel -> the element this app has there. The hit test is scoped to the
    // app, so windows of other apps on top of it do not matter and are never read.
    func hitTest(_ app: NSRunningApplication, _ request: [String:Any]) throws -> AXUIElement {
        guard let capture = captures[app.processIdentifier] else { try fail("SCREENSHOT_REQUIRED","Take a screenshot of this app first; clickPoint coordinates are pixels in the most recent screenshot.") }
        guard let x = (request["x"] as? NSNumber)?.doubleValue, let y = (request["y"] as? NSNumber)?.doubleValue else { try fail("INVALID_ARGUMENT","x and y must be numbers") }
        let bounds = try capture.verify(hit:nil)
        let point = CGPoint(x:bounds.minX+x/capture.scale,y:bounds.minY+y/capture.scale)
        guard bounds.contains(point) else { try fail("INVALID_ARGUMENT","The point is outside the captured window.") }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(app.processIdentifier),Float(point.x),Float(point.y),&hit) == .success, var hit else {
            try fail("UNSUPPORTED_TARGET","The app exposes no accessible element at that point. Observe and use an element instead.")
        }
        // The host's hit test stops at the container of a view-service panel (an open or
        // save panel). Descend through the bridged tree to the smallest element under the point.
        var container: AXUIElement? = hit
        while let current = container, roleOf(current) != kAXWindowRole { container = owningWindow(current) ?? parentOf(current) }
        if let window = container, viewService(in:window,host:app.processIdentifier) != nil {
            var steps = 0
            while steps < 40, let children = attribute(hit,kAXChildrenAttribute) as? [AXUIElement], !children.isEmpty {
                steps += 1
                let under = children.compactMap { child in elementFrame(child).flatMap { $0.contains(point) ? (child,$0.width*$0.height) : nil } }
                guard let next = under.min(by: { $0.1 < $1.1 }) else { break }
                hit = next.0
            }
        }
        if let window = owningWindow(hit), let frame = elementFrame(window),
           abs(frame.minX-bounds.minX) > 3 || abs(frame.minY-bounds.minY) > 3 || abs(frame.width-bounds.width) > 3 || abs(frame.height-bounds.height) > 3 {
            try fail("UNSUPPORTED_TARGET","Another window of this app covers that point. Observe the window and use an element instead.")
        }
        if attribute(hit,kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { try fail("SECURE_FIELD","Secure text fields are excluded from automation.") }
        _ = try capture.verify(hit:hit)
        return hit
    }
    // What "click" means for an element, without a pointer: press it or the control
    // that contains it, select it, or put the app's own text focus in it.
    func pressPlan(_ element: AXUIElement) -> (AXUIElement,String)? {
        let barriers = [kAXWindowRole,kAXApplicationRole,"AXWebArea",kAXScrollAreaRole,kAXSheetRole,kAXSplitGroupRole,kAXTabGroupRole,kAXMenuBarRole]
        func chain(_ hops: Int) -> [AXUIElement] {
            var items = [element]
            while items.count <= hops, let parent = parentOf(items.last!), !barriers.contains(roleOf(parent)) { items.append(parent) }
            return items
        }
        if Computer.textRoles.contains(roleOf(element)), isSettable(element,kAXFocusedAttribute) { return (element,kAXFocusedAttribute) }
        let near = chain(3)
        if let item = near.first(where: { actionNames($0).contains(kAXPressAction) }) { return (item,kAXPressAction) }
        if let item = near.prefix(3).first(where: { isSettable($0,kAXSelectedAttribute) }) { return (item,kAXSelectedAttribute) }
        if actionNames(element).contains(kAXPickAction) { return (element,kAXPickAction) }
        if isSettable(element,kAXFocusedAttribute) { return (element,kAXFocusedAttribute) }
        return nil
    }
    // false: the app did not answer in time. Controls that open a modal dialog or menu
    // run the action and reply only when it closes, so this is not a failure.
    func perform(_ element: AXUIElement, _ action: String) throws -> Bool {
        AXUIElementSetMessagingTimeout(element,3)
        if action == kAXSelectedAttribute || action == kAXFocusedAttribute {
            try axCheck(AXUIElementSetAttributeValue(element,action as CFString,kCFBooleanTrue),action)
            return true
        }
        let result = AXUIElementPerformAction(element,action as CFString)
        if result == .cannotComplete { return false }
        try axCheck(result,action)
        return true
    }
    func scrollPlan(_ element: AXUIElement, _ direction: String) -> (String,() throws -> Void)? {
        let action = "AXScroll\(direction.capitalized)ByPage"
        let vertical = direction == "up" || direction == "down"
        let sign: Double = direction == "down" || direction == "right" ? 1 : -1
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let item = current else { break }
            if actionNames(item).contains(action) { return (action,{ try axCheck(AXUIElementPerformAction(item,action as CFString),action) }) }
            if roleOf(item) == kAXScrollAreaRole, let bar = axElement(attribute(item,vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute)), isSettable(bar,kAXValueAttribute) {
                var step = 0.25
                if let visible = elementFrame(item), let content = (attribute(item,kAXContentsAttribute) as? [AXUIElement])?.first.flatMap({ elementFrame($0) }) {
                    let (shown,total) = vertical ? (visible.height,content.height) : (visible.width,content.width)
                    if total > shown + 1 { step = min(1,Double(shown/(total-shown))*0.9) }
                }
                return ("AXScrollBar",{
                    let value = (attribute(bar,kAXValueAttribute) as? NSNumber)?.doubleValue ?? 0
                    try axCheck(AXUIElementSetAttributeValue(bar,kAXValueAttribute as CFString,NSNumber(value:min(1,max(0,value+sign*step)))),"AXScrollBar")
                })
            }
            current = parentOf(item)
        }
        return nil
    }
    func focusForKeys(_ element: AXUIElement) async -> Bool {
        if attribute(element,kAXFocusedAttribute) as? Bool == true { return true }
        guard AXUIElementSetAttributeValue(element,kAXFocusedAttribute as CFString,kCFBooleanTrue) == .success else { return false }
        try? await Task.sleep(nanoseconds:60_000_000)
        return true
    }
    func open(_ request: [String:Any]) async throws -> [String:Any] {
        let bundle = try permit(request)
        try overlay.ensureNotPaused(NSRunningApplication.runningApplications(withBundleIdentifier:bundle).first)
        guard let location = NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundle) else { try fail("APP_NOT_FOUND","No installed app has bundle ID \(bundle).") }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        var urls: [URL] = []
        if let raw = request["url"] as? String {
            guard let url = URL(string:raw), ["http","https","file"].contains(url.scheme?.lowercased() ?? "") else { try fail("INVALID_ARGUMENT","url must be an http, https, or file URL.") }
            urls = [url]
        }
        let before = focus.begin(target:nil)
        do {
            let app = urls.isEmpty ? try await NSWorkspace.shared.openApplication(at:location,configuration:config)
                                   : try await NSWorkspace.shared.open(urls,withApplicationAt:location,configuration:config)
            focus.expect(app.processIdentifier)
            let outcome = await focus.finish(settleMs:250)
            overlay.track(app,action:urls.isEmpty ? "Opening app" : "Opening link")
            return ["opened":true,"app":bundle,"pid":app.processIdentifier,"frontmostBefore":before.bundle,"frontmostAfter":outcome.after,"focusChanged":outcome.changed,"focusRestored":outcome.restored]
        } catch let error as Failure { focus.cancel(); throw error }
        catch { focus.cancel(); try fail("OPEN_FAILED","Could not open \(bundle): \(error.localizedDescription)") }
    }
    /// Waits for the person's answer on the activity card before an action OPENCOMPUTER_CONFIRM covers.
    func approve(_ method: String, _ request: [String:Any], app: NSRunningApplication, item: AXUIElement?, reason: String) async throws {
        guard overlay.enabled else {
            throw Failure(code:"APPROVAL_UNAVAILABLE",message:"OPENCOMPUTER_CONFIRM asks the person before this action, but OPENCOMPUTER_OVERLAY=0 hides the indicator where they answer. Nothing was dispatched. Ask the person to enable the overlay or change OPENCOMPUTER_CONFIRM.",details:["dispatched":false])
        }
        let name = item.map { label($0) } ?? ""
        let what: String
        switch method {
        case "pressKey": what = "press \(cleanLabel(request["key"] as? String ?? "a key",limit:24))"
        case "setValue": what = "change “\(name)”"
        case "typeText": what = "type into “\(name)”"
        case "scroll": what = "scroll “\(name)”"
        default: what = "click “\(name)”"
        }
        // The key covers everything the action would do, so an answer never carries over to another action.
        let fields = request.filter { $0.key != "waitMs" }
        let key = (try? JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys])).flatMap { String(data:$0,encoding:.utf8) } ?? UUID().uuidString
        // Waiting for an answer and for the person to pause must fit in the client's 20 s request timeout.
        let wait = min(10000,max(0,request["waitMs"] as? Int ?? defaultWait))
        // The card already names the app and window, so the detail is just the reason.
        let outcome = await overlay.requestApproval(key:key,title:"\(overlay.view.agent.name) wants to \(what)",detail:reason,wait:max(3,16 - Double(wait)/1000))
        try overlay.ensureNotPaused(app)
        switch outcome {
        case .approved: note?.merge(["approved":true])
        case .denied: throw Failure(code:"APPROVAL_DENIED",message:"The person declined this action on screen, so nothing was dispatched. Do not retry it; ask them in chat how to proceed.",details:["dispatched":false])
        case .waiting: throw Failure(code:"APPROVAL_PENDING",message:"Waiting for the person to approve this action on the activity indicator; nothing was dispatched. Tell them in chat what you are waiting for, then retry the same call: it runs once they press Allow.",details:["dispatched":false,"retryAfterMs":3000])
        }
    }
    // The request being handled; requests are serialized, so there is at most one.
    var note: Note?
    func handle(_ request: [String: Any]) async throws -> [String: Any] {
        let method = request["method"] as? String ?? ""
        guard ActionLog.methods.contains(method) else { return try await dispatch(request) }
        let note = Note(method,request)
        self.note = note
        defer { self.note = nil }
        let serial = overlay.stepSerial
        do {
            let result = try await dispatch(request)
            log.write(note.finish(result))
            return result
        } catch let error as Failure {
            overlay.settle(since:serial,code:error.code)
            log.write(note.failed(error.code,error.message,error.details))
            throw error
        } catch {
            log.write(note.failed("NATIVE_ERROR",error.localizedDescription,nil))
            throw error
        }
    }
    func dispatch(_ request: [String: Any]) async throws -> [String: Any] {
        let method = try string(request, "method")
        switch method {
        case "status":
            return ["helperPid":getpid(), "platform": "macOS", "accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess(), "allowedApps": allowed.sorted(), "frontmostApp": frontmost(), "version": Computer.version, "actionLog": log.path ?? NSNull(), "activity":overlay.state(), "approvals":approvalPolicy.summary, "focusProtectionBlocked":false, "focusRestorations":focus.restorations, "waitMs":defaultWait]
        case "configure":
            overlay.configure(try string(request,"agent"))
            return ["agent":overlay.view.agent.name]
        case "release":
            overlay.release(); snapshots = [:]; captures = [:]
            return ["released":true]
        case "apps":
            let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map {
                ["name": $0.localizedName ?? "", "bundleId": $0.bundleIdentifier ?? "", "pid": $0.processIdentifier, "frontmost": $0.isActive, "hidden": $0.isHidden, "allowed": allowed.contains("*") || allowed.contains($0.bundleIdentifier ?? "")] as [String: Any]
            }
            return ["apps": apps.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }]
        case "open": return try await open(request)
        default: break
        }
        guard ["observe", "screenshot", "checkInteraction", "click", "clickPoint", "setValue", "performAction", "pressKey", "typeText", "scroll"].contains(method) else { try fail("UNKNOWN_METHOD", method) }
        let app = try target(request)
        let pid = app.processIdentifier
        if method == "screenshot" { return try await screenshot(app, request) }
        try trusted()
        if method == "observe" { return try await observe(app,request) }
        let elementOptional = ["checkInteraction","pressKey","clickPoint"].contains(method)
        var resolved: (snapshot: Snapshot, index: Int, element: AXUIElement)?
        var item: AXUIElement?
        if method == "clickPoint" {
            let hit = try hitTest(app,request)
            item = hit
            note?.merge(["target":describeForLog(hit)].merging(whereabouts(hit,in:snapshots[pid])) { a, _ in a })
        } else if !elementOptional || request["element"] != nil {
            resolved = try resolve(request,app)
            item = resolved!.element
        }
        if method == "checkInteraction" { return interaction.assess(app,element:item,intrusive:request["intrusive"] as? Bool ?? false).json }
        // Keys without an element go to the app's focused window; the latest snapshot of
        // the app must have read that window as it still is.
        var keySnapshot: Snapshot?
        if method == "pressKey", item == nil {
            if let focused = axElement(attribute(AXUIElementCreateApplication(pid),kAXFocusedWindowAttribute)) { note?.merge(["window":cleanLabel(readTitle(focused).title,limit:160)]) }
            if let snapshot = snapshots[pid], Date().timeIntervalSince(snapshot.time) < 300 { keySnapshot = snapshot }
            try keySnapshot?.verifyFocusedWindow(pid)
        }
        // Everything that can be refused is decided before the person's activity is checked.
        var intrusive = false
        var settle = 15
        var verb = "Using"
        var info: [String:Any] = [:]
        let run: () async throws -> [String:Any]
        switch method {
        case "click", "clickPoint":
            let hit = item!
            guard let plan = pressPlan(hit) else {
                throw Failure(code:method == "click" ? "UNSUPPORTED_ACTION" : "UNSUPPORTED_TARGET",message:"Nothing pressable here: this element and its container expose no press, select, or focus action. Try a nearby control from observe.",details:describe(hit))
            }
            if method == "clickPoint" { info["target"] = describe(hit) }
            if !CFEqual(plan.0,hit) { info["pressed"] = describe(plan.0) }
            item = plan.0
            intrusive = plan.1 == kAXFocusedAttribute
            settle = 60; verb = "Clicking"
            run = { try self.perform(plan.0,plan.1) ? ["delivery":plan.1] : ["delivery":plan.1,"confirmed":false] }
        case "setValue":
            let target = item!
            guard let value = request["value"] as? String, value.utf16.count <= 16000 else { try fail("INVALID_ARGUMENT", "value must be a string of at most 16000 UTF-16 units") }
            verb = "Editing"
            run = {
                // Sliders, steppers, and similar controls hold numbers.
                if attribute(target,kAXValueAttribute) is NSNumber, !(attribute(target,kAXValueAttribute) is NSString), let number = Double(value) {
                    try axCheck(AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, NSNumber(value:number)), "AXValue")
                } else {
                    try axCheck(AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, value as CFString), "AXValue")
                }
                return ["delivery":kAXValueAttribute]
            }
        case "performAction":
            let target = item!
            let action = try string(request, "action")
            if [kAXShowMenuAction,kAXRaiseAction].contains(action) { try fail("FOCUS_UNSAFE", "This action raises a window or opens a menu at the pointer. Use a specific control instead.") }
            let supported = [kAXPressAction, kAXIncrementAction, kAXDecrementAction, kAXPickAction, kAXConfirmAction, kAXCancelAction, "AXScrollToVisible", "AXOpen"]
            guard supported.contains(action) else { try fail("INVALID_ARGUMENT", "Use one of \(supported.joined(separator:", ")).") }
            guard actionNames(target).contains(action) else { try fail("UNSUPPORTED_ACTION","This element does not offer \(action). Its actions are listed in the snapshot.") }
            settle = 60
            run = { try self.perform(target,action) ? ["delivery":action] : ["delivery":action,"confirmed":false] }
        case "typeText":
            let target = item!
            let text = try string(request,"text")
            guard text.utf16.count <= 16000 else { try fail("INVALID_ARGUMENT","text must be at most 16000 UTF-16 units") }
            verb = "Editing"
            var range = CFRange()
            let current = attribute(target,kAXValueAttribute) as? String
            let semantic = !(request["keys"] as? Bool ?? false) && current != nil && isSettable(target,kAXValueAttribute)
                && attribute(target,kAXSelectedTextRangeAttribute).map { CFGetTypeID($0) == AXValueGetTypeID() && AXValueGetValue(unsafeBitCast($0,to:AXValue.self),.cfRange,&range) } == true
                && range.location >= 0 && range.length >= 0 && range.location <= (current! as NSString).length && range.length <= (current! as NSString).length-range.location
            if semantic {
                let replacement = (current! as NSString).replacingCharacters(in:NSRange(location:range.location,length:range.length),with:text)
                guard replacement.utf16.count <= 16000 else { try fail("INVALID_ARGUMENT", "Result exceeds 16000 UTF-16 units") }
                run = {
                    try axCheck(AXUIElementSetAttributeValue(target,kAXValueAttribute as CFString,replacement as CFString),"AXValue")
                    var caret = CFRange(location:range.location+(text as NSString).length,length:0)
                    if let value = AXValueCreate(.cfRange,&caret) { AXUIElementSetAttributeValue(target,kAXSelectedTextRangeAttribute as CFString,value) }
                    return ["delivery":kAXValueAttribute]
                }
            } else {
                guard text.count <= 2000 else { try fail("INVALID_ARGUMENT","This control only accepts typed keys, limited to 2000 characters per call. Split the text or use setValue.") }
                intrusive = true; settle = 60
                run = {
                    let focused = await self.focusForKeys(target)
                    Keys.type(text,to:pid)
                    return ["delivery":"keys","elementFocused":focused]
                }
            }
        case "pressKey":
            let stroke = try Keys.parse(try string(request,"key"))
            let count = min(50,max(1,request["count"] as? Int ?? 1))
            let target = item
            if target == nil, let focused = axElement(attribute(AXUIElementCreateApplication(pid),kAXFocusedUIElementAttribute)),
               attribute(focused,kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { try fail("SECURE_FIELD","The app's focus is in a secure text field; keys are not sent there.") }
            intrusive = true; settle = 60; verb = "Pressing \(cleanLabel(request["key"] as? String ?? "",limit:20)) in"
            run = {
                var result: [String:Any] = ["delivery":"keys"]
                if let target { result["elementFocused"] = await self.focusForKeys(target) }
                Keys.post(stroke,to:pid,count:count)
                return result
            }
        case "scroll":
            let direction = try string(request, "direction")
            guard ["up","down","left","right"].contains(direction) else { try fail("INVALID_ARGUMENT", "direction must be up/down/left/right") }
            let pages = min(20,max(1,request["pages"] as? Int ?? 1))
            guard let plan = scrollPlan(item!,direction) else {
                try fail("UNSUPPORTED_ACTION","Nothing scrollable contains this element. Use performAction AXScrollToVisible on the element you want to reach, or pressKey PageDown.")
            }
            verb = "Scrolling"
            run = { for _ in 0..<pages { try plan.1() }; return ["delivery":plan.0] }
        default: try fail("UNKNOWN_METHOD", method)
        }
        try overlay.ensureNotPaused(app)
        let pointer = ActivityOverlay.pointer(method:method,action:request["action"] as? String,role:item.flatMap { attribute($0,kAXRoleAttribute) as? String })
        overlay.track(app,element:item,pointer:pointer,action:"\(verb) \(item.map { label($0) } ?? (app.localizedName ?? "app"))")
        if let reason = approvalPolicy.reason(method:method,bundle:app.bundleIdentifier ?? "",label:item.map { label($0) },key:request["key"] as? String,action:request["action"] as? String) {
            try await approve(method,request,app:app,item:item,reason:reason)
        }
        var before = focus.begin(target:pid)
        var decision = interaction.assess(app,element:item,intrusive:intrusive,foreground:before)
        let wait = min(10000,max(0,request["waitMs"] as? Int ?? defaultWait))
        let deadline = Date().addingTimeInterval(Double(wait)/1000)
        // A brief pause in the person's activity is usually all an action needs.
        while !decision.canProceed, Date() < deadline {
            overlay.markWaiting(decision.message)
            try? await Task.sleep(nanoseconds:150_000_000)
            before = focus.begin(target:pid)
            decision = interaction.assess(app,element:item,intrusive:intrusive,foreground:before)
        }
        if !decision.canProceed {
            focus.cancel()
            overlay.markWaiting(decision.message)
            var details = decision.json
            details["dispatched"] = false
            details["waitedMs"] = wait
            throw Failure(code:"USER_BUSY",message:decision.message + " Nothing was dispatched or queued. Retry after retryAfterMs; the snapshot is still valid.",details:details)
        }
        // The person may have pressed Take over while the action waited.
        if overlay.paused { focus.cancel(); try overlay.ensureNotPaused(app) }
        if wait > 0 { overlay.track(app,element:item,pointer:pointer,action:"\(verb) \(item.map { label($0) } ?? (app.localizedName ?? "app"))") }
        // The person may have switched tabs or pages while the action waited for a pause.
        do {
            if let resolved { try resolved.snapshot.verify(resolved.index) }
            else if method == "clickPoint", let capture = captures[pid] { _ = try capture.verify(hit:item) }
            else if let keySnapshot { try keySnapshot.verifyFocusedWindow(pid) }
        } catch { focus.cancel(); overlay.markWaiting("Target changed; observe again"); throw error }
        note?.merge(["dispatchAttempted":true])
        let dispatched = Date()
        var dispatchError: Error?
        do { info.merge(try await run()) { _, new in new } } catch { dispatchError = error }
        let outcome = await focus.finish(settleMs:settle)
        if let error = dispatchError { throw error }
        // Changes this action caused keep the snapshot valid; changes the person made do not.
        if !userActed(since:dispatched) {
            if let resolved { resolved.snapshot.refresh(resolved.index) }
            else if let keySnapshot { keySnapshot.refreshFocusedWindow(pid) }
            else if method == "clickPoint", var capture = captures[pid] {
                if let title = windowInfo(capture.window)?.title { capture.title = title }
                if let page = capture.page, let url = pageURL(page) { capture.url = url }
                captures[pid] = capture
            }
        }
        var result: [String:Any] = ["dispatched":true,"method":method,"frontmostBefore":before.bundle,"frontmostAfter":outcome.after,"focusChanged":outcome.changed,"focusRestored":outcome.restored,"verificationRequired":true,"activity":overlay.state()]
        result.merge(info) { _, new in new }
        return result
    }
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let computer = MainActor.assumeIsolated { Computer() }
func write(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]), let text = String(data:data,encoding:.utf8) { print(text); fflush(stdout) }
}
// Read input off the main thread; keep the AppKit event loop alive between tool calls.
// The semaphore serializes dispatch so requests on one connection never interleave.
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
