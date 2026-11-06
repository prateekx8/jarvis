import XCTest
@testable import VoiceBrowser

final class ConversationTests: XCTestCase {
    func testFollowUpOnlyAfterSpokenCommands() {
        XCTAssertTrue(Conversation.shouldFollowUp(source: .voice, enabled: true, inSession: false, muted: false, stopped: false))
        XCTAssertFalse(Conversation.shouldFollowUp(source: .bridge, enabled: true, inSession: false, muted: false, stopped: false),
                       "commands from Claude, scripts or the phone don't open the mic")
        XCTAssertFalse(Conversation.shouldFollowUp(source: .voice, enabled: false, inSession: false, muted: false, stopped: false))
        XCTAssertFalse(Conversation.shouldFollowUp(source: .voice, enabled: true, inSession: false, muted: true, stopped: false))
        XCTAssertFalse(Conversation.shouldFollowUp(source: .voice, enabled: true, inSession: false, muted: false, stopped: true))
        XCTAssertFalse(Conversation.shouldFollowUp(source: .voice, enabled: true, inSession: true, muted: false, stopped: false),
                       "a session already keeps listening")
    }

    func testFollowUpQuestionsStayWithClaude() {
        let q = Action(action: "ask", text: "and what about tomorrow")
        XCTAssertEqual(Conversation.sticky(q, inConversation: true, lastEngine: "Claude (MCP)").engine, "claude")
        XCTAssertNil(Conversation.sticky(q, inConversation: true, lastEngine: "gemma2:2b (offline)").engine)
        XCTAssertNil(Conversation.sticky(q, inConversation: false, lastEngine: "Claude (MCP)").engine, "only inside a conversation")
        let local = Action(action: "ask", text: "x", engine: "local")
        XCTAssertEqual(Conversation.sticky(local, inConversation: true, lastEngine: "Claude (MCP)").engine, "local", "an explicit choice wins")
        let open = Action(action: "open_app", app: "notes")
        XCTAssertEqual(Conversation.sticky(open, inConversation: true, lastEngine: "Claude (MCP)"), open, "actions aren't rerouted")
    }

    func testEndingAConversation() {
        XCTAssertEqual(Meta.detect("that's all", inSession: true), .endSession)
        XCTAssertEqual(Meta.detect("Thank you Jarvis.", inSession: true), .endSession)
        XCTAssertNil(Meta.detect("that's all", inSession: false), "outside a conversation it's just a phrase")
    }
}
