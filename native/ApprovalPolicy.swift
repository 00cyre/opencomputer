import Foundation

/// Which actions wait for the person's OK on screen, from OPENCOMPUTER_CONFIRM.
///
/// Entries are comma-separated: `sensitive` asks before presses that look like they send,
/// pay, post, or delete (and before Return/Enter, which usually submits); `all` or `*`
/// asks before every action; a bundle ID asks before every action in that app.
/// Unset, empty, or `off` asks for nothing. Pure logic, so it is tested without a desktop.
struct ApprovalPolicy {
    let everything: Bool
    let sensitive: Bool
    let apps: Set<String>

    init(_ raw: String?) {
        let items = (raw ?? "").split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }
        let keywords: Set<String> = ["all","*","sensitive","off","none"]
        everything = items.contains { ["all","*"].contains($0.lowercased()) }
        sensitive = items.contains { $0.lowercased() == "sensitive" }
        apps = Set(items.filter { !keywords.contains($0.lowercased()) })
    }

    var enabled: Bool { everything || sensitive || !apps.isEmpty }
    var summary: String {
        if everything { return "all" }
        return ((sensitive ? ["sensitive"] : []) + apps.sorted()).joined(separator:",")
    }

    /// Words that, as a whole word in a button's label, make a press consequential.
    static let words: Set<String> = [
        "send","pay","buy","purchase","checkout","order","post","publish","tweet","submit",
        "delete","remove","trash","erase","transfer","withdraw","donate","confirm","approve","agree","subscribe","unsubscribe",
    ]
    static let presses: Set<String> = ["AXPress","AXConfirm","AXPick","AXOpen"]

    /// Why this action needs approval, or nil when it can run without asking.
    func reason(method: String, bundle: String, label: String?, key: String? = nil, action: String? = nil) -> String? {
        if everything { return "You asked to approve every action" }
        if apps.contains(bundle) { return "You asked to approve every action in this app" }
        guard sensitive else { return nil }
        if method == "pressKey", let key, ApprovalPolicy.submits(key) { return "This key can send, submit, or delete" }
        let press = method == "click" || method == "clickPoint" || (method == "performAction" && ApprovalPolicy.presses.contains(action ?? ""))
        if press, let label, let word = ApprovalPolicy.consequentialWord(label) { return "“\(word.capitalized)” looks like it can’t be undone" }
        return nil
    }

    /// The first consequential whole word in a label, so "Sender" or "Postcard" do not count.
    static func consequentialWord(_ label: String) -> String? {
        label.lowercased().split { !$0.isLetter }.map(String.init).first { words.contains($0) }
    }

    /// Return and Enter usually submit; cmd+Delete usually deletes.
    static func submits(_ key: String) -> Bool {
        let parts = key.lowercased().split(separator:"+").map { $0.trimmingCharacters(in:.whitespaces) }
        guard let last = parts.last else { return false }
        if last == "return" || last == "enter" { return true }
        let modifiers = Set(parts.dropLast())
        return ["delete","backspace","forwarddelete"].contains(last) && !modifiers.isDisjoint(with:["cmd","command","meta"])
    }
}

struct ApprovalRequest {
    let key: String
    let title: String
    let detail: String
    let created: Date
    var decision: Bool? = nil
    var decided: Date? = nil
}

/// One question on screen at a time. An action that stops waiting before the person answers
/// returns APPROVAL_PENDING; retrying the same action picks up the answer exactly once.
struct ApprovalDesk {
    enum Outcome: Equatable { case approved, denied, waiting }
    private(set) var current: ApprovalRequest?
    var pending: ApprovalRequest? { current?.decision == nil ? current : nil }

    mutating func ask(key: String, title: String, detail: String, now: Date) -> Outcome {
        expire(now)
        if let request = current, request.key == key {
            guard let decision = request.decision else { return .waiting }
            current = nil
            return decision ? .approved : .denied
        }
        // A different action replaces an unanswered or unused question.
        current = ApprovalRequest(key:key,title:title,detail:detail,created:now)
        return .waiting
    }
    mutating func answer(_ allow: Bool, now: Date) {
        guard current != nil, current?.decision == nil else { return }
        current?.decision = allow
        current?.decided = now
    }
    /// Unanswered questions lapse after two minutes; answers nobody picked up lapse after one.
    mutating func expire(_ now: Date) {
        guard let request = current else { return }
        if let decided = request.decided { if now.timeIntervalSince(decided) > 60 { current = nil } }
        else if now.timeIntervalSince(request.created) > 120 { current = nil }
    }
    mutating func cancel() { current = nil }
}
