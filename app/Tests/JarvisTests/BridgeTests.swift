import XCTest
@testable import VoiceBrowser

final class HTTPRequestTests: XCTestCase {
    func testWaitsForWholeRequest() {
        XCTAssertNil(HTTPRequest(Data("GET /x HTTP/1.1\r\nHost: a".utf8)), "headers not finished")
        let partial = "POST /say HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\":"
        XCTAssertNil(HTTPRequest(Data(partial.utf8)), "body not finished")
    }

    func testParsesMethodPathQueryHeadersBody() throws {
        let raw = "POST /claude/next?wait=5&x=y HTTP/1.1\r\nAuthorization: Bearer abc\r\nContent-Length: 11\r\n\r\n{\"t\":\"hi\"}X"
        let r = try XCTUnwrap(HTTPRequest(Data(raw.utf8)))
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/claude/next")
        XCTAssertEqual(r.query["wait"], "5")
        XCTAssertEqual(r.headers["authorization"], "Bearer abc")
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "{\"t\":\"hi\"}X")
    }
}

final class MCPTests: XCTestCase {
    func testToolList() {
        let names = MCPServer.tools.compactMap { $0["name"] as? String }
        for t in ["jarvis_wait_for_request", "jarvis_answer", "jarvis_say", "jarvis_command", "jarvis_page", "jarvis_status",
                  "jarvis_context", "jarvis_remember", "jarvis_memory", "jarvis_screenshot", "jarvis_click", "jarvis_type", "jarvis_key", "jarvis_applescript", "jarvis_shell"] {
            XCTAssertTrue(names.contains(t), "missing tool \(t)")
        }
        XCTAssertEqual(Set(names).count, names.count, "duplicate tool names")
        for tool in MCPServer.tools {
            let schema = tool["inputSchema"] as? [String: Any]
            XCTAssertEqual(schema?["type"] as? String, "object", "\(tool["name"] ?? "?") needs an object schema")
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty)
        }
    }
}

/// Runs a real bridge on a test port and plays the Claude side over HTTP.
@MainActor
final class BridgeTests: XCTestCase {
    private let port: UInt16 = 18777
    private let token = "test-token"
    private var bridge: Bridge!

    override func setUp() async throws {
        bridge = Bridge(port: port, token: token)
        bridge.onSay = { _ in }
        bridge.onFull = { name, _ in ["error": "Full Control is off (\(name))"] }
        bridge.onContext = { ["front_app": "Tests"] }
        bridge.start()
        try await Task.sleep(for: .milliseconds(300))
    }

    override func tearDown() async throws {
        bridge.stop()
        try await Task.sleep(for: .milliseconds(200))
    }

    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, auth: Bool = true) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, timeoutInterval: 20)
        req.httpMethod = method
        if auth { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((resp as! HTTPURLResponse).statusCode, obj)
    }

    func testHealthNeedsNoTokenButOtherRoutesDo() async throws {
        let (h, _) = try await call("GET", "/health", auth: false)
        XCTAssertEqual(h, 200)
        let (s, _) = try await call("GET", "/context", auth: false)
        XCTAssertEqual(s, 401)
        let (c, ctx) = try await call("GET", "/context")
        XCTAssertEqual(c, 200)
        XCTAssertEqual(ctx["front_app"] as? String, "Tests")
    }

    func testAskRoundTrip() async throws {
        XCTAssertFalse(bridge.claudeConnected)
        // Jarvis asks; "Claude" picks it up from the long-poll and answers.
        async let answer = bridge.ask(kind: "ask", text: "capital of France?", context: ["front_app": "Tests"], timeout: 10)
        let (status, req) = try await call("GET", "/claude/next?wait=5")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(req["text"] as? String, "capital of France?")
        XCTAssertEqual(req["kind"] as? String, "ask")
        XCTAssertTrue(bridge.claudeConnected)
        let id = try XCTUnwrap(req["id"] as? String)
        let (ok, _) = try await call("POST", "/claude/answer", ["id": id, "text": "Paris."])
        XCTAssertEqual(ok, 200)
        let reply = await answer
        XCTAssertEqual(reply, "Paris.")
    }

    func testLongPollReturnsNothingWhenIdle() async throws {
        let (status, _) = try await call("GET", "/claude/next?wait=1")
        XCTAssertEqual(status, 204)
    }

    func testAskTimesOutWithoutClaude() async {
        let reply = await bridge.ask(kind: "ask", text: "anyone?", context: [:], timeout: 0.5)
        XCTAssertNil(reply)
    }

    func testUnclaimedRequestIsGivenUpEarly() async {
        bridge.pickupTimeout = 0.5
        let t = Date()
        let reply = await bridge.ask(kind: "ask", text: "anyone?", context: [:], timeout: 30)
        XCTAssertNil(reply)
        XCTAssertLessThan(Date().timeIntervalSince(t), 5, "doesn't wait the full 30 s when no agent picks it up")
    }

    func testAnswerForUnknownIdIs404() async throws {
        let (status, _) = try await call("POST", "/claude/answer", ["id": "nope", "text": "x"])
        XCTAssertEqual(status, 404)
    }

    func testFullControlRoutesGoThroughTheAppGate() async throws {
        let (status, body) = try await call("POST", "/full/shell", ["command": "echo hi"])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["error"] as? String, "Full Control is off (shell)")
    }
}
