import Foundation

@main
struct ApprovalTests {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition,message); checks += 1 }

        let off = ApprovalPolicy(nil)
        check(!off.enabled && off.reason(method:"click",bundle:"com.apple.mail",label:"Send") == nil,"Unset asks for nothing")
        check(!ApprovalPolicy("off").enabled && !ApprovalPolicy(" , ").enabled,"off and empty entries ask for nothing")

        let sensitive = ApprovalPolicy("sensitive")
        check(sensitive.reason(method:"click",bundle:"com.apple.mail",label:"Send") != nil,"Send needs approval")
        check(sensitive.reason(method:"clickPoint",bundle:"x",label:"Place order") != nil,"Place order needs approval")
        check(sensitive.reason(method:"performAction",bundle:"x",label:"Delete…",action:"AXPress") != nil,"Pressing Delete… needs approval")
        check(sensitive.reason(method:"performAction",bundle:"x",label:"Delete",action:"AXIncrement") == nil,"Non-press actions never match labels")
        check(sensitive.reason(method:"click",bundle:"x",label:"Sender") == nil,"Whole words only: Sender")
        check(sensitive.reason(method:"click",bundle:"x",label:"Postcard settings") == nil,"Whole words only: Postcard")
        check(sensitive.reason(method:"click",bundle:"x",label:"Open") == nil,"Ordinary buttons run")
        check(sensitive.reason(method:"setValue",bundle:"x",label:"Send") == nil,"Editing a field labelled Send runs")
        check(sensitive.reason(method:"pressKey",bundle:"x",label:nil,key:"Return") != nil,"Return needs approval")
        check(sensitive.reason(method:"pressKey",bundle:"x",label:nil,key:"cmd+Enter") != nil,"cmd+Enter needs approval")
        check(sensitive.reason(method:"pressKey",bundle:"x",label:nil,key:"cmd+Delete") != nil,"cmd+Delete needs approval")
        check(sensitive.reason(method:"pressKey",bundle:"x",label:nil,key:"Delete") == nil,"Plain Delete edits text and runs")
        check(sensitive.reason(method:"pressKey",bundle:"x",label:nil,key:"Tab") == nil,"Tab runs")

        let mail = ApprovalPolicy("com.apple.mail, sensitive")
        check(mail.reason(method:"setValue",bundle:"com.apple.mail",label:"Subject") != nil,"Listed apps ask before every action")
        check(mail.reason(method:"setValue",bundle:"com.apple.TextEdit",label:"Body") == nil,"Other apps follow the sensitive rule only")
        check(mail.summary == "sensitive,com.apple.mail","Summary lists keywords then apps")
        check(ApprovalPolicy("*").reason(method:"scroll",bundle:"x",label:nil) != nil && ApprovalPolicy("ALL").everything,"all and * ask before everything")

        let t0 = Date(timeIntervalSinceReferenceDate:0)
        var desk = ApprovalDesk()
        check(desk.ask(key:"a",title:"Send",detail:"",now:t0) == .waiting && desk.pending?.key == "a","First ask shows a question")
        check(desk.ask(key:"a",title:"Send",detail:"",now:t0.addingTimeInterval(1)) == .waiting,"Asking again keeps waiting")
        desk.answer(true,now:t0.addingTimeInterval(2))
        check(desk.pending == nil,"An answered question leaves the screen")
        check(desk.ask(key:"a",title:"Send",detail:"",now:t0.addingTimeInterval(3)) == .approved,"The retry picks up the approval")
        check(desk.ask(key:"a",title:"Send",detail:"",now:t0.addingTimeInterval(4)) == .waiting,"An approval is used once")
        desk.answer(false,now:t0.addingTimeInterval(5))
        desk.answer(true,now:t0.addingTimeInterval(6))
        check(desk.ask(key:"a",title:"Send",detail:"",now:t0.addingTimeInterval(7)) == .denied,"The first answer stands")
        _ = desk.ask(key:"b",title:"Pay",detail:"",now:t0.addingTimeInterval(8))
        desk.answer(true,now:t0.addingTimeInterval(9))
        check(desk.ask(key:"c",title:"Post",detail:"",now:t0.addingTimeInterval(10)) == .waiting && desk.pending?.key == "c","Another action never inherits an approval")
        check(desk.ask(key:"b",title:"Pay",detail:"",now:t0.addingTimeInterval(11)) == .waiting,"The replaced approval is gone")
        check(desk.ask(key:"b",title:"Pay",detail:"",now:t0.addingTimeInterval(200)) == .waiting && desk.pending?.created == t0.addingTimeInterval(200),"Unanswered questions lapse after two minutes")
        desk.answer(true,now:t0.addingTimeInterval(201))
        check(desk.ask(key:"b",title:"Pay",detail:"",now:t0.addingTimeInterval(300)) == .waiting,"Unused approvals lapse after a minute")
        desk.cancel()
        check(desk.current == nil,"Cancel clears the question")
        print("Approval policy: \(checks) checks passed")
    }
}
