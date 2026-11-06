import Foundation
import CoreGraphics

/// A seekable cursor path: eased travel, followed by a small idle hover.
struct GhostMotion {
    private(set) var start: CGPoint?
    private(set) var target: CGPoint?
    private(set) var startedAt: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    mutating func move(to point: CGPoint, at time: TimeInterval, snap: Bool = false) {
        if let target = target, hypot(point.x-target.x, point.y-target.y) < 0.25, !snap { return }
        let current = position(at:time) ?? point
        start = snap ? point : current
        target = point
        startedAt = time
        duration = snap ? 0 : min(0.5, max(0.22, hypot(point.x-current.x,point.y-current.y)/1100 + 0.18))
    }
    func isFloating(at time: TimeInterval) -> Bool { target != nil && time-startedAt > duration+0.6 }
    func position(at time: TimeInterval) -> CGPoint? {
        guard let start = start, let target = target else { return nil }
        let elapsed = max(0,time-startedAt)
        let progress = duration > 0 ? min(1,elapsed/duration) : 1
        // Quintic smoothstep gives zero velocity and acceleration at both ends.
        let eased = progress*progress*progress*(progress*(progress*6-15)+10)
        var point = CGPoint(x:start.x+(target.x-start.x)*eased,y:start.y+(target.y-start.y)*eased)
        let idle = max(0,elapsed-duration-0.6)
        let blend = min(1,idle/0.5)
        let phase = idle * 2 * Double.pi / 2.4
        point.x += 0.65 * sin(phase*0.5) * blend
        point.y += 2.4 * sin(phase) * blend
        return point
    }
}
