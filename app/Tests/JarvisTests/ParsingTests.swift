import XCTest
@testable import VoiceBrowser

/// Instant rules: everything here is decided without the local model, so the tests need no Ollama.
final class ParsingTests: XCTestCase {
    private func parse(_ text: String) async throws -> Action {
        let (action, viaModel) = try await Brain.parse(text, model: "unused-model")
        XCTAssertFalse(viaModel, "“\(text)” should be handled by an instant rule")
        return action
    }

    func testBrowserRules() async throws {
        var a = try await parse("scroll down")
        XCTAssertEqual(a.action, "scroll"); XCTAssertEqual(a.direction, "down")
        a = try await parse("Go back.")
        XCTAssertEqual(a.action, "back")
        a = try await parse("go to the second tab")
        XCTAssertEqual(a.action, "switch_tab"); XCTAssertEqual(a.index, 2)
        a = try await parse("tab number three")
        XCTAssertEqual(a.index, 3)
        a = try await parse("last tab")
        XCTAssertEqual(a.index, -1)
        a = try await parse("go to amazon dot in")
        XCTAssertEqual(a.action, "open_url"); XCTAssertEqual(a.url, "https://amazon.in")
    }

    func testMacRules() async throws {
        var a = try await parse("set volume to 30")
        XCTAssertEqual(a.action, "volume"); XCTAssertEqual(a.level, 30)
        a = try await parse("mute the sound")
        XCTAssertEqual(a.action, "volume"); XCTAssertEqual(a.direction, "mute")
        a = try await parse("next song")
        XCTAssertEqual(a.action, "media"); XCTAssertEqual(a.direction, "next")
        a = try await parse("switch to light mode")
        XCTAssertEqual(a.action, "dark_mode"); XCTAssertEqual(a.direction, "off")
        a = try await parse("what time is it")
        XCTAssertEqual(a.action, "info"); XCTAssertEqual(a.text, "time")
        a = try await parse("how much battery do I have")
        XCTAssertEqual(a.text, "battery")
        a = try await parse("open calculator")
        XCTAssertEqual(a.action, "open_app")
    }

    func testAskRules() async throws {
        var a = try await parse("Claude, what's trending on hacker news")
        XCTAssertEqual(a.action, "ask"); XCTAssertEqual(a.engine, "claude")
        XCTAssertEqual(a.text, "what's trending on hacker news")
        a = try await parse("ask locally what is the capital of australia")
        XCTAssertEqual(a.engine, "local"); XCTAssertEqual(a.text, "what is the capital of australia")
        a = try await parse("why is the sky blue")
        XCTAssertEqual(a.action, "ask"); XCTAssertNil(a.engine)
        a = try await parse("what's this page about")
        XCTAssertEqual(a.action, "summarize")
    }

    func testQuestionsThatAreActionsAreNotAsks() {
        // These must go to the model as actions, not be answered as questions.
        XCTAssertNil(Brain.askRule("can you open youtube", original: "can you open youtube"))
        XCTAssertNil(Brain.askRule("could you scroll down a bit", original: "could you scroll down a bit"))
    }

    func testDraftReplyRule() async throws {
        var a = try await parse("draft a reply")
        XCTAssertEqual(a.action, "draft_reply"); XCTAssertEqual(a.text, "")
        a = try await parse("write a polite reply saying I'll join tomorrow")
        XCTAssertEqual(a.action, "draft_reply"); XCTAssertEqual(a.text, "i'll join tomorrow")
        a = try await parse("compose an email to them that we're running late")
        XCTAssertEqual(a.action, "draft_reply"); XCTAssertEqual(a.text, "we're running late")
    }

    func testMetaCommands() {
        XCTAssertEqual(Meta.detect("Give Claude full control.", inSession: false), .fullControlOn)
        XCTAssertEqual(Meta.detect("claude take over", inSession: false), .fullControlOn)
        XCTAssertEqual(Meta.detect("take back control", inSession: false), .fullControlOff)
        XCTAssertEqual(Meta.detect("start session", inSession: false), .startSession)
        XCTAssertEqual(Meta.detect("end session", inSession: true), .endSession)
        XCTAssertNil(Meta.detect("end session", inSession: false), "ending only makes sense inside a session")
        XCTAssertNil(Meta.detect("open github", inSession: true))
        XCTAssertEqual(Meta.detect("mute", inSession: false), .mute, "plain “mute” mutes Jarvis, not the Mac")
        XCTAssertEqual(Meta.detect("go to sleep", inSession: true), .mute)
        XCTAssertEqual(Meta.detect("Stop.", inSession: false), .stop)
        XCTAssertEqual(Meta.detect("never mind", inSession: false), .stop)
        XCTAssertNil(Meta.detect("stop the music", inSession: false))
    }

    func testMemoryAndScreenRules() async throws {
        var a = try await parse("remember that my sister's name is Riya")
        XCTAssertEqual(a.action, "remember"); XCTAssertEqual(a.text, "my sister's name is Riya", "keeps the user's casing")
        a = try await parse("what do you remember about me")
        XCTAssertEqual(a.action, "recall")
        a = try await parse("forget everything")
        XCTAssertEqual(a.action, "forget"); XCTAssertEqual(a.text, "all")
        a = try await parse("forget that")
        XCTAssertEqual(a.text, "last")
        a = try await parse("look at my screen and tell me what this error means")
        XCTAssertEqual(a.action, "screen")
        a = try await parse("what's on my screen")
        XCTAssertEqual(a.action, "screen")
    }

    func testSpokenStripsMarkdown() {
        XCTAssertEqual(AppDelegate.spoken("**Canberra** is the `capital`."), "Canberra is the capital.")
        XCTAssertEqual(AppDelegate.spoken("See [the docs](https://example.com)"), "See the docs")
    }

    func testSummaries() {
        XCTAssertEqual(Action(action: "volume", level: 40).summary, "Volume 40%")
        XCTAssertEqual(Action(action: "draft_reply", text: "yes").summary, "Draft a reply: yes")
        XCTAssertEqual(Action(action: "ask", engine: "claude").summary, "Ask Claude")
    }
}
