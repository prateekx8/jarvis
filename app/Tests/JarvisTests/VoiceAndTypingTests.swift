import AVFoundation
import XCTest
@testable import VoiceBrowser

final class TypingRuleTests: XCTestCase {
    private func parse(_ text: String) async throws -> Action {
        let (a, viaModel) = try await Brain.parse(text, model: "unused")
        XCTAssertFalse(viaModel, text)
        return a
    }

    func testTypeKeepsCaseAndDoesNotSubmit() async throws {
        let a = try await parse("type Hello Sam, see you at 4")
        XCTAssertEqual(a.action, "type_text")
        XCTAssertEqual(a.text, "Hello Sam, see you at 4")
        XCTAssertEqual(a.submit, false)
    }

    func testReplyWordsAreTyped() async throws {
        let a = try await parse("reply Sounds good, ship it")
        XCTAssertEqual(a.action, "type_text")
        XCTAssertEqual(a.text, "Sounds good, ship it")
    }

    func testPressEnterOnlyWhenSaid() async throws {
        let a = try await parse("type summarize the last commit and press enter")
        XCTAssertEqual(a.text, "summarize the last commit")
        XCTAssertEqual(a.submit, true)
    }

    func testDraftStillWinsOverType() async throws {
        let a = try await parse("write a reply saying I'll be there")
        XCTAssertEqual(a.action, "draft_reply")
    }
}

final class AudioRecorderTests: XCTestCase {
    func testWritesCommandFromStartMark() throws {
        let r = AudioRecorder()
        r.reset(rate: 16000)
        let tone = (0..<16000).map { Float(sin(Double($0) * 0.1) * 0.3) }   // 1 s
        tone.withUnsafeBufferPointer { r.append($0) }
        r.markStart(secondsBack: 0.5)
        XCTAssertEqual(r.seconds, 0.5, accuracy: 0.01)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNotNil(r.write(to: url))
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 0.5, accuracy: 0.01)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
    }

    func testTooShortIsSkipped() {
        let r = AudioRecorder()
        r.reset(rate: 16000)
        [Float](repeating: 0.1, count: 3000).withUnsafeBufferPointer { r.append($0) } // 0.19 s
        XCTAssertNil(r.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("short.wav")))
    }

    func testKeepsOnlyLast30Seconds() {
        let r = AudioRecorder()
        r.reset(rate: 1000)
        [Float](repeating: 0, count: 45_000).withUnsafeBufferPointer { r.append($0) }
        XCTAssertEqual(r.seconds, 30, accuracy: 0.01)
    }
}

final class VoiceHelperTests: XCTestCase {
    func testWhisperMultipartBody() {
        let body = String(decoding: Whisper.multipart(boundary: "B", fields: ["model": "m", "language": "en"],
                                                      file: Data("WAV".utf8), filename: "a.wav"), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nm\r\n"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nen\r\n"))
        XCTAssertTrue(body.contains("filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\nWAV\r\n"))
        XCTAssertTrue(body.hasSuffix("--B--\r\n"))
    }

    @MainActor
    func testSentences() {
        XCTAssertEqual(Speaker.sentences("Opening YouTube. It's 3 PM! Done?"), ["Opening YouTube.", "It's 3 PM!", "Done?"])
        XCTAssertEqual(Speaker.sentences("no punctuation"), ["no punctuation"])
    }
}
