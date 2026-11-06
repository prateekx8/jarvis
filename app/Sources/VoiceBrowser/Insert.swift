import AppKit
import ApplicationServices

/// "Jarvis, type …" / "Jarvis, reply …": puts text at the cursor in whatever app is in front (a Claude prompt box,
/// Notes, Slack, a browser field…) and highlights it so it's easy to see. Never presses Return on its own.
@MainActor
enum TextInserter {
    enum Method: String { case browser, accessibility, paste, clipboard }

    /// The text is always left on the clipboard too.
    static func insert(_ text: String, driver: AppleScriptDriver) -> Method {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let front = NSWorkspace.shared.frontmostApplication
        if front?.localizedName == driver.app.rawValue, driver.insertIntoFocused(text) { return .browser }
        guard AXIsProcessTrusted(), let pid = front?.processIdentifier else { return .clipboard }

        if let el = focusedElement(pid), insertViaAccessibility(text, into: el) { return .accessibility }

        // Apps that ignore Accessibility text insertion (many Electron apps): paste, then select what was pasted.
        guard FullControl.key("cmd+v")["error"] == nil else { return .clipboard }
        usleep(120_000)
        if text.count <= 400, !text.contains("\n") {
            for _ in 0..<text.count { _ = FullControl.key("shift+left") }
        }
        return .paste
    }

    private static func focusedElement(_ pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// Replaces the selection (or inserts at the cursor), then selects the inserted text.
    /// Returns false when the app says yes but nothing changed, so the caller can paste instead.
    private static func insertViaAccessibility(_ text: String, into el: AXUIElement) -> Bool {
        var before: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &before)
        var rangeRef: CFTypeRef?
        var start = 0
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let r = rangeRef, CFGetTypeID(r) == AXValueGetTypeID() {
            var range = CFRange()
            AXValueGetValue(r as! AXValue, .cfRange, &range)
            start = range.location
        }
        guard AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success else { return false }
        var after: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &after)
        if let b = before as? String, let a = after as? String, a == b { return false } // claimed success, changed nothing
        var inserted = CFRange(location: start, length: (text as NSString).length)
        if let v = AXValueCreate(.cfRange, &inserted) {
            AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v)
        }
        return true
    }
}
