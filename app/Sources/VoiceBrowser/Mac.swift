import AppKit

/// Mac-wide commands: apps, volume, music, dark mode, lock screen, folders, time and battery.
/// Deliberately no shut down / restart / log out, so a mis-heard command can't power off the Mac.
@MainActor
final class MacDriver {
    static let actions: Set<String> = ["open_app", "quit_app", "volume", "media", "dark_mode", "lock_screen", "open_folder", "info"]

    func execute(_ a: Action) throws -> String {
        switch a.action {
        case "open_app":
            guard let name = a.app, let url = MacApps.url(for: name) else { return "I couldn't find an app called \(a.app ?? "that")" }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return "Opening \(url.deletingPathExtension().lastPathComponent)"
        case "quit_app":
            let want = (a.app ?? "").lowercased()
            let running = NSWorkspace.shared.runningApplications.first {
                guard let n = $0.localizedName?.lowercased() else { return false }
                return $0.activationPolicy == .regular && (n == want || n.hasSuffix(" " + want))
            }
            guard let app = running, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return "\(a.app ?? "That app") isn't running"
            }
            app.terminate() // a normal quit: the app can still ask to save
            return "Quitting \(app.localizedName ?? want)"
        case "volume":
            return try volume(a)
        case "media":
            return try media(a.direction ?? "toggle")
        case "dark_mode":
            let value = ["on": "true", "off": "false"][a.direction ?? ""] ?? "not dark mode"
            try runAppleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(value)")
            let on = try runAppleScript("tell application \"System Events\" to tell appearance preferences to get dark mode") == "true"
            return on ? "Dark mode on" : "Light mode on"
        case "lock_screen":
            try run("/usr/bin/pmset", ["displaysleepnow"])
            return ""
        case "open_folder":
            let name = (a.text ?? "home").lowercased()
            let fm = FileManager.default
            let url: URL = switch name {
            case let n where n.contains("download"): fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            case let n where n.contains("desktop"): fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            case let n where n.contains("document"): fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            case let n where n.contains("application"): URL(fileURLWithPath: "/Applications")
            default: fm.homeDirectoryForCurrentUser
            }
            NSWorkspace.shared.open(url)
            return "Opening \(url.lastPathComponent)"
        case "info":
            return try info(a.text ?? "time")
        default:
            return "I don't know how to \(a.action)"
        }
    }

    private func volume(_ a: Action) throws -> String {
        switch a.direction {
        case "mute":
            try runAppleScript("set volume with output muted")
            return "Muted"
        case "unmute":
            try runAppleScript("set volume without output muted")
            return "Sound on"
        default:
            let current = Int(try runAppleScript("output volume of (get volume settings)")) ?? 50
            let target = a.level ?? (a.direction == "down" ? current - 15 : current + 15)
            let v = min(max(target, 0), 100)
            try runAppleScript("set volume without output muted\nset volume output volume \(v)")
            return "Volume \(v) percent"
        }
    }

    private func media(_ command: String) throws -> String {
        let players = [("com.spotify.client", "Spotify"), ("com.apple.Music", "Music")]
        let running = players.first { p in NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == p.0 } }
        guard let player = running?.1 else { return "Music and Spotify aren't open" }
        let verb = ["play": "play", "pause": "pause", "next": "next track", "previous": "previous track"][command] ?? "playpause"
        try runAppleScript("tell application \"\(player)\" to \(verb)")
        return ["next": "Next track", "previous": "Previous track", "pause": "Paused", "play": "Playing"][command] ?? ""
    }

    private func info(_ what: String) throws -> String {
        let now = Date()
        if what.contains("battery") {
            let out = try run("/usr/bin/pmset", ["-g", "batt"])
            guard let r = out.range(of: #"\d+%"#, options: .regularExpression) else { return "No battery found" }
            let charging = out.contains("AC Power") ? ", plugged in" : ""
            return "Battery is at \(out[r])\(charging)"
        }
        if what.contains("date") || what.contains("day") {
            return "It's " + now.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        return "It's " + now.formatted(date: .omitted, time: .shortened)
    }

    @discardableResult
    private func run(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

@discardableResult
func runAppleScript(_ source: String) throws -> String {
    var err: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
    if let err {
        let code = err[NSAppleScript.errorNumber] as? Int ?? -1
        let msg = code == -1743
            ? "Allow Jarvis to control that app in System Settings → Privacy & Security → Automation."
            : err[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
        throw NSError(domain: "AppleScript", code: code, userInfo: [NSLocalizedDescriptionKey: msg])
    }
    return result?.stringValue ?? ""
}

/// Installed apps by lowercased name, for matching spoken names like "chrome" or "notes".
enum MacApps {
    static let all: [String: URL] = {
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var apps: [String: URL] = [:]
        for dir in dirs {
            for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where item.hasSuffix(".app") {
                apps[String(item.dropLast(4)).lowercased()] = URL(fileURLWithPath: dir).appendingPathComponent(item)
            }
        }
        apps["finder"] = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        return apps
    }()

    /// Exact name, or the last word(s) of a longer name ("chrome" -> "Google Chrome").
    static func url(for spoken: String) -> URL? {
        let s = spoken.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"^the |( app| application)$"#, with: "", options: .regularExpression)
        guard !s.isEmpty else { return nil }
        if let u = all[s] { return u }
        return all.filter { $0.key.hasSuffix(" " + s) }.min { $0.key.count < $1.key.count }?.value
    }
}

/// Instant, no-LLM handling of common Mac commands.
enum MacCommands {
    static func fast(_ u: String) -> Action? {
        func m(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let r = re.firstMatch(in: u, range: NSRange(u.startIndex..., in: u)) else { return nil }
            return (0..<r.numberOfRanges).map { Range(r.range(at: $0), in: u).map { String(u[$0]) } ?? "" }
        }
        if let g = m(#"^(?:set |change )?(?:the )?volume (?:to )?(\d{1,3})(?: percent|%)?$"#) {
            return Action(action: "volume", level: Int(g[1]))
        }
        if let g = m(#"^(?:turn )?(?:the )?(?:volume|sound) (up|down)$|^turn (?:it )?(up|down)$"#) {
            return Action(action: "volume", direction: g[1].isEmpty ? g[2] : g[1])
        }
        if m(#"^(?:louder|volume up)$"#) != nil { return Action(action: "volume", direction: "up") }
        if m(#"^(?:quieter|softer|volume down)$"#) != nil { return Action(action: "volume", direction: "down") }
        // Plain "mute" mutes Jarvis itself (see Meta); muting the Mac's sound needs an object.
        if let g = m(#"^(mute|unmute) (?:the )?(?:sound|volume|audio|mac|speakers)$"#) { return Action(action: "volume", direction: g[1]) }
        if let g = m(#"^(play|pause|resume|stop)(?: (?:the )?(?:music|song|spotify|playback))?$"#) {
            return Action(action: "media", direction: ["resume": "play", "stop": "pause"][g[1]] ?? g[1])
        }
        if m(#"^(?:next|skip)(?: (?:the )?(?:track|song))?$"#) != nil { return Action(action: "media", direction: "next") }
        if m(#"^previous(?: (?:track|song))?$"#) != nil { return Action(action: "media", direction: "previous") }
        if let g = m(#"^(?:turn |switch )?(on|off) dark mode$|^(?:turn )?dark mode (on|off)$"#) {
            return Action(action: "dark_mode", direction: g[1].isEmpty ? g[2] : g[1])
        }
        if let g = m(#"^(?:switch to |turn on |use )?(dark|light) mode$"#) {
            return Action(action: "dark_mode", direction: g[1] == "dark" ? "on" : "off")
        }
        if m(#"^lock(?: the| my)?(?: screen| mac| computer| laptop)?$"#) != nil { return Action(action: "lock_screen") }
        if let g = m(#"^(?:open |show )?(?:my |the )?(downloads|desktop|documents|home|applications)(?: folder)?$"#) {
            return Action(action: "open_folder", text: g[1])
        }
        if m(#"^what(?:'s| is) (?:the )?time|^what time is it"#) != nil { return Action(action: "info", text: "time") }
        if m(#"^what(?:'s| is) (?:the |today's )?date|^what day is it"#) != nil { return Action(action: "info", text: "date") }
        if m(#"battery"#) != nil { return Action(action: "info", text: "battery") }
        if let g = m(#"^(?:open|launch|start|switch to|go to) (.+)$"#), MacApps.url(for: g[1]) != nil {
            return Action(action: "open_app", app: g[1])
        }
        if let g = m(#"^(?:quit|close|exit|kill) (.+)$"#), MacApps.url(for: g[1]) != nil {
            return Action(action: "quit_app", app: g[1])
        }
        return nil
    }
}
