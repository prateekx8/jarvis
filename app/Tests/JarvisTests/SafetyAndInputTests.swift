import XCTest
@testable import VoiceBrowser

final class FullControlTests: XCTestCase {
    func testBlocksDangerousCommands() {
        let blocked = [
            "sudo rm -rf /var/db", "shutdown -h now", "osascript -e 'tell app \"System Events\" to shut down'",
            "rm -rf ~", "rm -rf /", "rm -rf $HOME", "diskutil eraseDisk APFS X disk2", "dd if=/dev/zero of=/dev/disk2",
            ":(){ :|:& };:", "csrutil disable", "security find-generic-password -s foo", "tell application \"Finder\" to empty trash",
            "launchctl bootout gui/501", "reboot",
        ]
        for c in blocked { XCTAssertNotNil(FullControl.refusal(c), "should block: \(c)") }
    }

    func testAllowsEverydayCommands() {
        let allowed = [
            "ls ~/Downloads", "open -a Safari", "rm ~/Downloads/old.zip", "git status", "echo hello",
            "tell application \"Safari\" to make new document", "pmset -g batt", "restart the timer in my app",
        ]
        for c in allowed { XCTAssertNil(FullControl.refusal(c), "should allow: \(c)") }
    }

    func testShellRunsAndReportsExitCode() async {
        let r = await FullControl.shell("echo jarvis-test && exit 3")
        XCTAssertEqual(r["exit_code"], "3")
        XCTAssertTrue(r["output"]?.contains("jarvis-test") == true)
    }

    func testShellRefusesBlocked() async {
        let r = await FullControl.shell("sudo ls")
        XCTAssertNotNil(r["error"])
        XCTAssertNil(r["output"])
    }

    func testKeyParsing() {
        let (code, flags) = FullControl.parseKey("cmd+shift+t")!
        XCTAssertEqual(code, 17)
        XCTAssertTrue(flags.contains(.maskCommand)); XCTAssertTrue(flags.contains(.maskShift))
        XCTAssertEqual(FullControl.parseKey("Return")?.0, 36)
        XCTAssertEqual(FullControl.parseKey("down")?.0, 125)
        XCTAssertNil(FullControl.parseKey("cmd+banana"))
        XCTAssertNil(FullControl.parseKey("cmd"), "a modifier alone isn't a key")
    }

    func testChunking() {
        XCTAssertEqual("abcdefg".chunked(3), ["abc", "def", "g"])
        XCTAssertEqual("".chunked(3), [])
    }
}

final class ClapTests: XCTestCase {
    private let n = 1024
    private func quiet() -> [Float] { (0..<n).map { _ in Float.random(in: -0.005...0.005) } }
    /// A sharp transient: big spike at the start, decaying fast.
    private func clap() -> [Float] { (0..<n).map { i in (i % 2 == 0 ? 1 : -1) * 0.9 * exp(-Float(i) / 60) } }
    /// Sustained loud sound (speech, music): same level for many buffers.
    private func loud() -> [Float] { (0..<n).map { i in 0.5 * sin(Float(i) * 0.3) } }

    func testDetectsClapInQuietRoom() {
        let d = ClapDetector()
        let t = Date()
        for i in 0..<20 { XCTAssertFalse(d.feed(quiet(), now: t + Double(i) * 0.02)) }
        XCTAssertFalse(d.feed(clap(), now: t + 0.5))           // candidate
        XCTAssertTrue(d.feed(quiet(), now: t + 0.52))          // died away → clap
    }

    func testIgnoresSustainedSound() {
        let d = ClapDetector()
        let t = Date()
        for i in 0..<20 { _ = d.feed(quiet(), now: t + Double(i) * 0.02) }
        var fired = false
        for i in 0..<10 { fired = d.feed(loud(), now: t + 0.5 + Double(i) * 0.02) || fired }
        XCTAssertFalse(fired, "speech or music shouldn't count as a clap")
    }

    func testCooldown() {
        let d = ClapDetector()
        let t = Date()
        for i in 0..<20 { _ = d.feed(quiet(), now: t + Double(i) * 0.02) }
        _ = d.feed(clap(), now: t + 1)
        XCTAssertTrue(d.feed(quiet(), now: t + 1.02))
        _ = d.feed(clap(), now: t + 2)
        XCTAssertFalse(d.feed(quiet(), now: t + 2.02), "second clap within 3 s is ignored")
        _ = d.feed(clap(), now: t + 5)
        XCTAssertTrue(d.feed(quiet(), now: t + 5.02))
    }
}
