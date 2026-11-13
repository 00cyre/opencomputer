import Foundation
import CoreGraphics

@main struct GhostMotionTests {
    static func main() {
        var motion = GhostMotion()
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition,message); checks += 1 }
        check(motion.position(at:0) == nil,"No cursor position before a target exists")
        motion.move(to:.zero,at:0,snap:true)
        motion.move(to:CGPoint(x:400,y:200),at:0.1)
        check(motion.position(at:0.1) == .zero,"Retarget starts at the displayed position")
        let middle = motion.position(at:0.1+motion.duration/2)!
        let bow = GhostMotion.bow(from:.zero,to:CGPoint(x:400,y:200))
        check(abs(middle.x-(200+bow.x))<0.001 && abs(middle.y-(100+bow.y))<0.001,"Motion passes its midpoint on the arc")
        check(bow.y > 0 && abs(hypot(bow.x,bow.y)-hypot(400,200)*0.09)<0.001,"The arc bows upward by 9% of the distance")
        check(abs(bow.x*400+bow.y*200)<0.001,"The arc bows square to the line of travel")
        let up = GhostMotion.bow(from:.zero,to:CGPoint(x:0,y:300)), across = GhostMotion.bow(from:.zero,to:CGPoint(x:-2000,y:0))
        check(up.x < 0 && abs(up.y) < 0.001 && across.y == 36,"Vertical moves bow left; long moves bow at most 36 points")
        let landed = motion.position(at:0.1+motion.duration)!
        check(landed == CGPoint(x:400,y:200),"Cursor reaches the target without overshoot")
        check(!motion.isFloating(at:0.1+motion.duration+0.3),"Action holds before idle animation")
        let deadline = motion.startedAt+motion.duration
        let positions = (0..<180).map { motion.position(at:deadline+0.6+Double($0)/60)! }
        check(positions.allSatisfy {abs($0.x-400)<=0.66 && abs($0.y-200)<=2.41},"Idle hover stays within a small target-local radius")
        check(Set(positions.map {Int($0.y*100)}).count > 30,"Idle cursor continues floating")
        let now=deadline+1.4, current=motion.position(at:deadline+1.4)!
        motion.move(to:CGPoint(x:100,y:500),at:now)
        check(motion.position(at:now)==current,"Retargeting from idle has no position discontinuity")
        let start=motion.startedAt
        motion.move(to:CGPoint(x:100,y:500),at:now+0.1)
        check(motion.startedAt==start,"Repeated target refresh does not reset animation")
        print("Ghost motion: \(checks) checks passed")
    }
}
