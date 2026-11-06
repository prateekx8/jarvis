import AppKit
import XCTest
@testable import VoiceBrowser

final class PhoneHelperTests: XCTestCase {
    func testTailscaleRange() {
        XCTAssertTrue(Tailnet.isTailscale("100.64.0.1"))
        XCTAssertTrue(Tailnet.isTailscale("100.101.12.7"))
        XCTAssertTrue(Tailnet.isTailscale("100.127.255.254"))
        XCTAssertFalse(Tailnet.isTailscale("100.128.0.1"))
        XCTAssertFalse(Tailnet.isTailscale("192.168.1.10"), "never the local Wi-Fi")
        XCTAssertFalse(Tailnet.isTailscale("10.0.0.1"))
        XCTAssertFalse(Tailnet.isTailscale("not an ip"))
    }

    func testQRCodeAndURL() {
        let url = PhoneLink.url(host: "100.90.1.2", token: "abc")
        XCTAssertEqual(url, "http://100.90.1.2:8778/phone?t=abc")
        let qr = PhoneLink.qrCode(url)
        XCTAssertNotNil(qr)
        XCTAssertEqual(qr?.size.width ?? 0, 260, accuracy: 1)
    }

    func testScreenshotThumbnailIsSmallJPEG() throws {
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3000, pixelsHigh: 2000, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        let jpeg = try XCTUnwrap(PhoneLink.thumbnail(png))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8], "JPEG")
        let img = try XCTUnwrap(NSBitmapImageRep(data: jpeg))
        XCTAssertLessThanOrEqual(max(img.pixelsWide, img.pixelsHigh), 1200)
    }

    func testPageUsesOnlyPhoneRoutes() {
        for route in ["/phone/state", "/phone/say", "/phone/screen", "/phone/mute", "/phone/stop"] {
            XCTAssertTrue(PhonePage.html.contains(route), route)
        }
        XCTAssertFalse(PhonePage.html.contains("/claude/"))
        XCTAssertFalse(PhonePage.html.contains("/full/"))
    }
}

/// The phone listener on a test address: own token, only /phone routes.
@MainActor
final class PhoneRouteTests: XCTestCase {
    private var bridge: Bridge!
    private let port: UInt16 = 18778
    private var said: [String] = []
    private var controls: [String] = []

    override func setUp() async throws {
        bridge = Bridge(port: 18779, token: "agent-token")
        bridge.onPhoneState = { ["status": "STANDBY", "log": [["kind": "OK", "text": "hi", "time": "12:00:00.000"]]] }
        bridge.onPhoneSay = { [weak self] text in self?.said.append(text); return "Done: \(text)" }
        bridge.onPhoneControl = { [weak self] name in self?.controls.append(name); return name }
        bridge.onFull = { _, _ in ["result": "SHOULD NOT RUN"] }
        bridge.startPhone(host: "127.0.0.1", port: port, token: "phone-token")
        try await Task.sleep(for: .milliseconds(300))
    }

    override func tearDown() async throws {
        bridge.stop()
        try await Task.sleep(for: .milliseconds(200))
    }

    private func call(_ method: String, _ path: String, token: String? = "phone-token", body: [String: Any]? = nil) async throws -> (Int, Data) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, timeoutInterval: 10)
        req.httpMethod = method
        if let token { req.setValue(token, forHTTPHeaderField: "X-Jarvis-Phone") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as! HTTPURLResponse).statusCode, data)
    }

    func testNeedsThePhoneToken() async throws {
        let (none, _) = try await call("GET", "/phone/state", token: nil)
        XCTAssertEqual(none, 401)
        let (agent, _) = try await call("GET", "/phone/state", token: "agent-token")
        XCTAssertEqual(agent, 401, "the agents' token doesn't open the phone page")
        let (ok, data) = try await call("GET", "/phone/state")
        XCTAssertEqual(ok, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("STANDBY"))
    }

    func testServesThePageWithTokenInURL() async throws {
        let (status, data) = try await call("GET", "/phone?t=phone-token", token: nil)
        XCTAssertEqual(status, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("J.A.R.V.I.S."))
    }

    func testAgentAndFullControlRoutesAreNotReachable() async throws {
        for (m, p) in [("GET", "/claude/next"), ("POST", "/full/shell"), ("POST", "/command"), ("POST", "/hear"), ("GET", "/context")] {
            let (status, data) = try await call(m, p, body: m == "POST" ? ["command": "echo hi", "text": "x"] : nil)
            XCTAssertEqual(status, 404, p)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("SHOULD NOT RUN"))
        }
    }

    func testSayAndControls() async throws {
        let (status, data) = try await call("POST", "/phone/say", body: ["text": "open notes"])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(said, ["open notes"])
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Done: open notes"))
        _ = try await call("POST", "/phone/mute", body: [:])
        _ = try await call("POST", "/phone/stop", body: [:])
        XCTAssertEqual(controls, ["mute", "stop"])
        let (unmute, _) = try await call("POST", "/phone/unmute", body: [:])
        XCTAssertEqual(unmute, 404, "unmuting stays at the Mac")
    }
}
