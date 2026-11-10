import AppKit

struct KeyStroke { let code: CGKeyCode; let flags: CGEventFlags }

// Key events are posted to one process, never to the session, so they cannot reach
// the app the person is using. They carry their own modifier state for the same reason.
enum Keys {
    static let codes: [String: CGKeyCode] = [
        "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,
        "1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,"0":29,"]":30,"o":31,"u":32,"[":33,
        "i":34,"p":35,"l":37,"j":38,"'":39,"k":40,";":41,"\\":42,",":43,"/":44,"n":45,"m":46,".":47,"`":50,
        "return":36,"enter":36,"tab":48,"space":49,"delete":51,"backspace":51,"escape":53,"esc":53,
        "forwarddelete":117,"home":115,"end":119,"pageup":116,"pagedown":121,
        "left":123,"right":124,"down":125,"up":126,
        "f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,"f7":98,"f8":100,"f9":101,"f10":109,"f11":103,"f12":111,
        "plus":24,"minus":27,
    ]
    static let modifiers: [String: CGEventFlags] = [
        "cmd":.maskCommand,"command":.maskCommand,"meta":.maskCommand,"ctrl":.maskControl,"control":.maskControl,
        "alt":.maskAlternate,"option":.maskAlternate,"opt":.maskAlternate,"shift":.maskShift,"fn":.maskSecondaryFn,
    ]
    static func parse(_ spec: String) throws -> KeyStroke {
        let parts = spec.lowercased().split(separator:"+").map { $0.trimmingCharacters(in:.whitespaces) }
        guard let name = parts.last, let code = codes[name] else {
            try fail("INVALID_ARGUMENT","Unknown key \"\(spec)\". Use names like Return, Tab, Escape, Space, Delete, Up, PageDown, F5, or a character, with optional cmd/ctrl/alt/shift modifiers joined by +, e.g. cmd+shift+t.")
        }
        var flags: CGEventFlags = []
        for part in parts.dropLast() {
            guard let flag = modifiers[part] else { try fail("INVALID_ARGUMENT","Unknown modifier \"\(part)\". Use cmd, ctrl, alt, shift, or fn.") }
            flags.insert(flag)
        }
        if (123...126).contains(code) { flags.insert([.maskNumericPad,.maskSecondaryFn]) }
        else if [115,116,117,119,121].contains(code) || name.hasPrefix("f") && name.count > 1 { flags.insert(.maskSecondaryFn) }
        return KeyStroke(code:code,flags:flags)
    }
    static func post(_ stroke: KeyStroke, to pid: pid_t, count: Int = 1) {
        let source = CGEventSource(stateID:.privateState)
        for _ in 0..<count {
            for down in [true,false] {
                guard let event = CGEvent(keyboardEventSource:source,virtualKey:stroke.code,keyDown:down) else { continue }
                event.flags = stroke.flags
                event.postToPid(pid)
                usleep(1500)
            }
        }
    }
    static func type(_ text: String, to pid: pid_t) {
        let source = CGEventSource(stateID:.privateState)
        for character in text {
            if character.isNewline { post(KeyStroke(code:36,flags:[]),to:pid); continue }
            if character == "\t" { post(KeyStroke(code:48,flags:[]),to:pid); continue }
            let units = Array(String(character).utf16)
            for down in [true,false] {
                guard let event = CGEvent(keyboardEventSource:source,virtualKey:0,keyDown:down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength:units.count,unicodeString:units)
                event.postToPid(pid)
            }
            usleep(700)
        }
    }
}
