import XCTest
@testable import VoiceBrowser

/// Apple's on-device model is the default on a Mac that has it. The live tests skip where it isn't available.
final class AppleModelTests: XCTestCase {
    func testDefaultFollowsAvailability() {
        XCTAssertEqual(Brain.preferredModel, AppleModel.available ? Brain.appleModel : Brain.defaultModel)
        XCTAssertEqual(Brain.label(Brain.appleModel), "Apple on-device")
        XCTAssertEqual(Brain.label("gemma2:2b"), "gemma2:2b")
    }

    func testAskOfflineRuleAcceptsOnDeviceNames() async throws {
        for phrase in ["ask locally what is a cat", "ask on-device what is a cat", "ask apple what is a cat"] {
            let (a, viaModel) = try await Brain.parse(phrase, model: "unused-model")
            XCTAssertFalse(viaModel)
            XCTAssertEqual(a.engine, "local", phrase)
        }
    }

    func testSchemaConverts() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        XCTAssertNoThrow(try AppleModel.generationSchema(Brain.schema))
    }

    func testLiveParse() async throws {
        try XCTSkipUnless(AppleModel.available, AppleModel.unavailableReason ?? "unavailable")
        let (a, viaModel) = try await Brain.parse("open slack", model: Brain.appleModel)
        XCTAssertTrue(viaModel)
        XCTAssertEqual(a.action, "open_app")
        XCTAssertEqual(a.app?.lowercased(), "slack")
        let (b, _) = try await Brain.parse("make it a bit louder", model: Brain.appleModel)
        XCTAssertEqual(b.action, "volume")
        let reply = try await Brain.chat([["role": "system", "content": "Answer in one short sentence."],
                                          ["role": "user", "content": "What is the capital of Australia?"]], model: Brain.appleModel)
        XCTAssertTrue(reply.contains("Canberra"), reply)
    }
}
