import Foundation

/// One browser or Mac action, as chosen by the fast path or the local LLM.
struct Action: Codable, Equatable {
    var action: String
    var url: String?
    var query: String?
    var text: String?
    var direction: String?
    var index: Int?
    var submit: Bool?
    var app: String?
    var level: Int?
    /// Who answers an `ask`: "claude" (online), "local" (offline), or nil to follow the setting.
    var engine: String?

    var summary: String {
        switch action {
        case "open_url": return "Open \(URL(string: url ?? "")?.host ?? url ?? "")"
        case "new_tab": return url.map { "New tab: \(URL(string: $0)?.host ?? $0)" } ?? "New tab"
        case "search": return "Search: \(query ?? "")"
        case "click": return "Click “\(text ?? "")”"
        case "type": return "Type “\(text ?? "")”" + (submit == true ? " ⏎" : "")
        case "scroll": return "Scroll \(direction ?? "down")"
        case "switch_tab": return index == -1 ? "Last tab" : "Tab \(index ?? 1)"
        case "close_tab": return "Close tab"
        case "summarize": return "Summarize page"
        case "escalate": return "Hand off to Claude"
        case "draft_reply": return "Draft a reply" + ((text ?? "").isEmpty ? "" : ": \(text!)")
        case "type_text": return "Type “\(text ?? "")”" + (submit == true ? " ⏎" : "")
        case "remember": return "Remember: \(text ?? "")"
        case "recall": return "What I remember"
        case "forget": return text == "all" ? "Forget everything" : "Forget the last fact"
        case "screen": return "Look at the screen"
        case "ask": return engine == "local" ? "Ask (offline)" : engine == "claude" ? "Ask Claude" : "Ask"
        case "open_app": return "Open app \(app ?? "")"
        case "quit_app": return "Quit \(app ?? "")"
        case "volume": return level.map { "Volume \($0)%" } ?? "Volume \(direction ?? "")"
        case "media": return "Music: \(direction ?? "play/pause")"
        case "dark_mode": return "Dark mode \(direction ?? "toggle")"
        case "lock_screen": return "Lock screen"
        case "open_folder": return "Open \(text ?? "folder")"
        case "info": return "Check \(text ?? "time")"
        default: return action.capitalized
        }
    }
}

enum BrainError: LocalizedError {
    case ollamaDown, modelMissing(String), bad(String), unsupported(String), cpuBusy(Double)
    var errorDescription: String? {
        switch self {
        case .ollamaDown: return "Ollama isn't running. Open the Ollama app."
        case .modelMissing(let m): return "Model \(m) isn't installed. Run: ollama pull \(m)"
        case .bad(let s): return "Couldn't understand the model's reply: \(s.prefix(120))"
        case .unsupported(let s): return "I can't do that yet: “\(s)”"
        case .cpuBusy(let u): return "Your Mac is busy (CPU at \(Int(u))%), so I'm not starting the local model. Ask Claude, or try again in a moment."
        }
    }
}

enum Brain {
    static let host = ProcessInfo.processInfo.environment["OLLAMA_HOST"] ?? "http://127.0.0.1:11434"
    static let defaultModel = "gemma2:2b"

    static let actions = ["open_url", "search", "new_tab", "close_tab", "switch_tab", "back",
                          "forward", "reload", "scroll", "click", "type", "summarize", "escalate",
                          "ask", "draft_reply", "open_app", "quit_app", "volume", "media", "dark_mode", "lock_screen", "open_folder", "info"]

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": actions],
            "url": ["type": "string"],
            "query": ["type": "string"],
            "text": ["type": "string"],
            "direction": ["type": "string", "enum": ["up", "down", "top", "bottom", "mute", "unmute",
                                                     "play", "pause", "toggle", "next", "previous", "on", "off"]],
            "index": ["type": "integer"],
            "submit": ["type": "boolean"],
            "app": ["type": "string"],
            "level": ["type": "integer"],
        ],
        "required": ["action"],
    ]

    static let system = """
    You turn a spoken command for a web browser or a Mac into ONE JSON action. Speech-to-text may contain errors; infer intent.
    Actions:
    - open_url {url}: go to a site in the current tab. Expand names to full URLs ("youtube" -> https://www.youtube.com).
    - new_tab {url?}: open a new tab, optionally at url.
    - search {query}: web search.
    - close_tab, back, forward, reload: no args.
    - switch_tab {index}: 1-based tab number; use -1 for last tab.
    - scroll {direction}: up/down/top/bottom.
    - click {text}: click the link/button whose visible label best matches text.
    - type {text, submit}: type text into the focused/first input; submit=true if the user says search/enter/submit/go.
    - summarize: user wants the current page read, summarized or explained.
    - open_app {app} / quit_app {app}: open or quit a Mac application by name (Slack, Notes, Spotify, Calculator...).
    - volume {direction: up/down/mute/unmute} or {level: 0-100}.
    - media {direction: play/pause/toggle/next/previous}: control music.
    - dark_mode {direction: on/off/toggle}.
    - lock_screen. open_folder {text: downloads/desktop/documents/home}. info {text: time/date/battery}.
    - ask {text}: a question or chat that needs an answer in words (facts, explanations, advice, opinions), not a browser or Mac action.
    - draft_reply {text}: write a reply / response / email / message to what's on screen; text = what the reply should say, if the user said.
    - escalate {text}: multi-step or open-ended tasks (compare, book, fill a whole form, research, "find me the cheapest..."). Put the full task in text.
    Examples:
    "open hacker news" -> {"action":"open_url","url":"https://news.ycombinator.com"}
    "search for best mechanical keyboards" -> {"action":"search","query":"best mechanical keyboards"}
    "click on sign in" -> {"action":"click","text":"sign in"}
    "go to the third tab" -> {"action":"switch_tab","index":3}
    "type hello world and press enter" -> {"action":"type","text":"hello world","submit":true}
    "what is this page about" -> {"action":"summarize"}
    "open slack" -> {"action":"open_app","app":"Slack"}
    "what is the capital of australia" -> {"action":"ask","text":"what is the capital of australia"}
    "explain how vaccines work" -> {"action":"ask","text":"explain how vaccines work"}
    "make it a bit louder" -> {"action":"volume","direction":"up"}
    "play some music" -> {"action":"media","direction":"play"}
    "find a cheap flight to goa next friday and compare airlines" -> {"action":"escalate","text":"find a cheap flight to goa next friday and compare airlines"}
    """

    /// Instant, no-LLM handling for the most common phrases.
    static let fastPath: [(String, Action)] = [
        ("^(scroll )?down$|^scroll down", Action(action: "scroll", direction: "down")),
        ("^(scroll )?up$|^scroll up", Action(action: "scroll", direction: "up")),
        ("^(go )?back$", Action(action: "back")),
        ("^(go )?forward$", Action(action: "forward")),
        ("^(reload|refresh)( (the )?page)?$", Action(action: "reload")),
        ("^close( this)?( tab)?$", Action(action: "close_tab")),
        ("^new tab$", Action(action: "new_tab")),
        ("^(go to |scroll to )?(the )?top$", Action(action: "scroll", direction: "top")),
        ("^(go to |scroll to )?(the )?bottom$", Action(action: "scroll", direction: "bottom")),
    ]

    static let ordinals = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
                           "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "one": 1, "two": 2, "three": 3,
                           "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "last": -1]
    static let tabRegex = try! NSRegularExpression(
        pattern: #"^(?:go to |switch to |open )?(?:the )?(?:tab (?:number )?(\w+)|(?:(\d+)(?:st|nd|rd|th)?|(\w+)) tab)$"#)
    static let domainRegex = try! NSRegularExpression(
        pattern: #"^(?:open |go to |visit )?((?:[a-z0-9-]+\.)+[a-z]{2,})(/\S*)?$"#)

    /// Returns the action and whether the LLM was needed (false = instant rule).
    /// `history`: recent commands, oldest first ("heard → what happened"), so the model can resolve "it", "that", "again".
    static func parse(_ utterance: String, model: String, history: [String] = []) async throws -> (action: Action, viaModel: Bool) {
        // Speech engines spell out web addresses: "amazon dot in" -> "amazon.in".
        let utterance = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+dot\s+"#, with: ".", options: [.regularExpression, .caseInsensitive])
        var u = utterance.lowercased()
        u = u.replacingOccurrences(of: "[.!?]+$", with: "", options: .regularExpression)
        u = u.replacingOccurrences(of: "^(please |hey browser,? |browser,? )", with: "", options: .regularExpression)
        if let hit = fastPath.first(where: { u.range(of: $0.0, options: .regularExpression) != nil }) {
            return (hit.1, false)
        }
        let range = NSRange(u.startIndex..., in: u)
        let group = { (m: NSTextCheckingResult, i: Int) in Range(m.range(at: i), in: u).map { String(u[$0]) } }
        if let m = tabRegex.firstMatch(in: u, range: range),
           let word = group(m, 1) ?? group(m, 2) ?? group(m, 3),
           let n = Int(word) ?? ordinals[word] {
            return (Action(action: "switch_tab", index: n), false)
        }
        if let m = domainRegex.firstMatch(in: u, range: range), let host = group(m, 1) {
            return (Action(action: "open_url", url: "https://" + host + (group(m, 2) ?? "")), false)
        }
        if let a = MacCommands.fast(u) { return (a, false) }
        if let a = askRule(u, original: utterance) { return (a, false) }
        if CPUGuard.busy {
            throw BrainError.cpuBusy(CPUGuard.usage)
        }
        let recent = history.isEmpty ? "" : "Recent commands, oldest first:\n" + history.map { "- \($0)" }.joined(separator: "\n") + "\n\nNow: "
        let out = try await chat([["role": "system", "content": system], ["role": "user", "content": recent + utterance]],
                                 model: model, schema: schema)
        guard var a = try? JSONDecoder().decode(Action.self, from: Data(out.utf8)) else { throw BrainError.bad(out) }
        // Small models drop optional fields; don't rely on them for "press enter".
        if a.action == "type", u.range(of: #"\b(press enter|hit enter|press return|and search|and submit|and go)$"#, options: .regularExpression) != nil {
            a.submit = true
        }
        // Small models pick the nearest action even when it's wrong; catch the risky mix-ups.
        if a.action == "open_app", u.range(of: #"^(quit|close|exit|kill)\b"#, options: .regularExpression) != nil {
            a.action = "quit_app"
        }
        if a.action == "volume", u.range(of: #"volume|sound|loud|quiet|soft|mute|audio|hear"#, options: .regularExpression) == nil {
            throw BrainError.unsupported(utterance)
        }
        return (a, true)
    }

    /// "Claude, …" / "ask Claude …" go online; "ask locally …" stays offline; page questions summarize;
    /// plain questions ("what…", "why…", "explain…") are answered rather than parsed as actions.
    static func askRule(_ u: String, original: String) -> Action? {
        func rest(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: u, range: NSRange(u.startIndex..., in: u)),
                  let r = Range(m.range(at: 1), in: u) else { return nil }
            return String(u[r]).trimmingCharacters(in: .whitespaces)
        }
        /// The same words as `s` (found in the lowercased text) with the user's original capitalisation.
        func cased(_ s: String) -> String {
            let o = original as NSString
            let r = (original.lowercased() as NSString).range(of: s)
            return r.location == NSNotFound || NSMaxRange(r) > o.length ? s : o.substring(with: r)
        }
        if let q = rest(#"^(?:ask |hey |ok )?claude[ ,:]+(?:to )?(.+)$"#) { return Action(action: "ask", text: q, engine: "claude") }
        if let q = rest(#"^ask (?:locally|offline|gemma|ollama)[ ,:]+(.+)$"#) { return Action(action: "ask", text: q, engine: "local") }
        if let fact = rest(#"^(?:please )?(?:remember|note|keep in mind)(?: that)?[ ,:]+(.+)$"#) {
            return Action(action: "remember", text: cased(fact))
        }
        if u.range(of: #"^(what do you (know|remember)( about me)?|what have you remembered|(list|show)( my)? memor(y|ies))$"#,
                   options: .regularExpression) != nil {
            return Action(action: "recall")
        }
        if u.range(of: #"^forget (everything|all( of it)?|all memories|my memories)$"#, options: .regularExpression) != nil {
            return Action(action: "forget", text: "all")
        }
        if u.range(of: #"^forget (that|the last (one|thing|fact))$"#, options: .regularExpression) != nil {
            return Action(action: "forget", text: "last")
        }
        if u.range(of: #"^(look at|check|read|scan|see) (my |the )?screen\b|\b(on|at) (my|the) screen\b|^what('s| is) on (my |the )?screen"#,
                   options: .regularExpression) != nil {
            return Action(action: "screen", text: original)
        }
        if u.range(of: #"^(?:please )?(?:draft|write|compose|prepare)(?: me)?(?: a| an)?(?: quick| short| polite| formal| friendly)? (?:reply|response|answer|email|message)\b"#,
                   options: .regularExpression) != nil {
            let how = rest(#"^.*?(?:reply|response|answer|email|message)(?: to (?:this|that|it|him|her|them))?(?:[ ,:]+(?:saying|that says|to say|that|telling (?:him|her|them)))?[ ,:]*(.*)$"#) ?? ""
            return Action(action: "draft_reply", text: how)
        }
        // "type …", "reply …", "dictate …": put the words at the cursor in the front app (after the draft rule above).
        if let words = rest(#"^(?:please )?(?:type|dictate|insert|enter|reply|write|put)(?: (?:in|this|that|the following|out|it))?[ ,:]+(.+)$"#) {
            let submit = words.range(of: #"[ ,]+(?:and )?(?:press enter|hit enter|press return|send it|submit)$"#, options: .regularExpression)
            let body = submit.map { String(words[..<$0.lowerBound]) } ?? words
            return Action(action: "type_text", text: cased(body), submit: submit != nil)
        }
        if u.range(of: #"^(what('s| is) (this|the) (web ?)?page about|summari[sz]e (this|the) (web ?)?page|read (this|the) page( to me)?)$"#,
                   options: .regularExpression) != nil {
            return Action(action: "summarize")
        }
        let question = #"^(what|who|whom|whose|why|how|when|where|which|explain|tell me|define|describe|is|are|does|do|can|could|should|would)\b"#
        let acting = #"\b(open|search|google|click|scroll|type|play|pause|go to|close|quit|launch|volume|mute|tab|lock|dark mode)\b"#
        if u.range(of: question, options: .regularExpression) != nil, u.range(of: acting, options: .regularExpression) == nil {
            return Action(action: "ask", text: original)
        }
        return nil
    }

    static func chat(_ messages: [[String: String]], model: String, schema: [String: Any]? = nil) async throws -> String {
        if CPUGuard.busy { throw BrainError.cpuBusy(CPUGuard.usage) }
        var body: [String: Any] = ["model": model, "messages": messages, "stream": false,
                                   "keep_alive": "30m", "options": ["temperature": 0]]
        if let schema { body["format"] = schema }
        let (data, status) = try await post("/api/chat", body)
        if status == 404 { throw BrainError.modelMissing(model) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = obj["message"] as? [String: Any], let content = msg["content"] as? String
        else { throw BrainError.bad(String(decoding: data, as: UTF8.self)) }
        return content
    }

    /// Loads the model into memory so the first spoken command is fast.
    static func warmUp(model: String) async {
        _ = try? await post("/api/generate", ["model": model, "keep_alive": "30m"])
    }

    static func installedModels() async -> [String] {
        guard let url = URL(string: "\(host)/api/tags"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }.sorted()
    }

    private static func post(_ path: String, _ body: [String: Any]) async throws -> (Data, Int) {
        var req = URLRequest(url: URL(string: host + path)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw BrainError.ollamaDown
        }
    }
}


/// Commands about Jarvis itself, handled before parsing.
enum Meta: Equatable {
    case startSession, endSession, fullControlOn, fullControlOff, mute, stop

    static func detect(_ command: String, inSession: Bool) -> Meta? {
        let m = command.lowercased()
            .replacingOccurrences(of: "[.!?,]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        func has(_ p: String) -> Bool { m.range(of: p, options: .regularExpression) != nil }
        if has(#"^(mute|mute (yourself|jarvis)|jarvis mute|go quiet|be quiet|quiet|shut up|stop listening|go to sleep|sleep)$"#) {
            return .mute
        }
        if has(#"^(stop|cancel|never ?mind|stop (it|that|talking|speaking|everything)|abort)$"#) { return .stop }
        if has(#"^(give|grant|enable|turn on)( claude)? (full|complete|total) control( to claude)?$|^(full control( on)?|claude take (over|full control|control))$"#) {
            return .fullControlOn
        }
        if has(#"^(take back|revoke|disable|end|stop|turn off|cancel) (claude'?s? )?(full )?control$|^(take control back|full control off|i'?ll take it from here)$"#) {
            return .fullControlOff
        }
        if has(#"^(start|begin|open)( a)? (session|conversation)$|^(session mode|stay awake|keep listening)$"#) { return .startSession }
        if inSession, has(#"^(end|stop|close)( the)? (session|conversation)$|^(that's all|that is all|goodbye|thanks jarvis|thank you jarvis)$"#) {
            return .endSession
        }
        return nil
    }
}
