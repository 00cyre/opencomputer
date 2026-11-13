import Foundation
import CryptoKit

// One JSON line per request that touches an app, in one file per helper process (one
// MCP or JavaScript connection), so what a session did can be reconstructed afterwards.
// Typed text and set values are never written, only their length. Page addresses lose
// their query and fragment. Files are private to the user and pruned after 30 days.
// Each line carries "prev", the start of the SHA-256 of the line before it ("" on the
// first), so `opencomputer log --verify` notices a line changed or removed inside a file.
@MainActor
final class ActionLog {
    static let methods: Set<String> = ["configure","release","open","observe","screenshot","readText","click","clickPoint","setValue","performAction","pressKey","typeText","scroll"]
    private var handle: FileHandle?
    private var previous = ""
    private(set) var path: String?
    private static let clock: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; return f }()
    init(_ env: [String:String]) {
        guard env["OPENCOMPUTER_LOG"] != "0" else { return }
        let dir = URL(fileURLWithPath:env["OPENCOMPUTER_LOG_DIR"] ?? NSHomeDirectory() + "/Library/Logs/OpenComputer",isDirectory:true)
        let files = FileManager.default
        try? files.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let cutoff = Date().addingTimeInterval(-30*86400)
        for name in (try? files.contentsOfDirectory(atPath:dir.path)) ?? [] where name.hasPrefix("session-") && name.hasSuffix(".jsonl") {
            let file = dir.appendingPathComponent(name).path
            if let modified = (try? files.attributesOfItem(atPath:file))?[.modificationDate] as? Date, modified < cutoff { try? files.removeItem(atPath:file) }
        }
        let stamp = ActionLog.clock.string(from:Date()).prefix(19).replacingOccurrences(of:":",with:"")
        let file = dir.appendingPathComponent("session-\(stamp)Z-\(getpid()).jsonl").path
        guard files.createFile(atPath:file,contents:nil,attributes:[.posixPermissions:0o600]), let handle = FileHandle(forWritingAtPath:file) else {
            FileHandle.standardError.write("OpenComputer: cannot write the action log in \(dir.path)\n".data(using:.utf8)!)
            return
        }
        self.handle = handle
        path = file
    }
    func write(_ entry: [String:Any]) {
        guard let handle, let body = try? JSONSerialization.data(withJSONObject:entry,options:[.sortedKeys]), body.count > 1 else { return }
        var line = Data("{\"time\":\"\(ActionLog.clock.string(from:Date()))\",\"prev\":\"\(previous)\"".utf8)
        if body.count > 2 { line.append(Data(",".utf8)) }
        line.append(body.dropFirst())
        let digest = SHA256.hash(data:line).prefix(16).map { String(format:"%02x",$0) }.joined()
        line.append(0x0a)
        do { try handle.write(contentsOf:line); previous = digest } catch {}
    }
}

// What one request did, filled in as it is resolved and dispatched.
final class Note {
    var fields: [String:Any]
    let started = Date()
    static let copied = ["app","pid","snapshot","element","root","menu","limit","windowId","x","y","action","keys","count","direction","pages","waitMs","intrusive","refresh","marks","ocr","region","offset","length","maxEdge"]
    static let kept = ["dispatched","delivery","confirmed","elementFocused","focusChanged","focusRestored","frontmostBefore","frontmostAfter","opened","snapshot","truncated","windowId","selectionRequired","released","agent","target","pressed","refreshed","zoomed","marked","totalLength","source","summary"]
    init(_ method: String, _ request: [String:Any]) {
        fields = ["event":method]
        for key in Note.copied { if let value = request[key] { fields[key] = value } }
        if let window = request["window"] { fields["windowIndex"] = window }
        if let text = request["text"] as? String { fields["textLength"] = text.count }
        if let value = request["value"] as? String { fields["valueLength"] = value.count }
        if let key = request["key"] as? String { fields["key"] = Note.safeKey(key) }
        if let url = request["url"] as? String { fields["url"] = redactURL(url) ?? "[invalid]" }
        if let agent = request["agent"] as? String { fields["agent"] = cleanLabel(agent,limit:100) }
    }
    // A bare character could be one letter of something typed; names and shortcuts are kept.
    static func safeKey(_ key: String) -> String {
        let parts = key.split(separator:"+")
        return parts.count == 1 && key.count == 1 ? "[character]" : cleanLabel(key,limit:40)
    }
    func merge(_ values: [String:Any]) { fields.merge(values) { _, new in new } }
    func finish(_ result: [String:Any]) -> [String:Any] {
        for key in Note.kept { if let value = result[key] { fields[key] = value } }
        if let nodes = result["nodes"] as? [Any] { fields["nodeCount"] = nodes.count }
        // Recognized and read text stay out of the log; only how much there was.
        if let lines = result["lines"] as? [Any] { fields["ocrLines"] = lines.count }
        if let text = result["text"] as? String { fields["textLength"] = (text as NSString).length }
        if let windows = result["windows"] as? [[String:Any]], fields["event"] as? String == "observe" {
            fields["windows"] = windows.map { cleanLabel($0["title"] as? String ?? "",limit:120) }
        }
        fields["outcome"] = result["dispatched"] as? Bool == true ? "dispatched" : "ok"
        fields["elapsedMs"] = Int(Date().timeIntervalSince(started)*1000)
        return fields
    }
    func failed(_ code: String, _ message: String, _ details: [String:Any]?) -> [String:Any] {
        var error: [String:Any] = ["code":code,"message":String(message.prefix(400))]
        if let details { error["details"] = details.filter { ["reason","was","now","tab","dispatched","waitedMs","retryAfterMs","role","label"].contains($0.key) } }
        fields["error"] = error
        fields["outcome"] = fields["dispatchAttempted"] as? Bool == true ? "failed" : "refused"
        if fields["dispatchAttempted"] == nil { fields["dispatched"] = false }
        fields["elapsedMs"] = Int(Date().timeIntervalSince(started)*1000)
        return fields
    }
}
