import Foundation
import Network

/// Localhost-only HTTP API inside the Jarvis app. `Jarvis --mcp` (the MCP server Claude runs) talks to it,
/// so Claude can take what the user asked, act through Jarvis with the app's permissions, and answer.
///
///   GET  /health                      no auth
///   GET  /claude/next?wait=25          long-poll: the next request for Claude, or 204
///   POST /claude/answer {id, text}     Jarvis shows and speaks the answer
///   POST /say {text}                   speak anything
///   POST /command {text}               run a Jarvis command (browser / Mac action)
///   POST /hear {text}                  run text through the whole pipeline as if spoken; returns the reply
///   GET  /status, GET /page            what Jarvis and the browser are doing
///   GET  /context                      front app, window, selection, tab (plus page text and clipboard in Full Control)
///   POST /memory/remember {fact}, POST /memory/search {query}
///   POST /full/{shell,applescript,screenshot,type,key,click}   Full Control only (the app refuses otherwise)
///
/// Every route but /health needs `Authorization: Bearer <token>` from ~/Library/Application Support/Jarvis/bridge.json.
@MainActor
final class Bridge {
    struct Request: Codable {
        let id: String
        /// "ask" (a question to answer) or "task" (something to do, e.g. multi-step in the browser).
        let kind: String
        let text: String
        let context: [String: String]
    }

    nonisolated static let defaultPort: UInt16 = 8777
    let port: UInt16
    private let fixedToken: String?

    /// `token` given: use it and don't touch the token file (tests).
    init(port: UInt16 = Bridge.defaultPort, token: String? = nil) {
        self.port = port
        self.fixedToken = token
    }
    nonisolated static let configFile = Paths.support.appendingPathComponent("bridge.json")

    var onSay: (String) -> Void = { _ in }
    var onCommand: (String) async -> [String: String] = { _ in [:] }
    var onHear: (String) async -> String = { _ in "" }
    var onStatus: () -> [String: String] = { [:] }
    var onPage: () async -> [String: String] = { [:] }
    var onContext: () -> [String: String] = { [:] }
    var onMemory: (String, [String: Any]) -> [String: String] = { _, _ in [:] }
    var onFull: (String, [String: Any]) async -> [String: String] = { _, _ in ["error": "Full Control is off"] }
    var onLog: (LogEntry.Kind, String) -> Void = { _, _ in }

    // Phone page (served only on the Tailscale address, with its own token; see Phone.swift).
    var onPhoneState: () -> [String: Any] = { [:] }
    var onPhoneSay: (String) async -> String = { _ in "" }
    var onPhoneScreen: () async -> (jpeg: Data?, error: String?) = { (nil, "unavailable") }
    var onPhoneControl: (String) -> String = { _ in "" }
    private var phoneListener: NWListener?
    private(set) var phoneHost: String?
    private(set) var phonePort: UInt16 = 0
    private var phoneToken = ""

    private(set) var token = ""
    private var listener: NWListener?
    private var queue: [Request] = []
    private var waiters: [(id: UUID, deliver: (Request?) -> Void)] = []
    private var pending: [String: CheckedContinuation<String?, Never>] = [:]
    private var lastPoll = Date.distantPast

    /// A Claude session is (or very recently was) waiting for requests over MCP.
    var claudeConnected: Bool { !waiters.isEmpty || Date().timeIntervalSince(lastPoll) < 10 }
    /// An agent is waiting for a request right now.
    var agentWaiting: Bool { !waiters.isEmpty }
    /// A request no agent picks up within this many seconds is given up (the caller answers offline).
    var pickupTimeout: TimeInterval = 10

    func start() {
        token = fixedToken ?? Self.loadOrCreateToken(port: port)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in
                MainActor.assumeIsolated { self?.accept(conn, phone: false) }
            }
            l.stateUpdateHandler = { [weak self] state in
                if case .failed(let e) = state {
                    MainActor.assumeIsolated { self?.onLog(.err, "Claude bridge: \(e.localizedDescription)") }
                }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            onLog(.err, "Claude bridge didn't start: \(error.localizedDescription)")
        }
    }

    /// Serves the phone page on `host:port` (the Mac's Tailscale address). Only /phone routes, only with `token`.
    func startPhone(host: String, port: UInt16, token: String) {
        stopPhone()
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in
                MainActor.assumeIsolated { self?.accept(conn, phone: true) }
            }
            l.start(queue: .main)
            phoneListener = l
            phoneHost = host
            phonePort = port
            phoneToken = token
        } catch {
            onLog(.err, "Phone link didn't start: \(error.localizedDescription)")
        }
    }

    func stopPhone() {
        phoneListener?.cancel()
        phoneListener = nil
        phoneHost = nil
    }

    func stop() {
        stopPhone()
        listener?.cancel()
        listener = nil
        waiters.forEach { $0.deliver(nil) }
        waiters.removeAll()
    }

    /// Hands a request to the connected Claude session and waits for its answer (nil on timeout).
    func ask(kind: String, text: String, context: [String: String], timeout: TimeInterval) async -> String? {
        let r = Request(id: String(UUID().uuidString.prefix(8)).lowercased(), kind: kind, text: text, context: context)
        return await withCheckedContinuation { cont in
            pending[r.id] = cont
            if waiters.isEmpty {
                queue.append(r)
                // Nobody came for it (the agent stopped): give up early instead of waiting the full timeout.
                DispatchQueue.main.asyncAfter(deadline: .now() + pickupTimeout) { [weak self] in
                    guard let self, self.queue.contains(where: { $0.id == r.id }), let c = self.pending.removeValue(forKey: r.id) else { return }
                    self.queue.removeAll { $0.id == r.id }
                    self.onLog(.err, "No agent picked up the request in \(Int(self.pickupTimeout)) s")
                    c.resume(returning: nil)
                }
            } else {
                waiters.removeFirst().deliver(r)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let c = self.pending.removeValue(forKey: r.id) else { return }
                self.queue.removeAll { $0.id == r.id }
                c.resume(returning: nil)
            }
        }
    }

    // MARK: - HTTP

    private func accept(_ conn: NWConnection, phone: Bool) {
        conn.start(queue: .main)
        receive(conn, buffer: Data(), phone: phone)
    }

    private func receive(_ conn: NWConnection, buffer: Data, phone: Bool) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buf = buffer
                if let data { buf.append(data) }
                if let req = HTTPRequest(buf) {
                    Task { phone ? await self.routePhone(req, conn) : await self.route(req, conn) }
                } else if done || error != nil || buf.count > 1_000_000 {
                    conn.cancel()
                } else {
                    self.receive(conn, buffer: buf, phone: phone)
                }
            }
        }
    }

    private func route(_ req: HTTPRequest, _ conn: NWConnection) async {
        if req.method == "GET", req.path == "/health" { return reply(conn, 200, ["ok": true]) }
        guard req.headers["authorization"] == "Bearer \(token)" else { return reply(conn, 401, ["error": "bad token"]) }
        let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
        switch (req.method, req.path) {
        case ("GET", "/claude/next"):
            lastPoll = Date()
            if !queue.isEmpty { return reply(conn, 200, encode(queue.removeFirst())) }
            let wait = min(max(Double(req.query["wait"] ?? "") ?? 25, 0), 55)
            let id = UUID()
            var answered = false
            let deliver: (Request?) -> Void = { [weak self] r in
                guard !answered else { return }
                answered = true
                self?.lastPoll = Date()
                if let r { self?.reply(conn, 200, self?.encode(r) ?? [:]) } else { self?.reply(conn, 204, [:]) }
            }
            waiters.append((id, deliver))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self, let i = self.waiters.firstIndex(where: { $0.id == id }) else { return }
                self.waiters.remove(at: i).deliver(nil)
            }
        case ("POST", "/claude/answer"):
            guard let id = body["id"] as? String, let text = body["text"] as? String else {
                return reply(conn, 400, ["error": "need id and text"])
            }
            guard let c = pending.removeValue(forKey: id) else {
                return reply(conn, 404, ["error": "no open request \(id) (it may have timed out)"])
            }
            c.resume(returning: text)
            reply(conn, 200, ["ok": true])
        case ("POST", "/say"):
            guard let text = body["text"] as? String, !text.isEmpty else { return reply(conn, 400, ["error": "need text"]) }
            onSay(text)
            reply(conn, 200, ["ok": true])
        case ("POST", "/command"):
            guard let text = body["text"] as? String, !text.isEmpty else { return reply(conn, 400, ["error": "need text"]) }
            reply(conn, 200, await onCommand(text))
        case ("POST", "/hear"):
            guard let text = body["text"] as? String, !text.isEmpty else { return reply(conn, 400, ["error": "need text"]) }
            reply(conn, 200, ["heard": text, "reply": await onHear(text)])
        case ("GET", "/status"):
            var s = onStatus()
            s["claude_connected"] = claudeConnected ? "yes" : "no"
            s["agent_connected"] = s["claude_connected"]
            s["agent_waiting"] = agentWaiting ? "yes" : "no"
            reply(conn, 200, s)
        case ("GET", "/page"):
            reply(conn, 200, await onPage())
        case ("GET", "/context"):
            reply(conn, 200, onContext())
        case ("POST", "/memory/remember"):
            reply(conn, 200, onMemory("remember", body))
        case ("POST", "/memory/search"):
            reply(conn, 200, onMemory("search", body))
        case ("POST", let path) where path.hasPrefix("/full/"):
            reply(conn, 200, await onFull(String(path.dropFirst(6)), body))
        default:
            reply(conn, 404, ["error": "unknown route \(req.method) \(req.path)"])
        }
    }

    private func encode(_ r: Request) -> [String: Any] {
        ["id": r.id, "kind": r.kind, "text": r.text, "context": r.context]
    }

    /// The phone side: the page and a few routes. Never the agent routes (/claude, /full, /command…).
    private func routePhone(_ req: HTTPRequest, _ conn: NWConnection) async {
        let given = req.query["t"] ?? req.headers["x-jarvis-phone"] ?? ""
        guard !phoneToken.isEmpty, given == phoneToken else {
            return send(conn, 401, Data("Not allowed. Scan the QR code in Jarvis → Connect Phone.".utf8), type: "text/plain; charset=utf-8")
        }
        let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
        switch (req.method, req.path) {
        case ("GET", "/phone"), ("GET", "/"):
            send(conn, 200, Data(PhonePage.html.utf8), type: "text/html; charset=utf-8")
        case ("GET", "/phone/state"):
            reply(conn, 200, onPhoneState())
        case ("POST", "/phone/say"):
            guard let text = body["text"] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                return reply(conn, 400, ["error": "need text"])
            }
            reply(conn, 200, ["reply": await onPhoneSay(text)])
        case ("POST", "/phone/screen"):
            let shot = await onPhoneScreen()
            if let jpeg = shot.jpeg { reply(conn, 200, ["jpeg": jpeg.base64EncodedString()]) } else { reply(conn, 200, ["error": shot.error ?? "failed"]) }
        case ("POST", "/phone/mute"), ("POST", "/phone/stop"):
            reply(conn, 200, ["reply": onPhoneControl(String(req.path.dropFirst(7)))])
        default:
            reply(conn, 404, ["error": "not available from the phone"])
        }
    }

    private func send(_ conn: NWConnection, _ status: Int, _ body: Data, type: String) {
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Unauthorized")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func reply(_ conn: NWConnection, _ status: Int, _ obj: [String: Any]) {
        let body = status == 204 ? Data() : ((try? JSONSerialization.data(withJSONObject: obj)) ?? Data())
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        if status == 204 { head = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n" }
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Token

    private static func loadOrCreateToken(port: UInt16) -> String {
        if let data = try? Data(contentsOf: configFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String], let t = obj["token"], !t.isEmpty {
            return t
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        let obj = ["url": "http://127.0.0.1:\(port)", "token": token]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) {
            FileManager.default.createFile(atPath: configFile.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
        return token
    }
}

/// Just enough HTTP/1.1 request parsing for the bridge. Returns nil until the whole request has arrived.
struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = head.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        let comps = URLComponents(string: String(first[1]))
        method = String(first[0])
        path = comps?.path ?? "/"
        query = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        self.headers = headers
        self.body = Data(body.prefix(length))
    }
}

/// Runs a request through the Claude Code CLI in the background (no open Claude session needed).
/// Uses the CLI that ships inside the Claude desktop app, or one installed on PATH. Needs `claude auth login` once.
enum ClaudeCLI {
    static var path: String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let base = "\(home)/Library/Application Support/Claude/claude-code"
        let bundled = ((try? fm.contentsOfDirectory(atPath: base)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .flatMap { v in ((try? fm.contentsOfDirectory(atPath: "\(base)/\(v)")) ?? []).map { "\(base)/\(v)/\($0)/claude.app/Contents/MacOS/claude" } }
        return (["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"] + bundled)
            .first { fm.isExecutableFile(atPath: $0) }
    }

    /// The prompt that turns a Claude session into Jarvis's online brain.
    static let servePrompt = "Serve Jarvis: call jarvis_wait_for_request in a loop; for each request, use the jarvis tools (and your own) " +
        "to answer or do it, then jarvis_answer with a short spoken reply (only the reply text for kind draft). Keep looping until I say stop."

    /// Registers `Jarvis --mcp` with Claude Code (user scope) unless it's already there.
    static func registerMCP() async throws -> String {
        guard let path else { throw err("Claude CLI not found. Install the Claude desktop app or Claude Code.") }
        let exe = Bundle.main.executablePath ?? "/Applications/Jarvis.app/Contents/MacOS/VoiceBrowser"
        if let out = try? await run(path, ["mcp", "get", "jarvis"], timeout: 30), out.contains(exe) {
            return "Already connected"
        }
        _ = try? await run(path, ["mcp", "remove", "--scope", "user", "jarvis"], timeout: 30)
        let out = try await run(path, ["mcp", "add", "--scope", "user", "jarvis", "--", exe, "--mcp"], timeout: 30)
        guard out.contains("Added") else { throw err("claude mcp add failed: \(out.suffix(200))") }
        return "Connected: Claude Code sessions now have the Jarvis tools"
    }

    private static var cachedLogin: (Date, Bool)?

    /// Signed in? Cached for two minutes so routing a request stays fast.
    static func signedIn() async -> Bool {
        if let (t, v) = cachedLogin, Date().timeIntervalSince(t) < 120 { return v }
        guard let path else { return false }
        let out = try? await run(path, ["auth", "status"], timeout: 15)
        let v = out?.contains("\"loggedIn\": true") == true
        cachedLogin = (Date(), v)
        return v
    }

    /// Asks Claude headless. Claude can use Jarvis's own tools (page, command, status) through `Jarvis --mcp`.
    static func ask(_ prompt: String, system: String, timeout: TimeInterval) async throws -> String {
        guard let path else { throw err("Claude CLI not found") }
        let mcp: [String: Any] = ["mcpServers": ["jarvis": ["command": Bundle.main.executablePath ?? "", "args": ["--mcp"]]]]
        let mcpJSON = String(decoding: try JSONSerialization.data(withJSONObject: mcp), as: UTF8.self)
        let out = try await run(path, [
            "-p", prompt,
            "--output-format", "json",
            "--append-system-prompt", system,
            "--strict-mcp-config", "--mcp-config", mcpJSON,
            "--allowedTools", "mcp__jarvis__jarvis_page", "mcp__jarvis__jarvis_command", "mcp__jarvis__jarvis_status",
            "WebSearch", "WebFetch",
            "--max-turns", "12",
        ], timeout: timeout)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else { throw err("Unreadable reply from Claude") }
        let result = obj["result"] as? String ?? ""
        if obj["is_error"] as? Bool == true { throw err(result.isEmpty ? "Claude returned an error" : result) }
        return result
    }

    private static func err(_ m: String) -> NSError { NSError(domain: "ClaudeCLI", code: 1, userInfo: [NSLocalizedDescriptionKey: m]) }

    private static func run(_ path: String, _ args: [String], timeout: TimeInterval) async throws -> String {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.currentDirectoryURL = Paths.support
            p.standardInput = FileHandle.nullDevice
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            let data = out.fileHandleForReading.readDataToEndOfFile() // until the process closes stdout
            p.waitUntilExit()
            timer.cancel()
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}
