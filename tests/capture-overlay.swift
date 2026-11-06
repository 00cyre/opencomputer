// Test-only capture: permits only the OpenComputer helper's own windows.
import AppKit
import ScreenCaptureKit
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let args = CommandLine.arguments
if args.count != 4 { fatalError("capture-overlay HELPER_PID WINDOW_ID OUTPUT_PNG") }
let pid = pid_t(args[1])!
let windowID = CGWindowID(args[2])!
guard NSRunningApplication(processIdentifier:pid)?.executableURL?.lastPathComponent == "opencomputer-native" else { fatalError("Only an OpenComputer helper may be captured") }
let content = try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:false)
guard let window = content.windows.first(where:{$0.windowID == windowID && $0.owningApplication?.processID == pid}) else { fatalError("Helper window not found") }
let config = SCStreamConfiguration(); config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2); config.showsCursor = false
let image: CGImage = try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:window),configuration:config)
let data = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!
try data.write(to:URL(fileURLWithPath:args[3]))
print(args[3])
