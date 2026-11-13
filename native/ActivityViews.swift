import AppKit

// Drawing for the activity card and the ghost cursor. Layout and state live in
// ActivityOverlay.swift; everything here is a pure function of the view's properties.

func clamp01(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }
/// Cubic ease-out: quick to respond, soft to land.
func easeOut(_ value: CGFloat) -> CGFloat { let t = 1 - clamp01(value); return 1 - t * t * t }

/// Colours that follow the system appearance, so the card reads like native macOS chrome.
struct OverlayTheme {
    let dark: Bool
    init(_ appearance: NSAppearance) { dark = appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua }
    var primary: NSColor { NSColor(white:dark ? 1 : 0.07, alpha:dark ? 0.95 : 0.92) }
    var secondary: NSColor { NSColor(white:dark ? 1 : 0.07, alpha:dark ? 0.62 : 0.58) }
    var tertiary: NSColor { NSColor(white:dark ? 1 : 0.07, alpha:dark ? 0.40 : 0.40) }
    var hairline: NSColor { NSColor(white:dark ? 1 : 0, alpha:dark ? 0.10 : 0.08) }
    var rim: NSColor { NSColor(white:1, alpha:dark ? 0.16 : 0.70) }
    var wash: NSColor { dark ? NSColor(srgbRed:0.075,green:0.08,blue:0.095,alpha:0.58) : NSColor(white:0.99,alpha:0.62) }
    var control: NSColor { NSColor(white:dark ? 1 : 0, alpha:dark ? 0.10 : 0.055) }
    var controlHover: NSColor { NSColor(white:dark ? 1 : 0, alpha:dark ? 0.17 : 0.10) }
    var ring: NSColor { dark ? NSColor(srgbRed:0.15,green:0.155,blue:0.17,alpha:1) : NSColor(white:0.97,alpha:1) }
    var solid: NSColor { dark ? NSColor(white:0.97,alpha:1) : NSColor(white:0.09,alpha:1) }
    var onSolid: NSColor { dark ? NSColor(white:0.08,alpha:1) : NSColor(white:1,alpha:1) }
    static let amber = NSColor(srgbRed:0.96,green:0.62,blue:0.13,alpha:1)
}

extension NSColor {
    /// Near-black or white, whichever reads better on this colour (WCAG relative luminance).
    var readableText: NSColor {
        guard let c = usingColorSpace(.sRGB) else { return .white }
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        return luminance > 0.2 ? NSColor(white:0.08,alpha:1) : .white
    }
}

func textAttributes(_ font: NSFont, _ color: NSColor, _ align: NSTextAlignment = .left) -> [NSAttributedString.Key:Any] {
    let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail; paragraph.alignment = align
    return [.font:font,.foregroundColor:color,.paragraphStyle:paragraph]
}
func drawText(_ value: String, _ rect: NSRect, _ font: NSFont, _ color: NSColor, _ align: NSTextAlignment = .left) {
    (value as NSString).draw(in:rect,withAttributes:textAttributes(font,color,align))
}
func textWidth(_ value: String, _ font: NSFont) -> CGFloat { ceil((value as NSString).size(withAttributes:[.font:font]).width) }
func shortDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    return s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m" : "\(s / 3600)h"
}
func clockDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    return s < 3600 ? String(format:"%d:%02d", s / 60, s % 60) : String(format:"%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
}

struct ActivityStep {
    enum State { case running, waiting, done, failed }
    var text: String
    var detail: String?
    var state: State
    let started: Date
    let serial: Int
    var open: Bool { state == .running || state == .waiting }
}

enum CardButton {
    case takeOver, resume, allow, deny
    var title: String {
        switch self {
        case .takeOver: return "Take over"
        case .resume: return "Resume"
        case .allow: return "Allow"
        case .deny: return "Deny"
        }
    }
    var primary: Bool { self == .allow || self == .resume }
}

/// The activity indicator: three dots that open into a card on hover.
final class ActivityView: NSView {
    static let pillWidth: CGFloat = 56
    static let pillHeight: CGFloat = 30
    static let cardWidth: CGFloat = 360
    static let pad: CGFloat = 14
    static let bodyTop: CGFloat = 67
    static func radius(_ reveal: CGFloat) -> CGFloat { 15 + 3 * clamp01(reveal) }

    var expanded = false
    var reveal: CGFloat = 0
    var agent = AgentIdentity("Agent")
    var agentIcon: NSImage?
    var appIcon: NSImage?
    var appName = ""
    var windowTitle = ""
    var action = "Working"
    var blocked = false
    var paused = false
    var approval: ApprovalRequest?
    var steps: [ActivityStep] = []
    var startedAt = Date()
    var hovered: CardButton?
    var pressed: CardButton?
    var onButton: ((CardButton) -> Void)?
    private var drawAlpha: CGFloat = 1

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var bodyHeight: CGFloat { approval != nil ? 46 : CGFloat(max(1, min(3, steps.count))) * 22 }
    var expandedHeight: CGFloat { ActivityView.bodyTop + bodyHeight + 10 + 28 + 12 }
    var statusColor: NSColor { approval != nil || blocked ? OverlayTheme.amber : paused ? NSColor.systemGray : agent.color }
    var statusText: String {
        if approval != nil { return "Needs your OK" }
        if paused { return "Paused · you have control" }
        return blocked ? "Waiting for you" : "Working"
    }
    var buttons: [CardButton] { approval != nil ? [.deny,.allow] : paused ? [.resume] : [.takeOver] }
    static let buttonFont = NSFont.systemFont(ofSize:12,weight:.semibold)

    /// Button frames in card coordinates (the card is drawn right-aligned in the view).
    func cardButtonFrames() -> [(CardButton,NSRect)] {
        let y = ActivityView.bodyTop + bodyHeight + 10 + 1
        var x = ActivityView.cardWidth - ActivityView.pad
        var frames: [(CardButton,NSRect)] = []
        for button in buttons.reversed() {
            let width = textWidth(button.title,ActivityView.buttonFont) + 28
            x -= width
            frames.insert((button,NSRect(x:x,y:y,width:width,height:26)),at:0)
            x -= 8
        }
        return frames
    }
    func buttonFrames() -> [(CardButton,NSRect)] {
        let dx = bounds.width - ActivityView.cardWidth
        return cardButtonFrames().map { ($0.0,$0.1.offsetBy(dx:dx,dy:0)) }
    }
    func button(at point: NSPoint) -> CardButton? {
        guard expanded, reveal > 0.9 else { return nil }
        return buttonFrames().first { $0.1.insetBy(dx:-3,dy:-3).contains(point) }?.0
    }

    override func mouseDown(with event: NSEvent) {
        pressed = button(at:convert(event.locationInWindow,from:nil)); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        let released = button(at:convert(event.locationInWindow,from:nil))
        if let button = pressed, button == released { onButton?(button) }
        pressed = nil; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let theme = OverlayTheme(effectiveAppearance)
        let radius = ActivityView.radius(reveal)
        let shape = NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:radius,yRadius:radius)
        theme.wash.setFill(); shape.fill()
        // A faint wash of the status colour from the top edge ties the card to its agent.
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGradient(starting:statusColor.withAlphaComponent(theme.dark ? 0.20 : 0.13),ending:statusColor.withAlphaComponent(0))?
            .draw(in:NSRect(x:0,y:0,width:bounds.width,height:min(bounds.height,70)),angle:90)
        NSGraphicsContext.restoreGraphicsState()
        theme.rim.setStroke(); shape.lineWidth = 1; shape.stroke()

        let collapsedAlpha = clamp01(1 - reveal * 2.5)
        let expandedAlpha = clamp01((reveal - 0.3) / 0.7)
        if collapsedAlpha > 0.01 {
            NSGraphicsContext.saveGraphicsState()
            drawAlpha = collapsedAlpha; context.setAlpha(drawAlpha)
            drawDots(theme,centerX:bounds.width - ActivityView.pillWidth / 2)
            NSGraphicsContext.restoreGraphicsState()
        }
        if expandedAlpha > 0.01 {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            drawAlpha = expandedAlpha; context.setAlpha(drawAlpha)
            // The card grows from the dots at the top right; content settles in from above.
            let shift = NSAffineTransform()
            shift.translateX(by:bounds.width - ActivityView.cardWidth,yBy:(1 - expandedAlpha) * -6)
            shift.concat()
            drawCard(theme)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    func drawDots(_ theme: OverlayTheme, centerX: CGFloat) {
        let cy = ActivityView.pillHeight / 2
        if paused && approval == nil {
            theme.secondary.setFill()
            for dx: CGFloat in [-3.75,1.25] { NSBezierPath(roundedRect:NSRect(x:centerX + dx,y:cy - 5,width:2.5,height:10),xRadius:1.25,yRadius:1.25).fill() }
            return
        }
        let now = Date.timeIntervalSinceReferenceDate
        let speed = blocked || approval != nil ? 2.6 : 4.4
        for i in 0..<3 {
            let wave = CGFloat((sin(now * speed - Double(i) * 0.8) + 1) / 2)
            statusColor.withAlphaComponent(0.32 + 0.68 * wave).setFill()
            let x = centerX + CGFloat(i - 1) * 10
            NSBezierPath(ovalIn:NSRect(x:x - 2.6,y:cy - 2.6 - wave * 1.6,width:5.2,height:5.2)).fill()
        }
    }

    func drawCard(_ theme: OverlayTheme) {
        let width = ActivityView.cardWidth, pad = ActivityView.pad
        let now = Date()

        // Who is working where: the app's icon, badged with the agent.
        let appRect = NSRect(x:pad,y:pad,width:32,height:32)
        if let appIcon { appIcon.draw(in:appRect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil) }
        else {
            theme.control.setFill(); NSBezierPath(roundedRect:appRect.insetBy(dx:2,dy:2),xRadius:7,yRadius:7).fill()
            drawText(String(appName.prefix(1)).uppercased(),NSRect(x:pad,y:pad + 7,width:32,height:18),.systemFont(ofSize:13,weight:.semibold),theme.secondary,.center)
        }
        let badge = NSRect(x:pad + 20,y:pad + 20,width:17,height:17)
        theme.ring.setFill(); NSBezierPath(ovalIn:badge.insetBy(dx:-2,dy:-2)).fill()
        if let agentIcon {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn:badge).addClip()
            agentIcon.draw(in:badge.insetBy(dx:-2.5,dy:-2.5),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            agent.color.setFill(); NSBezierPath(ovalIn:badge).fill()
            drawText(String(agent.name.prefix(1)).uppercased(),NSRect(x:badge.minX,y:badge.minY + 2,width:badge.width,height:13),.systemFont(ofSize:9.5,weight:.bold),agent.color.readableText,.center)
        }

        let titleX = pad + 32 + 12, clock: CGFloat = 44
        let title = NSMutableAttributedString(string:agent.name,attributes:textAttributes(.systemFont(ofSize:13,weight:.semibold),theme.primary))
        title.append(NSAttributedString(string:" is using ",attributes:textAttributes(.systemFont(ofSize:13),theme.secondary)))
        title.append(NSAttributedString(string:appName,attributes:textAttributes(.systemFont(ofSize:13,weight:.semibold),theme.primary)))
        title.draw(in:NSRect(x:titleX,y:pad - 1,width:width - titleX - pad - clock,height:18))
        drawText(windowTitle.isEmpty ? appName : windowTitle,NSRect(x:titleX,y:pad + 17,width:width - titleX - pad,height:16),.systemFont(ofSize:11.5),theme.secondary)
        drawText(clockDuration(now.timeIntervalSince(startedAt)),NSRect(x:width - pad - clock,y:pad + 1,width:clock,height:15),.monospacedDigitSystemFont(ofSize:11,weight:.medium),theme.tertiary,.right)

        theme.hairline.setFill(); NSBezierPath(rect:NSRect(x:pad,y:57,width:width - pad * 2,height:1)).fill()

        let top = ActivityView.bodyTop
        if let approval { drawApproval(approval,theme,top:top) } else { drawSteps(theme,top:top,now:now) }

        // Status on the left, the person's controls on the right.
        let footer = top + bodyHeight + 10
        let pulse = CGFloat((sin(Date.timeIntervalSinceReferenceDate * 3) + 1) / 2)
        let dot = NSRect(x:pad + 1,y:footer + 11,width:6,height:6)
        if !paused || approval != nil {
            statusColor.withAlphaComponent(0.28 * (1 - pulse)).setFill()
            NSBezierPath(ovalIn:dot.insetBy(dx:-4 * pulse,dy:-4 * pulse)).fill()
        }
        statusColor.setFill(); NSBezierPath(ovalIn:dot).fill()
        drawText(statusText,NSRect(x:pad + 15,y:footer + 6,width:170,height:16),.systemFont(ofSize:11.5,weight:.medium),theme.secondary)
        for (button,frame) in cardButtonFrames() {
            let path = NSBezierPath(roundedRect:frame,xRadius:13,yRadius:13)
            var fill = button.primary ? theme.solid : hovered == button ? theme.controlHover : theme.control
            if button.primary && hovered == button { fill = fill.withAlphaComponent(0.86) }
            if pressed == button { fill = fill.withAlphaComponent(fill.alphaComponent * 0.7) }
            fill.setFill(); path.fill()
            if !button.primary { theme.hairline.setStroke(); path.lineWidth = 1; path.stroke() }
            drawText(button.title,NSRect(x:frame.minX,y:frame.minY + 5,width:frame.width,height:16),ActivityView.buttonFont,button.primary ? theme.onSolid : theme.primary,.center)
        }
    }

    func drawSteps(_ theme: OverlayTheme, top: CGFloat, now: Date) {
        let width = ActivityView.cardWidth, pad = ActivityView.pad
        let shown = steps.suffix(3)
        guard !shown.isEmpty else {
            drawText(action,NSRect(x:pad + 18,y:top + 3,width:width - pad * 2 - 18,height:16),.systemFont(ofSize:12,weight:.medium),theme.primary)
            return
        }
        let clock = Date.timeIntervalSinceReferenceDate
        for (i,step) in shown.enumerated() {
            let latest = i == shown.count - 1
            // The newest step slides up into place.
            let appear = latest ? easeOut(CGFloat(now.timeIntervalSince(step.started) / 0.28)) : 1
            let y = top + CGFloat(i) * 22 + (1 - appear) * 7
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(drawAlpha * appear)
            let center = NSPoint(x:pad + 5,y:y + 11)
            switch step.state {
            case .running, .waiting:
                let color = step.state == .waiting ? OverlayTheme.amber : agent.color
                let wave = CGFloat((sin(clock * (step.state == .waiting ? 2.6 : 4.2)) + 1) / 2)
                color.withAlphaComponent(0.25 * (1 - wave)).setFill()
                NSBezierPath(ovalIn:NSRect(x:center.x - 3 - 3.5 * wave,y:center.y - 3 - 3.5 * wave,width:6 + 7 * wave,height:6 + 7 * wave)).fill()
                color.setFill(); NSBezierPath(ovalIn:NSRect(x:center.x - 3,y:center.y - 3,width:6,height:6)).fill()
            case .done:
                let check = NSBezierPath()
                check.move(to:NSPoint(x:center.x - 3.6,y:center.y + 0.2)); check.line(to:NSPoint(x:center.x - 1.1,y:center.y + 2.7)); check.line(to:NSPoint(x:center.x + 3.7,y:center.y - 2.6))
                check.lineWidth = 1.6; check.lineCapStyle = .round; check.lineJoinStyle = .round
                theme.tertiary.setStroke(); check.stroke()
            case .failed:
                let cross = NSBezierPath()
                cross.move(to:NSPoint(x:center.x - 2.8,y:center.y - 2.8)); cross.line(to:NSPoint(x:center.x + 2.8,y:center.y + 2.8))
                cross.move(to:NSPoint(x:center.x + 2.8,y:center.y - 2.8)); cross.line(to:NSPoint(x:center.x - 2.8,y:center.y + 2.8))
                cross.lineWidth = 1.6; cross.lineCapStyle = .round
                OverlayTheme.amber.setStroke(); cross.stroke()
            }
            let text: String
            switch step.state {
            case .waiting: text = step.detail ?? step.text
            case .failed: text = step.detail.map { "\(step.text) — \($0)" } ?? step.text
            default: text = step.text
            }
            let emphasis = latest && step.open
            drawText(text,NSRect(x:pad + 18,y:y + 3,width:width - pad * 2 - 18 - 38,height:16),.systemFont(ofSize:12,weight:emphasis ? .medium : .regular),emphasis ? theme.primary : theme.secondary)
            let age = now.timeIntervalSince(step.started)
            drawText(latest && step.open && age < 2 ? "now" : shortDuration(age),NSRect(x:width - pad - 36,y:y + 4,width:36,height:14),.monospacedDigitSystemFont(ofSize:10.5,weight:.regular),theme.tertiary,.right)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    func drawApproval(_ approval: ApprovalRequest, _ theme: OverlayTheme, top: CGFloat) {
        let width = ActivityView.cardWidth, pad = ActivityView.pad
        let circle = NSRect(x:pad,y:top + 4,width:30,height:30)
        OverlayTheme.amber.withAlphaComponent(0.18).setFill(); NSBezierPath(ovalIn:circle).fill()
        OverlayTheme.amber.setFill()
        NSBezierPath(roundedRect:NSRect(x:circle.midX - 1.4,y:circle.minY + 7.5,width:2.8,height:10),xRadius:1.4,yRadius:1.4).fill()
        NSBezierPath(ovalIn:NSRect(x:circle.midX - 1.7,y:circle.minY + 19.5,width:3.4,height:3.4)).fill()
        drawText(approval.title,NSRect(x:pad + 42,y:top + 2,width:width - pad * 2 - 42,height:18),.systemFont(ofSize:13,weight:.semibold),theme.primary)
        drawText(approval.detail,NSRect(x:pad + 42,y:top + 21,width:width - pad * 2 - 42,height:16),.systemFont(ofSize:11.5),theme.secondary)
    }
}

/// The agent's cursor: an arrow in the agent's colour with its name tag, drawn at the
/// visible target. It eases between targets, tilts with its motion, and dips with a ripple
/// when an action lands. Purely visual: the real pointer never moves.
final class GhostView: NSView {
    static let size = NSSize(width:190,height:68)
    /// Where the arrow's tip sits in the view (flipped coordinates).
    static let tip = NSPoint(x:20,y:18)
    var tint = NSColor.systemTeal
    var name = "Agent"
    /// Set when an action lands on a control; drives the press dip and ripple.
    var pulseUntil = Date.distantPast
    var tilt: CGFloat = 0
    override var isFlipped: Bool { true }

    /// The arrow, tip at the origin, pointing up-left.
    static func arrow() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to:NSPoint(x:0,y:0))
        path.line(to:NSPoint(x:0,y:17.2))
        path.line(to:NSPoint(x:4.4,y:13.1))
        path.line(to:NSPoint(x:7.5,y:19.8))
        path.line(to:NSPoint(x:10.6,y:18.4))
        path.line(to:NSPoint(x:7.6,y:11.8))
        path.line(to:NSPoint(x:13.4,y:11.8))
        path.close()
        path.lineJoinStyle = .round
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        let tip = GhostView.tip
        let remaining = pulseUntil.timeIntervalSinceNow
        let press = remaining > 0 ? clamp01(CGFloat(1 - remaining / 0.6)) : 1
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width:0,height:-1.5)
        shadow.shadowBlurRadius = 4
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)

        if press < 1 {
            let radius = 4 + 17 * easeOut(press)
            let ring = NSBezierPath(ovalIn:NSRect(x:tip.x - radius,y:tip.y - radius,width:radius * 2,height:radius * 2))
            tint.withAlphaComponent(0.55 * (1 - press)).setStroke(); ring.lineWidth = 2; ring.stroke()
            tint.withAlphaComponent(0.12 * (1 - press)).setFill(); ring.fill()
        }

        NSGraphicsContext.saveGraphicsState()
        let scale = 1 - 0.14 * sin(.pi * min(1, press / 0.45))
        let transform = NSAffineTransform()
        transform.translateX(by:tip.x,yBy:tip.y)
        transform.rotate(byDegrees:tilt)
        transform.scale(by:scale)
        transform.concat()
        let arrow = GhostView.arrow()
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.white.setStroke(); arrow.lineWidth = 3.4; arrow.stroke()
        NSColor.white.setFill(); arrow.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting:tint.blended(withFraction:0.28,of:.white) ?? tint,ending:tint)?.draw(in:arrow,angle:90)
        (tint.shadow(withLevel:0.28) ?? tint).withAlphaComponent(0.55).setStroke(); arrow.lineWidth = 0.6; arrow.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // Name tag, tucked under the arrow's tail.
        let font = NSFont.systemFont(ofSize:11,weight:.semibold)
        let labelWidth = min(GhostView.size.width - tip.x - 14 - 6, textWidth(name,font) + 16)
        let tag = NSRect(x:tip.x + 12,y:tip.y + 20,width:labelWidth,height:19)
        let pill = NSBezierPath(roundedRect:tag,xRadius:9.5,yRadius:9.5)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        tint.setFill(); pill.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.9).setStroke(); pill.lineWidth = 1.5; pill.stroke()
        drawText(name,NSRect(x:tag.minX + 8,y:tag.minY + 2.5,width:tag.width - 16,height:15),font,tint.readableText,.center)
    }
}
