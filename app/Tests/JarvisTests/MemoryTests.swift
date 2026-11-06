import XCTest
@testable import VoiceBrowser

final class MemoryTests: XCTestCase {
    private var url: URL!
    private var memory: Memory!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-memory-\(UUID().uuidString).sqlite")
        memory = try Memory(url: url)
    }

    override func tearDownWithError() throws {
        memory = nil
        for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + ext) }
    }

    func testLogsRequestsNewestFirst() {
        memory.log(source: "voice", heard: "open notes", action: Action(action: "open_app", app: "notes"), result: "Opening Notes", engine: "instant rule")
        memory.log(source: "voice", heard: "what time is it", action: Action(action: "info", text: "time"), result: "It's 3 PM", engine: "instant rule")
        let r = memory.recent(5)
        XCTAssertEqual(r.map(\.heard), ["what time is it", "open notes"])
        XCTAssertEqual(r[1].action, Action(action: "open_app", app: "notes"))
        XCTAssertTrue(r[0].ok)
    }

    func testLastActionSkipsQuestionsAndFailures() {
        memory.log(source: "voice", heard: "open notes", action: Action(action: "open_app", app: "notes"), result: "ok", engine: "")
        memory.log(source: "voice", heard: "why is the sky blue", action: Action(action: "ask", text: "why"), result: "…", engine: "gemma")
        memory.log(source: "voice", heard: "open nothing", action: Action(action: "open_app", app: "nothing"), result: "fail", engine: "", ok: false)
        XCTAssertEqual(memory.lastAction(), Action(action: "open_app", app: "notes"))
    }

    func testFactsRememberRecallForget() {
        memory.remember("My sister's name is Maya.")
        memory.remember("I work at Acme")
        memory.remember("I work at Acme") // no duplicates
        XCTAssertEqual(memory.facts().map(\.text), ["My sister's name is Maya", "I work at Acme"])
        XCTAssertEqual(memory.relevantFacts("who is my sister").map(\.text), ["My sister's name is Maya"])
        XCTAssertEqual(memory.forgetLastFact(), "I work at Acme")
        memory.forgetAll()
        XCTAssertTrue(memory.facts().isEmpty)
        XCTAssertTrue(memory.recent().isEmpty)
    }

    func testPersistsAcrossOpens() throws {
        memory.remember("Favourite colour is teal")
        memory = nil
        memory = try Memory(url: url)
        XCTAssertEqual(memory.facts().map(\.text), ["Favourite colour is teal"])
    }

    func testSearchRequests() {
        memory.log(source: "voice", heard: "open github", action: nil, result: "Opening github.com", engine: "")
        memory.log(source: "voice", heard: "volume up", action: nil, result: "Volume 60", engine: "")
        XCTAssertEqual(memory.searchRequests("github").map(\.heard), ["open github"])
    }
}

final class FollowUpTests: XCTestCase {
    func testAgainRepeatsLastAction() {
        let last = Action(action: "volume", direction: "up")
        XCTAssertEqual(FollowUp.resolve("do that again", last: last), last)
        XCTAssertEqual(FollowUp.resolve("Again!", last: last), last)
    }

    func testCloseItClosesWhatWasOpened() {
        XCTAssertEqual(FollowUp.resolve("now close it", last: Action(action: "open_app", app: "notes")),
                       Action(action: "quit_app", app: "notes"))
        XCTAssertEqual(FollowUp.resolve("close that", last: Action(action: "open_url", url: "https://github.com")),
                       Action(action: "close_tab"))
        XCTAssertNil(FollowUp.resolve("close it", last: Action(action: "volume", direction: "up")))
    }

    func testNoFollowUpWithoutHistoryOrMatch() {
        XCTAssertNil(FollowUp.resolve("do that again", last: nil))
        XCTAssertNil(FollowUp.resolve("open github", last: Action(action: "open_app", app: "notes")))
    }
}

final class GuardrailAndConfigTests: XCTestCase {
    func testCPUUsageFromTicks() {
        // user, system, idle, nice
        XCTAssertEqual(CPUGuard.usage(from: [100, 100, 100, 0], to: [190, 150, 110, 0]), 93.33, accuracy: 0.01) // 140 busy of 150 ticks
        XCTAssertEqual(CPUGuard.usage(from: [0, 0, 0, 0], to: [0, 0, 100, 0]), 0)
        XCTAssertEqual(CPUGuard.usage(from: [5, 5, 5, 5], to: [5, 5, 5, 5]), 0, "no ticks, no division by zero")
    }

    func testCPUGuardBlocksLocalModel() async {
        CPUGuard.enabled = true
        let saved = CPUGuard.threshold
        CPUGuard.threshold = -1 // always "busy"
        defer { CPUGuard.threshold = saved }
        do {
            _ = try await Brain.chat([["role": "user", "content": "hi"]], model: "x")
            XCTFail("should refuse while busy")
        } catch BrainError.cpuBusy {
        } catch {
            XCTFail("wrong error \(error)")
        }
        // Instant rules don't need the model, so they still work.
        let (a, viaModel) = try! await Brain.parse("volume up", model: "x")
        XCTAssertEqual(a.action, "volume"); XCTAssertFalse(viaModel)
    }

    func testClapThresholdFromUserClaps() {
        XCTAssertEqual(ClapCalibrator.threshold(from: [0.9, 0.8, 0.7, 0.1])!, 0.48, accuracy: 0.001)
        XCTAssertNil(ClapCalibrator.threshold(from: [0.5]), "one clap isn't enough")
        XCTAssertEqual(ClapCalibrator.threshold(from: [0.2, 0.2])!, 0.15, accuracy: 0.001, "never below 0.15")
    }

    func testAntigravityConfigMergeKeepsOtherServers() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: url.appendingPathExtension("bak")) }
        try Data(#"{"mcpServers": {"github": {"command": "gh-mcp"}}, "other": 1}"#.utf8).write(to: url)
        XCTAssertTrue(try AgentConfig.addJarvis(to: url).hasPrefix("Added"))
        XCTAssertTrue(try AgentConfig.addJarvis(to: url).hasPrefix("Updated"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let servers = try XCTUnwrap(obj["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["github"], "other servers are kept")
        XCTAssertEqual((servers["jarvis"] as? [String: Any])?["args"] as? [String], ["--mcp"])
        XCTAssertEqual(obj["other"] as? Int, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path), "backs up first")
    }

    func testAntigravityConfigRefusesNonObject() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("[1,2]".utf8).write(to: url)
        XCTAssertThrowsError(try AgentConfig.addJarvis(to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "[1,2]", "left untouched")
    }

    func testEmptyConfigFileGetsJarvis() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: Data())
        try AgentConfig.addJarvis(to: url)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNotNil((obj["mcpServers"] as? [String: Any])?["jarvis"])
    }
}
