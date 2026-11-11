import AppKit
import ApplicationServices

// Where observe saw an element: the window it was in and, for web content, the page.
struct Place { var window: Int?; var page: Int? }
// What a window looked like at observe time: its title and its selected tab, if any.
struct WindowMark { var title: String; var tab: Int?; var tabTitle: String?; var tabs: [Int] = [] }
struct PageMark { var url: String }

func isAlive(_ element: AXUIElement) -> Bool {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element,kAXRoleAttribute as CFString,&value) != .invalidUIElement
}
func readTitle(_ element: AXUIElement) -> (alive: Bool, title: String) {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element,kAXTitleAttribute as CFString,&value)
    return (result != .invalidUIElement, value as? String ?? "")
}
func pageURL(_ element: AXUIElement) -> String? {
    guard let value = attribute(element,"AXURL") else { return nil }
    if let url = value as? URL { return url.absoluteString }
    return value as? String
}
func webArea(_ element: AXUIElement) -> AXUIElement? {
    var current: AXUIElement? = element
    for _ in 0..<80 {
        guard let item = current else { return nil }
        if roleOf(item) == "AXWebArea" { return item }
        current = parentOf(item)
    }
    return nil
}
func isSelectedTab(_ element: AXUIElement) -> Bool {
    if let value = attribute(element,kAXValueAttribute) as? NSNumber { return value.intValue == 1 }
    return attribute(element,kAXSelectedAttribute) as? Bool == true
}
// Errors and the action log say which page, never what its address carries.
func redactURL(_ raw: String?) -> String? {
    guard let raw, var parts = URLComponents(string:raw) else { return nil }
    parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
    return parts.string
}
func quoted(_ text: String) -> String { "\"\(cleanLabel(text,limit:80))\"" }
func targetChanged(_ reason: String, _ message: String, _ details: [String:Any] = [:]) -> Failure {
    var details = details
    details["reason"] = reason
    details["dispatched"] = false
    return Failure(code:"TARGET_CHANGED",message:message + " Nothing was sent. Observe the app again and act on an element from the new snapshot.",details:details)
}
// The person's own clicks, keys, or scrolling since a moment. Posted events use a
// private source and never count.
func userActed(since start: Date) -> Bool {
    let elapsed = Date().timeIntervalSince(start) + 0.05
    return [CGEventType.leftMouseDown,.rightMouseDown,.otherMouseDown,.keyDown,.flagsChanged,.scrollWheel].contains {
        let age = CGEventSource.secondsSinceLastEventType(.hidSystemState,eventType:$0)
        return age.isFinite && age >= 0 && age <= elapsed
    }
}

// An element ID names an object, not a position, so a press always reaches the object
// observe saw. That object can still be in a tab the person has since left, or on a page
// that has since changed. Before every dispatch the snapshot proves its window, tab, and
// page are still the ones it read; otherwise the action is refused with TARGET_CHANGED.
extension Snapshot {
    func find(_ element: AXUIElement) -> Int? { index[CFHash(element)]?.first { CFEqual(elements[$0],element) } }
    func note(_ index: Int, parent: Int?, place: Place) {
        if let parent, parents[index] == nil, parent != index { parents[index] = parent }
        if places[index] == nil { places[index] = place }
    }
    func checkWindow(_ w: Int) throws {
        guard let mark = windows[w] else { return }
        let now = readTitle(elements[w])
        guard now.alive else { throw targetChanged("window-closed","The window this element was in has closed since snapshot \(id).") }
        guard now.title == mark.title else {
            throw targetChanged("window-title","The window title changed from \(quoted(mark.title)) to \(quoted(now.title)) since snapshot \(id), so another tab or page is probably showing.",["was":mark.title,"now":now.title])
        }
        if let tab = mark.tab, !isSelectedTab(elements[tab]) {
            throw targetChanged("tab","The tab \(quoted(mark.tabTitle ?? "")) is no longer the selected tab of its window.",["tab":mark.tabTitle ?? ""])
        }
    }
    // Throws when the element, its window, its window's selected tab, or its page is no
    // longer what this snapshot read.
    func verify(_ index: Int) throws {
        guard isAlive(elements[index]) else {
            try fail("STALE_ELEMENT","This element no longer exists; its page or view changed after snapshot \(id). Nothing was sent. Observe the app again and use a current element.")
        }
        guard let place = places[index] else { return }
        if let w = place.window { try checkWindow(w) }
        if let p = place.page {
            guard isAlive(elements[p]) else { throw targetChanged("page-closed","The web page this element was on is gone.") }
            if let mark = pages[p], let now = pageURL(elements[p]), now != mark.url {
                throw targetChanged("page-url","The page address changed from \(redactURL(mark.url) ?? "?") to \(redactURL(now) ?? "?") since snapshot \(id).",["was":redactURL(mark.url) ?? "","now":redactURL(now) ?? ""])
            }
        }
        if let w = place.window { try attached(place.page ?? index,to:w) }
    }
    // A tab moved to the background can keep its elements alive while its page leaves
    // the window, so each link from the window down to the page must still hold.
    func attached(_ index: Int, to window: Int) throws {
        var chain = [index]
        while let last = chain.last, last != window, chain.count <= 80, let parent = parents[last] { chain.append(parent) }
        guard chain.last == window else { return }
        for (child,parent) in zip(chain,chain.dropFirst()).reversed() {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(elements[parent],kAXChildrenAttribute as CFString,&value)
            if result == .invalidUIElement { throw targetChanged("detached","This element's page or view has left its window since snapshot \(id).") }
            guard result == .success, let children = value as? [AXUIElement] else { continue }
            guard children.contains(where: { CFEqual($0,elements[child]) }) else {
                throw targetChanged("detached","This element is no longer shown in its window, for example because another tab became active.")
            }
        }
    }
    // Keys go to whatever the app's focused window shows, so that window must be one this
    // snapshot read and still look the same.
    func verifyFocusedWindow(_ pid: pid_t) throws {
        guard !windows.isEmpty, let focused = axElement(attribute(AXUIElementCreateApplication(pid),kAXFocusedWindowAttribute)) else { return }
        guard let w = find(focused), windows[w] != nil else {
            throw targetChanged("window-unknown","Keys would go to the app's focused window \(quoted(readTitle(focused).title)), which snapshot \(id) did not read.")
        }
        try checkWindow(w)
    }
    // A change the session caused itself (a tab it pressed, a page it navigated) is
    // expected, so later actions in the same window stay valid. Elements of an old page
    // are still refused by the page and attachment checks.
    func refresh(_ index: Int) {
        guard let place = places[index] else { return }
        if let w = place.window { refreshWindow(w) }
        if let p = place.page, pages[p] != nil, let now = pageURL(elements[p]) { pages[p] = PageMark(url:now) }
    }
    func refreshFocusedWindow(_ pid: pid_t) {
        guard let focused = axElement(attribute(AXUIElementCreateApplication(pid),kAXFocusedWindowAttribute)), let w = find(focused) else { return }
        refreshWindow(w)
    }
    // Pressing or closing a tab selects another one; the snapshot knows every tab it read.
    func refreshWindow(_ w: Int) {
        guard var mark = windows[w] else { return }
        let now = readTitle(elements[w])
        if now.alive { mark.title = now.title }
        if !mark.tabs.isEmpty, mark.tab.map({ !isSelectedTab(elements[$0]) }) ?? true {
            mark.tab = mark.tabs.first { isAlive(elements[$0]) && isSelectedTab(elements[$0]) }
            mark.tabTitle = mark.tab.map { readTitle(elements[$0]).title }
        }
        windows[w] = mark
    }
}

// Window, tab, and page of an element as they are now, for the action log.
@MainActor
func whereabouts(_ element: AXUIElement, in snapshot: Snapshot?) -> [String:Any] {
    var out: [String:Any] = [:]
    let place = snapshot.flatMap { s in s.find(element).flatMap { s.places[$0] } }
    let window = place?.window.map { snapshot!.elements[$0] } ?? owningWindow(element)
    if let window { out["window"] = cleanLabel(readTitle(window).title,limit:160) }
    if let w = place?.window, let tab = snapshot!.windows[w]?.tab { out["tab"] = cleanLabel(readTitle(snapshot!.elements[tab]).title,limit:120) }
    let page = place?.page.map { snapshot!.elements[$0] } ?? webArea(element)
    if let page, let url = redactURL(pageURL(page)) { out["page"] = url }
    return out
}
func describeForLog(_ element: AXUIElement) -> [String:Any] {
    var out: [String:Any] = ["role":roleOf(element)]
    if let subrole = attribute(element,kAXSubroleAttribute) as? String, !subrole.isEmpty { out["subrole"] = subrole }
    if let name = [kAXTitleAttribute,kAXDescriptionAttribute].compactMap({ attribute(element,$0) as? String }).first(where: { !$0.isEmpty }) { out["label"] = cleanLabel(name,limit:80) }
    if let identifier = attribute(element,kAXIdentifierAttribute) as? String, !identifier.isEmpty { out["identifier"] = cleanLabel(identifier,limit:60) }
    return out
}
// The processes above the helper (node, then the agent host), to tell sessions apart.
func ancestry(_ pid: pid_t, levels: Int = 3) -> [[String:Any]] {
    var chain: [[String:Any]] = []
    var current = pid
    for _ in 0..<levels {
        var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN,KERN_PROC,KERN_PROC_PID,current]
        guard current > 1, sysctl(&mib,4,&info,&size,nil,0) == 0, size > 0 else { break }
        let name = withUnsafeBytes(of:info.kp_proc.p_comm) { String(decoding:$0.prefix { $0 != 0 },as:UTF8.self) }
        chain.append(["pid":current,"name":name])
        current = info.kp_eproc.e_ppid
    }
    return chain
}

// A screenshot pixel names a position, so clickPoint resolves it to whatever is there at
// dispatch time. The capture records the window title, size, and page it showed.
struct Capture {
    let window: CGWindowID
    let scale: CGFloat
    var title: String?
    let size: CGSize
    let time = Date()
    var page: AXUIElement?
    var url: String?
}
func windowInfo(_ id: CGWindowID) -> (title: String?, bounds: CGRect)? {
    guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow],id) as? [[String:Any]])?.first,
          let raw = info[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation:raw as CFDictionary) else { return nil }
    return (info[kCGWindowName as String] as? String,bounds)
}
extension Capture {
    func verify(hit: AXUIElement?) throws -> CGRect {
        guard Date().timeIntervalSince(time) < 300 else { try fail("SCREENSHOT_REQUIRED","The last screenshot of this app is more than 5 minutes old. Take a new screenshot.") }
        guard let now = windowInfo(window) else { try fail("NO_WINDOW","The captured window is gone. Take a new screenshot.") }
        if let title, let current = now.title, current != title {
            throw targetChanged("window-title","The window title changed from \(quoted(title)) to \(quoted(current)) since the screenshot, so the pixel may now show another tab or page.",["was":title,"now":current])
                .retitled("Take a new screenshot")
        }
        if abs(now.bounds.width-size.width) > 3 || abs(now.bounds.height-size.height) > 3 {
            throw targetChanged("window-resized","The window was resized since the screenshot, so its pixels moved.").retitled("Take a new screenshot")
        }
        if let page, let hit, let hitPage = webArea(hit) {
            guard CFEqual(hitPage,page) else { throw targetChanged("page","That point is now on a different web page than the screenshot showed.").retitled("Take a new screenshot") }
            if let url, let current = pageURL(page), current != url {
                throw targetChanged("page-url","The page address changed from \(redactURL(url) ?? "?") to \(redactURL(current) ?? "?") since the screenshot.").retitled("Take a new screenshot")
            }
        }
        return now.bounds
    }
}
extension Failure {
    func retitled(_ step: String) -> Failure {
        Failure(code:code,message:message.replacingOccurrences(of:"Observe the app again and act on an element from the new snapshot.",with:"\(step) and pick the point again."),details:details)
    }
}
