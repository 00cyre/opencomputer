import AppKit
import ApplicationServices
import Vision

// What a screenshot or a container shows, in forms a model reads cheaply: element ids
// drawn over the picture, text recognized in the pixels, and the text of a subtree.

// An element id and its box in screenshot pixels, top-left origin.
struct Mark { let id: Int; let rect: CGRect }

// Draws each mark as a coloured box with its id on a tag above it (inside it when there
// is no room above). The picture itself is unchanged underneath.
func annotate(_ image: CGImage, marks: [Mark]) -> CGImage? {
    let width = image.width, height = image.height
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    // Flip so y grows downward, like the pixel coordinates agents use.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    defer { NSGraphicsContext.current = previous }
    let palette: [NSColor] = [
        NSColor(srgbRed: 0.90, green: 0.22, blue: 0.21, alpha: 1), NSColor(srgbRed: 0.12, green: 0.47, blue: 0.85, alpha: 1),
        NSColor(srgbRed: 0.18, green: 0.56, blue: 0.25, alpha: 1), NSColor(srgbRed: 0.85, green: 0.45, blue: 0.05, alpha: 1),
        NSColor(srgbRed: 0.55, green: 0.27, blue: 0.75, alpha: 1), NSColor(srgbRed: 0.80, green: 0.20, blue: 0.55, alpha: 1),
        NSColor(srgbRed: 0.05, green: 0.55, blue: 0.60, alpha: 1), NSColor(srgbRed: 0.45, green: 0.33, blue: 0.20, alpha: 1),
    ]
    let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    for (n, mark) in marks.enumerated() {
        let color = palette[n % palette.count]
        color.setStroke()
        let box = NSBezierPath(rect: mark.rect.insetBy(dx: 0.75, dy: 0.75))
        box.lineWidth = 1.5
        box.stroke()
        let label = String(mark.id) as NSString
        let size = label.size(withAttributes: attributes)
        var tag = CGRect(x: mark.rect.minX, y: mark.rect.minY - size.height - 2, width: size.width + 6, height: size.height + 2)
        if tag.minY < 0 { tag.origin.y = mark.rect.minY }
        if tag.maxX > CGFloat(width) { tag.origin.x = max(0, CGFloat(width) - tag.width) }
        color.setFill()
        NSBezierPath(roundedRect: tag, xRadius: 3, yRadius: 3).fill()
        label.draw(at: CGPoint(x: tag.minX + 3, y: tag.minY + 1), withAttributes: attributes)
    }
    context.flush()
    return context.makeImage()
}

// Text lines Vision finds in the picture, with boxes in its pixels (top-left origin), in
// reading order. For canvases and custom-drawn controls the outline cannot see.
func recognizeText(_ image: CGImage) throws -> [[String: Any]] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
    catch { try fail("OCR_FAILED", "Text recognition failed: \(error.localizedDescription)") }
    let width = CGFloat(image.width), height = CGFloat(image.height)
    var lines: [[String: Any]] = []
    for observation in request.results ?? [] {
        guard let best = observation.topCandidates(1).first else { continue }
        let box = observation.boundingBox
        lines.append(["text": best.string,
                      "x": Int((box.minX * width).rounded()), "y": Int(((1 - box.maxY) * height).rounded()),
                      "width": Int((box.width * width).rounded()), "height": Int((box.height * height).rounded()),
                      "confidence": (Double(best.confidence) * 100).rounded() / 100])
    }
    // Rows top to bottom, then left to right; boxes within half a line count as one row.
    return lines.sorted { a, b in
        let ay = a["y"] as? Int ?? 0, by = b["y"] as? Int ?? 0
        let ah = a["height"] as? Int ?? 0
        if abs(ay - by) > max(4, ah / 2) { return ay < by }
        return (a["x"] as? Int ?? 0) < (b["x"] as? Int ?? 0)
    }
}

// A menu item's keyboard shortcut in pressKey syntax (cmd+shift+s), or nil. Only a
// printable character, or a key code with a name (Return, F5, arrows), counts: items
// without a shortcut can still report key code 0, which would read as "a".
func menuShortcut(_ element: AXUIElement) -> String? {
    var raw: CFArray?
    let names = [kAXMenuItemCmdCharAttribute, kAXMenuItemCmdVirtualKeyAttribute, kAXMenuItemCmdModifiersAttribute] as CFArray
    guard AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
          let list = raw as? [AnyObject], list.count == 3 else { return nil }
    var key: String?
    if let char = list[0] as? String, char.unicodeScalars.count == 1, let scalar = char.unicodeScalars.first,
       scalar.value > 32, scalar.value < 0xF700, !CharacterSet.controlCharacters.contains(scalar) {
        key = char.lowercased()
    } else if let code = list[1] as? NSNumber, let name = Keys.names[CGKeyCode(truncatingIfNeeded: code.intValue)] {
        key = name
    }
    guard let key else { return nil }
    // kAXMenuItemModifier bits: shift 1, option 2, control 4, and 8 when there is no command key.
    let flags = (list[2] as? NSNumber)?.intValue ?? 0
    var parts: [String] = []
    if flags & 8 == 0 { parts.append("cmd") }
    if flags & 4 != 0 { parts.append("ctrl") }
    if flags & 2 != 0 { parts.append("alt") }
    if flags & 1 != 0 { parts.append("shift") }
    return (parts + [key]).joined(separator: "+")
}

extension Computer {
    // The text inside a container in reading order: static text, field values, and the
    // labels of leaf buttons and links, each once. Pieces on one visual line are joined
    // with spaces. Secure fields are skipped.
    func collectText(_ root: AXUIElement, maxCharacters: Int, deadline: Date) -> (text: String, truncated: Bool) {
        var lines: [String] = []
        var line = ""
        var lineMid: CGFloat?
        var count = 0
        var visited = 0
        var truncated = false
        func emit(_ piece: String, _ frame: CGRect?) {
            let text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if let frame, let mid = lineMid, !line.isEmpty, abs(frame.midY - mid) < max(4, frame.height / 2) { line += " " + text }
            else {
                if !line.isEmpty { lines.append(line) }
                line = text
            }
            lineMid = frame?.midY
            count += text.count + 1
        }
        func walk(_ element: AXUIElement, _ depth: Int) {
            guard !truncated else { return }
            guard depth <= 80, visited < 20000, count < maxCharacters, Date() < deadline else { truncated = true; return }
            visited += 1
            let v = values(element)
            let role = v[0] as? String ?? ""
            if (v[1] as? String) == kAXSecureTextFieldSubrole { return }
            var frame: CGRect?
            if let p = v[10], let s = v[11], CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() {
                var point = CGPoint.zero; var size = CGSize.zero
                AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point)
                AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size)
                frame = CGRect(origin: point, size: size)
            }
            let children = v[12] as? [AXUIElement] ?? []
            let title = v[2] as? String
            let description = v[3] as? String
            if role == kAXStaticTextRole {
                emit((v[5] as? String) ?? title ?? description ?? "", frame)
                return
            }
            if Computer.textRoles.contains(role), let value = v[5] as? String { emit(value, frame) }
            else if children.isEmpty, [kAXButtonRole, "AXLink", kAXMenuItemRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole].contains(role) {
                emit(title ?? description ?? "", frame)
            }
            for child in children { walk(child, depth + 1) }
        }
        walk(root, 0)
        if !line.isEmpty { lines.append(line) }
        return (lines.joined(separator: "\n"), truncated)
    }
}
