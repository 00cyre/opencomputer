import AppKit
import ScreenCaptureKit

@main
struct OverlayUITest {
    @MainActor
    static func capture(_ panel: NSPanel, to file: URL) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:false)
        guard let window = content.windows.first(where:{$0.windowID == CGWindowID(panel.windowNumber) && $0.owningApplication?.processID == getpid()}) else { throw Failure(code:"UI_TEST",message:"Own overlay window missing") }
        let config = SCStreamConfiguration(); config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2); config.showsCursor = false
        let image: CGImage = try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:window),configuration:config)
        guard let data = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else { throw Failure(code:"UI_TEST",message:"PNG encoding failed") }
        try data.write(to:file)
        return data
    }
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
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
                overlay.track(target,action:"Editing benchmark token")
                try await Task.sleep(nanoseconds:250_000_000)
                try check(overlay.panel.isVisible && !overlay.view.expanded,"Activity begins collapsed")
                let first = try await capture(overlay.panel,to:dir.appendingPathComponent("activity-collapsed.png"))
                try await Task.sleep(nanoseconds:200_000_000)
                let second = try await capture(overlay.panel,to:dir.appendingPathComponent("activity-animation-frame.png"))
                try check(first != second,"Animation changes the rendered dot pixels")
                try check(overlay.ghost.isVisible,"Ghost visible over exposed fixture")
                _ = try await capture(overlay.ghost,to:dir.appendingPathComponent("ghost-cursor.png"))
                pointer = NSPoint(x:overlay.panel.frame.midX,y:overlay.panel.frame.midY)
                try await Task.sleep(nanoseconds:250_000_000)
                try check(overlay.view.expanded && overlay.panel.frame.width == 380,"Hover expands activity details")
                try check(overlay.view.agent.name == "Claude" && overlay.view.appName == "OpenComputer Fixture","Expanded details identify the right agent and app")
                try check(overlay.view.windowTitle == "OpenComputer Test Fixture","Expanded details include the target window title")
                try check(!overlay.panel.canBecomeKey && !overlay.panel.canBecomeMain && !overlay.panel.isKeyWindow && !overlay.panel.isMainWindow,"Expanded panel cannot own focus")
                try check(overlay.panel.ignoresMouseEvents && overlay.ghost.ignoresMouseEvents,"Both annotations remain click-through during hover")
                try check(NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid(),"Overlay process never becomes foreground")
                _ = try await capture(overlay.panel,to:dir.appendingPathComponent("activity-expanded.png"))
                pointer = NSPoint(x:-10000,y:-10000)
                try await Task.sleep(nanoseconds:350_000_000)
                try check(!overlay.view.expanded && overlay.panel.frame.width == 54,"Leaving the pill collapses it")
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
