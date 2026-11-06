import Foundation

/// `Jarvis --mcp`: a stdio MCP server that an AI agent launches (Claude Code, Claude Desktop, Google Antigravity,
/// Cursor, any MCP client). Each tool forwards to
/// the running Jarvis app's localhost bridge, so actions run inside Jarvis with the permissions it already has.
enum MCPServer {
    static let instructions = """
    Jarvis is the user's voice assistant on this Mac ("Hey Jarvis"). It sends the connected AI agent (you) what \
    the user asks out loud when they want an online answer or a multi-step task done.

    To serve Jarvis: call jarvis_wait_for_request in a loop. When a request arrives, handle it (look at the page \
    with jarvis_page, act in the browser or on the Mac with jarvis_command, use your own tools too), then call \
    jarvis_answer with its id and a short reply meant to be spoken: 1–3 plain sentences, no markdown, no lists. \
    Then wait again. If a request is unclear, answer with a short question instead of guessing.

    Request kinds: "ask" (answer it), "task" (do it), "draft" (write a reply to the conversation in \
    context.conversation; jarvis_answer with ONLY the reply text, no preamble: Jarvis pastes it, it doesn't send it). \
    The context has the front app, window, selection and browser tab; jarvis_context gets it fresh.

    Memory: context.memory_facts lists what the user asked Jarvis to remember, context.recent_history their last \
    requests. Use jarvis_memory to search older history; jarvis_remember to save a fact the user tells you.

    Full Control: when context.full_control is "on", the user has allowed you to operate the Mac directly with \
    jarvis_screenshot (then read the image file), jarvis_click, jarvis_type, jarvis_key, jarvis_applescript and \
    jarvis_shell. Otherwise those tools are refused. Even then: ask before sending, posting, buying, deleting or \
    changing settings, and never try to get around the safety blocklist.
    """

    static let tools: [[String: Any]] = [
        tool("jarvis_wait_for_request",
             "Wait for the next thing the user asked Jarvis to send to you (the AI agent). Returns {id, kind, text, context} "
                 + "(kind: ask = answer a question, task = do something), or a 'nothing yet' message after the wait. Call it in a loop.",
             ["wait_seconds": ["type": "integer", "description": "How long to wait, 1-55 (default 50)."]]),
        tool("jarvis_answer", "Answer a request: Jarvis shows it on screen and speaks it. Keep it short and spoken, no markdown.",
             ["id": ["type": "string"], "text": ["type": "string"]], required: ["id", "text"]),
        tool("jarvis_say", "Make Jarvis say something out loud now (progress updates, alerts).",
             ["text": ["type": "string"]], required: ["text"]),
        tool("jarvis_command",
             "Run one Jarvis command in plain English, as if spoken: browser (open/search/click/type/scroll/tabs/back) "
                 + "or Mac (open/quit apps, volume, music, dark mode, folders, time, battery). One action per call. Returns what happened.",
             ["text": ["type": "string", "description": "e.g. \"open github.com\", \"click Sign in\", \"type hello and press enter\""]],
             required: ["text"]),
        tool("jarvis_page", "The current browser tab: title, URL and visible text (text needs Chrome's 'Allow JavaScript from Apple Events').", [:]),
        tool("jarvis_context", "Fresh context: front app, window title, selected text, browser tab (and page text + clipboard in Full Control).", [:]),
        tool("jarvis_screenshot", "Full Control only. Screenshot of the main screen; returns the PNG path (read it) and the point/pixel scale.", [:]),
        tool("jarvis_click", "Full Control only. Click at screen coordinates in points (top-left origin).",
             ["x": ["type": "number"], "y": ["type": "number"], "double": ["type": "boolean"], "right": ["type": "boolean"]],
             required: ["x", "y"]),
        tool("jarvis_type", "Full Control only. Type text into whatever has keyboard focus.", ["text": ["type": "string"]], required: ["text"]),
        tool("jarvis_key", "Full Control only. Press a key or shortcut, e.g. \"return\", \"cmd+t\", \"cmd+shift+4\", \"down\".",
             ["keys": ["type": "string"]], required: ["keys"]),
        tool("jarvis_applescript", "Full Control only. Run AppleScript and return its result.", ["script": ["type": "string"]], required: ["script"]),
        tool("jarvis_shell", "Full Control only. Run a zsh command in the home folder (60 s limit) and return its output.",
             ["command": ["type": "string"]], required: ["command"]),
        tool("jarvis_remember", "Save a fact about the user to Jarvis's memory (e.g. “My sister's name is Riya”). Only facts the user told you.",
             ["fact": ["type": "string"]], required: ["fact"]),
        tool("jarvis_memory", "Search Jarvis's memory: facts the user asked it to remember and past requests. Empty query = everything recent.",
             ["query": ["type": "string"]]),
        tool("jarvis_status", "What Jarvis is doing: front app, browser, model, recent log lines, whether Claude is connected.", [:]),
    ]

    private static func tool(_ name: String, _ desc: String, _ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": desc,
         "inputSchema": ["type": "object", "properties": props, "required": required] as [String: Any]]
    }

    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine() {
            guard let msg = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = msg["method"] as? String else { continue }
            let id = msg["id"]
            guard id != nil else { continue } // notifications need no reply
            let params = msg["params"] as? [String: Any] ?? [:]
            switch method {
            case "initialize":
                send(id, result: [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "jarvis", "version": "1.0.0"],
                    "instructions": instructions,
                ])
            case "tools/list":
                send(id, result: ["tools": tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                let (text, isError) = call(name, args)
                send(id, result: ["content": [["type": "text", "text": text]], "isError": isError])
            case "ping":
                send(id, result: [:])
            case "resources/list":
                send(id, result: ["resources": []])
            case "resources/templates/list":
                send(id, result: ["resourceTemplates": []])
            case "prompts/list":
                send(id, result: ["prompts": []])
            default:
                send(id, error: ["code": -32601, "message": "Method not found: \(method)"])
            }
        }
        exit(0)
    }

    private static func call(_ name: String, _ args: [String: Any]) -> (String, Bool) {
        switch name {
        case "jarvis_wait_for_request":
            let wait = min(max(args["wait_seconds"] as? Int ?? 50, 1), 55)
            return http("GET", "/claude/next?wait=\(wait)", nil, timeout: Double(wait) + 10, empty: "Nothing yet. Call jarvis_wait_for_request again.")
        case "jarvis_answer":
            return http("POST", "/claude/answer", ["id": args["id"] ?? "", "text": args["text"] ?? ""])
        case "jarvis_say":
            return http("POST", "/say", ["text": args["text"] ?? ""])
        case "jarvis_command":
            return http("POST", "/command", ["text": args["text"] ?? ""], timeout: 60)
        case "jarvis_page":
            return http("GET", "/page", nil)
        case "jarvis_status":
            return http("GET", "/status", nil)
        case "jarvis_remember":
            return http("POST", "/memory/remember", ["fact": args["fact"] ?? ""])
        case "jarvis_memory":
            return http("POST", "/memory/search", ["query": args["query"] ?? ""])
        case "jarvis_context":
            return http("GET", "/context", nil)
        case "jarvis_screenshot":
            return http("POST", "/full/screenshot", [:], timeout: 30)
        case "jarvis_click":
            return http("POST", "/full/click", args)
        case "jarvis_type":
            return http("POST", "/full/type", args)
        case "jarvis_key":
            return http("POST", "/full/key", args)
        case "jarvis_applescript":
            return http("POST", "/full/applescript", args, timeout: 60)
        case "jarvis_shell":
            return http("POST", "/full/shell", args, timeout: 75)
        default:
            return ("Unknown tool \(name)", true)
        }
    }

    /// Calls the app's bridge synchronously. Returns the response body as text.
    private static func http(_ method: String, _ path: String, _ body: [String: Any]?, timeout: TimeInterval = 20,
                             empty: String = "OK") -> (String, Bool) {
        guard let data = try? Data(contentsOf: Bridge.configFile),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let base = cfg["url"], let token = cfg["token"], let url = URL(string: base + path)
        else { return ("Jarvis isn't set up yet: open /Applications/Jarvis.app once.", true) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        var result = ("", false)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, error in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            if error != nil {
                result = ("Jarvis isn't running. Open /Applications/Jarvis.app.", true)
            } else if status == 204 {
                result = (empty, false)
            } else {
                result = (text.isEmpty ? empty : text, status >= 400)
            }
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    private static func send(_ id: Any?, result: [String: Any]? = nil, error: [String: Any]? = nil) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull()]
        if let result { msg["result"] = result }
        if let error { msg["error"] = error }
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

/// Registers `Jarvis --mcp` in JSON MCP configs that use the common `{"mcpServers": {...}}` shape
/// (Google Antigravity, Cursor, Claude Desktop, Windsurf…).
enum AgentConfig {
    static let antigravityURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/antigravity/mcp_config.json")

    static var jarvisEntry: [String: Any] {
        ["command": Bundle.main.executablePath ?? "/Applications/Jarvis.app/Contents/MacOS/VoiceBrowser", "args": ["--mcp"]]
    }

    /// Adds or updates the "jarvis" server, leaving every other server as it was. Backs the file up first.
    @discardableResult
    static func addJarvis(to url: URL) throws -> String {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "AgentConfig", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(url.path) isn't a JSON object; not touching it"])
            }
            root = obj
            try? data.write(to: url.appendingPathExtension("bak"))
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        let existed = servers["jarvis"] != nil
        servers["jarvis"] = jarvisEntry
        root["mcpServers"] = servers
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        return existed ? "Updated the jarvis server in \(url.lastPathComponent)" : "Added the jarvis server to \(url.lastPathComponent)"
    }
}
