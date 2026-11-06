import AppKit
import ApplicationServices
import Vision

/// What Jarvis can tell Claude about what's on screen, gathered when a request is sent.
@MainActor
enum ContextProbe {
    enum Depth {
        /// Front app, window title, selected text, browser tab title and URL.
        case basic
        /// Basic plus the browser page text and the clipboard (draft replies, full control).
        case full
    }

    static func gather(_ depth: Depth, driver: AppleScriptDriver) -> [String: String] {
        var c = driver.currentTab()
        let front = NSWorkspace.shared.frontmostApplication
        c["front_app"] = front?.localizedName ?? ""
        if let pid = front?.processIdentifier, AXIsProcessTrusted() {
            let app = AXUIElementCreateApplication(pid)
            if let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute), let title: String = attribute(window, kAXTitleAttribute), !title.isEmpty {
                c["window_title"] = title
            }
            if let focused: AXUIElement = attribute(app, kAXFocusedUIElementAttribute),
               let selected: String = attribute(focused, kAXSelectedTextAttribute), !selected.isEmpty {
                c["selected_text"] = String(selected.prefix(4000))
            }
        }
        if depth == .full {
            if c["page_url"] != nil, let text = try? driver.pageText(), !text.isEmpty {
                c["page_text"] = String(text.prefix(8000))
            }
            if let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty {
                c["clipboard"] = String(clip.prefix(4000))
            }
        }
        return c
    }

    /// The text a reply should answer: selection first, then the page, then the clipboard.
    static func conversation(in c: [String: String]) -> (source: String, text: String)? {
        for key in ["selected_text", "page_text", "clipboard"] {
            if let t = c[key], !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (key, t) }
        }
        return nil
    }

    private static func attribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

/// "Look at my screen": a screenshot plus its text, read on the Mac with Apple's Vision OCR
/// (so the offline model can use the screen too).
enum ScreenReader {
    static func capture() async -> (path: String?, text: String, labels: [String], error: String?) {
        let shot = await FullControl.screenshot()
        guard let path = shot["path"] else { return (nil, "", [], shot["error"] ?? "Screenshot failed") }
        let url = URL(fileURLWithPath: path)
        let text = (try? await recognizeText(url)) ?? ""
        let labels = (try? await classify(url)) ?? []
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 5 {
            return (path, text, labels, "The screenshot came out empty. Allow Jarvis in System Settings → Privacy & Security → Screen Recording.")
        }
        return (path, text, labels, nil)
    }

    /// What's in an image (e.g. "document", "screenshot", "chart", "person"), from Vision's built-in classifier:
    /// no model download, little memory.
    static func classify(_ url: URL, limit: Int = 6) async throws -> [String] {
        try await Task.detached {
            let request = VNClassifyImageRequest()
            try VNImageRequestHandler(url: url).perform([request])
            return (request.results ?? []).filter { $0.confidence > 0.3 }.prefix(limit).map(\.identifier)
        }.value
    }

    static func recognizeText(_ url: URL) async throws -> String {
        try await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(url: url).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return String(lines.joined(separator: "\n").prefix(8000))
        }.value
    }
}
