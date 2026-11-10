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
    switch result {
    case .success: return
    case .invalidUIElement: try fail("STALE_ELEMENT", "\(operation): this element no longer exists. Observe again and use a current element.")
    case .actionUnsupported, .attributeUnsupported: try fail("UNSUPPORTED_ACTION", "\(operation) is not supported by this element. Check its actions in the snapshot or try another control.")
    default: try fail("AX_ERROR", "\(operation) failed (AXError \(result.rawValue)). Observe again; the app may not support this action.")
    }
}
func frontmost() -> String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown" }
func owningWindow(_ element: AXUIElement) -> AXUIElement? {
    if (attribute(element,kAXRoleAttribute) as? String) == kAXWindowRole { return element }
    return axElement(attribute(element,kAXWindowAttribute))
}
func roleOf(_ element: AXUIElement) -> String { attribute(element,kAXRoleAttribute) as? String ?? "" }
func parentOf(_ element: AXUIElement) -> AXUIElement? { axElement(attribute(element,kAXParentAttribute)) }
func actionNames(_ element: AXUIElement) -> [String] {
    var actions: CFArray?
    AXUIElementCopyActionNames(element,&actions)
    return actions as? [String] ?? []
}
func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
    var settable: DarwinBoolean = false
    return AXUIElementIsAttributeSettable(element,name as CFString,&settable) == .success && settable.boolValue
}
