import AppKit
import ApplicationServices

struct Failure: Error { let code: String; let message: String; var details: [String:Any]? = nil }
func fail(_ code: String, _ message: String) throws -> Never { throw Failure(code: code, message: message) }
func string(_ request: [String: Any], _ key: String) throws -> String {
    guard let value = request[key] as? String, !value.isEmpty else { try fail("INVALID_ARGUMENT", "\(key) must be a nonempty string") }
    return value
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func axCheck(_ result: AXError, _ operation: String) throws {
    guard result == .success else { try fail("AX_ERROR", "\(operation) failed (AXError \(result.rawValue)). Observe again; the app may not support this action.") }
}
func frontmost() -> String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown" }
func owningWindow(_ element: AXUIElement) -> AXUIElement? {
    if (attribute(element,kAXRoleAttribute) as? String) == kAXWindowRole { return element }
    return axElement(attribute(element,kAXWindowAttribute))
}

