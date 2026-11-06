import AppKit
import CoreGraphics

/// Tools Claude gets only while the user has switched on Full Control: screenshot, keyboard, mouse,
/// AppleScript and shell. Every call is logged; a few catastrophic commands are always refused.
enum FullControl {
    /// Refused even in Full Control: powering off, wiping disks, privilege escalation, deleting home or root.
    static let blocked = try! NSRegularExpression(pattern: [
        #"\b(shutdown|reboot|halt|poweroff)\b"#,
        #"shut\s+down|restart\s+(the\s+)?(computer|mac)|\blog\s+out\b|empty\s+(the\s+)?trash"#,
        #"\bsudo\b|\bsu\s+-|\bdoas\b"#,
        #"\brm\s+(-[a-zA-Z]*\s+)*(/|~|\$HOME)/?(\s|$|\*)"#,
        #"\bmkfs\b|diskutil\s+(erase|partition|reformat|zero)|\bdd\s+if="#,
        #":\(\)\s*\{"#,
        #"\bcsrutil\b|\bspctl\s+--master-disable|\btccutil\b"#,
        #"security\s+(delete|dump|find-generic-password|find-internet-password)"#,
        #"launchctl\s+(unload|bootout|remove)"#,
    ].joined(separator: "|"), options: [.caseInsensitive])

    /// The reason a command is refused, or nil if allowed.
    static func refusal(_ command: String) -> String? {
        let range = NSRange(command.startIndex..., in: command)
        guard let m = blocked.firstMatch(in: command, range: range), let r = Range(m.range, in: command) else { return nil }
        return "Blocked by Jarvis safety rules (\(command[r].trimmingCharacters(in: .whitespaces))). Ask the user to do this themselves."
    }

    // MARK: Shell and AppleScript

    static func shell(_ command: String, timeout: TimeInterval = 60) async -> [String: String] {
        if let no = refusal(command) { return ["error": no] }
        return await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            p.standardInput = FileHandle.nullDevice
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            do { try p.run() } catch { return ["error": error.localizedDescription] }
            let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            timer.cancel()
            let text = String(decoding: data, as: UTF8.self)
            return ["exit_code": String(p.terminationStatus), "output": String(text.suffix(8000))]
        }.value
    }

    @MainActor
    static func applescript(_ source: String) -> [String: String] {
        if let no = refusal(source) { return ["error": no] }
        do { return ["result": try runAppleScript(source)] } catch { return ["error": error.localizedDescription] }
    }

    // MARK: Screen

    /// Saves a screenshot and returns its path (Claude Code can read the image file).
    static func screenshot() async -> [String: String] {
        let dir = Paths.support.appendingPathComponent("screens")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Keep only the latest few.
        if let old = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).sorted(by: { $0.path > $1.path }) {
            old.dropFirst(10).forEach { try? FileManager.default.removeItem(at: $0) }
        }
        let file = dir.appendingPathComponent("screen-\(Int(Date().timeIntervalSince1970)).png")
        let r = await shellUnchecked("/usr/sbin/screencapture", ["-x", "-t", "png", file.path])
        guard FileManager.default.fileExists(atPath: file.path) else {
            return ["error": "Screenshot failed (\(r)). Allow Jarvis in System Settings → Privacy & Security → Screen Recording."]
        }
        let size = await MainActor.run { NSScreen.main.map { ($0.frame.size, $0.backingScaleFactor) } }
        var out = ["path": file.path]
        if let (pts, scale) = size {
            out["screen_points"] = "\(Int(pts.width))x\(Int(pts.height))"
            out["note"] = "Image pixels are \(scale)x points: divide pixel coordinates by \(scale) for jarvis_click."
        }
        return out
    }

    private static func shellUnchecked(_ exe: String, _ args: [String]) async -> String {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let pipe = Pipe()
            p.standardError = pipe
            do { try p.run() } catch { return error.localizedDescription }
            p.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }.value
    }

    // MARK: Keyboard and mouse (need Accessibility permission)

    static var canControlInput: Bool { AXIsProcessTrusted() }

    /// Asks macOS for the permissions Full Control needs (shows the system prompts once).
    @MainActor
    static func requestPermissions() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
    }

    static func type(_ text: String) -> [String: String] {
        guard canControlInput else { return ["error": needAccessibility] }
        let src = CGEventSource(stateID: .hidSystemState)
        for chunk in text.chunked(20) {
            let utf16 = Array(chunk.utf16)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                e?.post(tap: .cghidEventTap)
            }
            usleep(8000)
        }
        return ["result": "Typed \(text.count) characters"]
    }

    /// "cmd+shift+t", "return", "escape", "cmd+v", "down", "f5"…
    static func key(_ combo: String) -> [String: String] {
        guard canControlInput else { return ["error": needAccessibility] }
        guard let (code, flags) = parseKey(combo) else { return ["error": "Unknown key: \(combo)"] }
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
        return ["result": "Pressed \(combo)"]
    }

    static func click(x: Double, y: Double, double: Bool = false, right: Bool = false) -> [String: String] {
        guard canControlInput else { return ["error": needAccessibility] }
        let p = CGPoint(x: x, y: y)
        let (downType, upType, button): (CGEventType, CGEventType, CGMouseButton) =
            right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        for n in 1...(double ? 2 : 1) {
            for t in [downType, upType] {
                let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: button)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                e?.post(tap: .cghidEventTap)
            }
        }
        return ["result": "\(right ? "Right-clicked" : double ? "Double-clicked" : "Clicked") at \(Int(x)),\(Int(y))"]
    }

    static let needAccessibility = "Jarvis needs Accessibility permission for keyboard and mouse: System Settings → Privacy & Security → Accessibility → Jarvis."

    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111,
    ]

    static func parseKey(_ combo: String) -> (CGKeyCode, CGEventFlags)? {
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for part in combo.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default:
                guard let k = keyCodes[part] else { return nil }
                key = k
            }
        }
        return key.map { ($0, flags) }
    }
}

extension String {
    func chunked(_ size: Int) -> [String] {
        stride(from: 0, to: count, by: size).map {
            let start = index(startIndex, offsetBy: $0)
            return String(self[start..<(index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex)])
        }
    }
}
