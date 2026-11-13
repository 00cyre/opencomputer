import AppKit
import ScreenCaptureKit

@main
struct OverlayUITest {
    @MainActor
    static func capture(_ panel: NSPanel, to file: URL) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:false)
        guard let window = content.windows.first(where:{$0.windowID == CGWindowID(panel.windowNumber) && $0.owningApplication?.processID == getpid()}) else { throw Failure(code:"UI_TEST",message:"Own overlay window missing") }
        let scale = panel.backingScaleFactor
        let config = SCStreamConfiguration(); config.width = Int(window.frame.width * scale); config.height = Int(window.frame.height * scale); config.showsCursor = false
        let image: CGImage = try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:window),configuration:config)
        guard let data = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else { throw Failure(code:"UI_TEST",message:"PNG encoding failed") }
        try data.write(to:file)
        return data
    }
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Screenshots for both system appearances: OPENCOMPUTER_UI_APPEARANCE=dark or light.
        switch ProcessInfo.processInfo.environment["OPENCOMPUTER_UI_APPEARANCE"] {
        case "dark": app.appearance = NSAppearance(named:.darkAqua)
        case "light": app.appearance = NSAppearance(named:.aqua)
        default: break
        }
        var pointer = NSPoint(x:-10000,y:-10000)
        // The production hover branch receives pointer positions without moving the user's cursor.
        let overlay = ActivityOverlay(pointer:{pointer})
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/OpenComputer Fixture.app/Contents/MacOS/fixture")
        let dir = URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "work/overlay-ui",isDirectory:true)
        fixture.environment = ProcessInfo.processInfo.environment.merging(["OPENCOMPUTER_FIXTURE_OUTPUT":dir.appendingPathComponent("fixture.json").path]) { _,new in new }
        fixture.standardOutput = FileHandle.nullDevice
        fixture.standardError = FileHandle.nullDevice
        Task { @MainActor in
            var checks = 0
            func check(_ condition: Bool, _ message: String) throws {
                guard condition else { throw Failure(code:"UI_TEST",message:message) }; checks += 1
            }
            // Animations run on the overlay's timer, which a busy CI runner can delay: wait for the state, not a fixed time.
            func waitUntil(_ seconds: Double = 3, _ condition: () -> Bool) async throws {
                let end = Date().addingTimeInterval(seconds)
                while !condition() && Date() < end { try await Task.sleep(nanoseconds:50_000_000) }
            }
            do {
                try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
                try? FileManager.default.removeItem(at:dir.appendingPathComponent("fixture.json"))
                try fixture.run()
                var target: NSRunningApplication?
                for _ in 0..<50 {
                    target = NSRunningApplication(processIdentifier:fixture.processIdentifier)
                    if target != nil && FileManager.default.fileExists(atPath:dir.appendingPathComponent("fixture.json").path) { break }
                    try await Task.sleep(nanoseconds:100_000_000)
                }
                guard let target = target else { throw Failure(code:"UI_TEST",message:"Fixture launch failed") }
                try check(AXIsProcessTrusted(),"Accessibility unavailable")
                overlay.configure("Claude")
                overlay.track(target,action:"Reading window")
                overlay.track(target,action:"Clicking Benchmark field")
                overlay.track(target,action:"Editing benchmark token")
                try check(overlay.view.steps.map { $0.text } == ["Reading window","Clicking Benchmark field","Editing benchmark token"],"Each new action becomes a step")
                try check(overlay.view.steps.dropLast().allSatisfy { $0.state == .done } && overlay.view.steps.last?.state == .running,"Earlier steps finish when a new one starts")
                overlay.track(target,action:"Editing benchmark token")
                try check(overlay.view.steps.count == 3,"Repeating the current action adds no step")
                try await Task.sleep(nanoseconds:250_000_000)
                try check(overlay.panel.isVisible && !overlay.view.expanded,"Activity begins collapsed")
                let first = try await capture(overlay.panel,to:dir.appendingPathComponent("activity-collapsed.png"))
                try await Task.sleep(nanoseconds:200_000_000)
                let second = try await capture(overlay.panel,to:dir.appendingPathComponent("activity-animation-frame.png"))
                try check(first != second,"Animation changes the rendered dot pixels")
                try check(overlay.ghost.isVisible,"Ghost visible over exposed fixture")
                try await Task.sleep(nanoseconds:700_000_000)
                _ = try await capture(overlay.ghost,to:dir.appendingPathComponent("ghost-cursor.png"))
                overlay.ghostView.pulseUntil = Date().addingTimeInterval(0.6)
                try await Task.sleep(nanoseconds:120_000_000)
                _ = try await capture(overlay.ghost,to:dir.appendingPathComponent("ghost-cursor-press.png"))
                try check(overlay.ghostView.name == "Claude","The ghost cursor carries the agent's name tag")
                pointer = NSPoint(x:overlay.panel.frame.midX,y:overlay.panel.frame.midY)
                try await waitUntil { overlay.view.expanded && overlay.view.reveal >= 1 && overlay.panel.frame.width == ActivityView.cardWidth }
                try check(overlay.view.expanded && overlay.panel.frame.width == ActivityView.cardWidth,"Hover expands activity details")
                try check(overlay.panel.frame.height == overlay.view.expandedHeight,"The card fits its three steps")
                try check(overlay.view.agent.name == "Claude" && overlay.view.appName == "OpenComputer Fixture","Expanded details identify the right agent and app")
                try check(overlay.view.windowTitle == "OpenComputer Test Fixture","Expanded details include the target window title")
                try check(!overlay.panel.canBecomeKey && !overlay.panel.canBecomeMain && !overlay.panel.isKeyWindow && !overlay.panel.isMainWindow,"Expanded panel cannot own focus")
                try check(!overlay.panel.ignoresMouseEvents && overlay.ghost.ignoresMouseEvents,"The open card takes clicks for its buttons; the ghost never does")
                try check(NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid(),"Overlay process never becomes foreground")
                _ = try await capture(overlay.panel,to:dir.appendingPathComponent("activity-expanded.png"))
                guard let takeOver = overlay.view.buttonFrames().first(where:{ $0.0 == .takeOver })?.1 else { throw Failure(code:"UI_TEST",message:"Take over button missing") }
                pointer = NSPoint(x:overlay.panel.frame.minX + takeOver.midX,y:overlay.panel.frame.maxY - takeOver.midY)
                try await waitUntil { overlay.view.hovered == .takeOver }
                try check(overlay.view.hovered == .takeOver,"Hovering Take over highlights it")

                // Take over pauses the session until Resume; the agent's actions are refused meanwhile.
                overlay.press(.takeOver)
                try check(overlay.paused && overlay.view.buttons == [.resume],"Take over pauses and offers Resume")
                var refused = ""
                do { try overlay.ensureNotPaused(target) } catch let error as Failure { refused = error.code }
                try check(refused == "PAUSED_BY_USER","Actions are refused while the person has control")
                try await Task.sleep(nanoseconds:150_000_000)
                _ = try await capture(overlay.panel,to:dir.appendingPathComponent("activity-paused.png"))
                overlay.press(.resume)
                try check(!overlay.paused && overlay.view.buttons == [.takeOver],"Resume hands control back")

                pointer = NSPoint(x:-10000,y:-10000)
                try await waitUntil { !overlay.view.expanded && overlay.panel.frame.width == ActivityView.pillWidth }
                try check(!overlay.view.expanded && overlay.panel.frame.width == ActivityView.pillWidth,"Leaving the pill collapses it")
                try check(overlay.panel.ignoresMouseEvents,"Collapsed dots pass clicks through")

                // An approval question opens the card by itself and waits for Allow or Deny.
                let key = "click-send"
                let unanswered = await overlay.requestApproval(key:key,title:"Claude wants to click “Send”",detail:"“Send” looks like it can’t be undone",wait:0.5)
                try check(unanswered == .waiting && overlay.view.approval != nil,"Unanswered approval keeps waiting")
                try await waitUntil { overlay.view.expanded && overlay.view.reveal >= 1 && !overlay.panel.ignoresMouseEvents }
                try check(overlay.view.expanded && overlay.view.buttons == [.deny,.allow] && !overlay.panel.ignoresMouseEvents,"Approval opens the card with Deny and Allow")
                // Allow counts only after a held press, and is never offered to assistive apps.
                let holdStart = Date()
                overlay.view.pressed = .allow; overlay.view.holdStarted = holdStart
                try await Task.sleep(nanoseconds:200_000_000)
                try check(overlay.view.approval != nil,"A short press on Allow approves nothing")
                _ = try await capture(overlay.panel,to:dir.appendingPathComponent("activity-approval-hold.png"))
                try check(!(overlay.view.accessibilityCustomActions() ?? []).contains { $0.name.contains("allow") },"Allow is not an accessibility action")
                try await waitUntil { overlay.view.approval == nil && overlay.view.pressed == nil }
                try check(Date().timeIntervalSince(holdStart) >= ActivityView.holdDuration,"Allow waits for the full hold")
                try check(overlay.view.approval == nil && overlay.view.pressed == nil,"Holding Allow for half a second answers the question")
                let held = await overlay.requestApproval(key:key,title:"Claude wants to click “Send”",detail:"",wait:0.5)
                try check(held == .approved,"The held Allow approves the waiting action once")
                _ = await overlay.requestApproval(key:key,title:"Claude wants to click “Send”",detail:"“Send” looks like it can’t be undone",wait:0.3)
                try await waitUntil { overlay.view.expanded && overlay.view.reveal >= 1 }
                _ = try await capture(overlay.panel,to:dir.appendingPathComponent("activity-approval.png"))
                overlay.press(.allow)
                let clicked = await overlay.requestApproval(key:key,title:"Claude wants to click “Send”",detail:"",wait:0.5)
                try check(clicked == .approved,"Allow approves the waiting action once")
                try await waitUntil { !overlay.view.expanded }
                try check(!overlay.view.expanded,"The card closes once answered")
                overlay.release()
                try check(!overlay.panel.isVisible && !overlay.ghost.isVisible,"Release removes all UI")
                print("{\"passed\":\(checks),\"hoverExpanded\":true,\"dotsAnimated\":true,\"focusPreserved\":true}")
                overlay.shutdown(); fixture.terminate(); app.terminate(nil)
            } catch {
                fputs("Overlay UI test failed: \(error)\n",stderr)
                overlay.shutdown(); if fixture.isRunning { fixture.terminate() }; exit(1)
            }
        }
        app.run()
    }
}
