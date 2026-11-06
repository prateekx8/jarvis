import AppKit

/// Anything that can carry out an `Action`. AppleScript drives your real browser today;
/// a Playwright driver (for scripted test runs) can conform to this later.
protocol BrowserDriver {
    /// Returns a short sentence describing what happened (shown and spoken).
    func execute(_ a: Action, model: String) async throws -> String
}

enum BrowserApp: String, CaseIterable {
    case chrome = "Google Chrome", safari = "Safari"
}

/// Controls Chrome or Safari through AppleScript, keeping the user's own profile and sign-ins.
@MainActor
final class AppleScriptDriver: BrowserDriver {
    var app: BrowserApp = .chrome

    func execute(_ a: Action, model: String) async throws -> String {
        try ensureWindow()
        let tab = app == .safari ? "current tab" : "active tab"
        switch a.action {
        case "open_url":
            let url = normalize(a.url ?? "")
            try setURL(url)
            return "Opening \(URL(string: url)?.host ?? url)"
        case "new_tab":
            let url = a.url.map(normalize) ?? (app == .chrome ? "chrome://newtab" : "")
            if app == .safari {
                try osa("tell application \"Safari\" to tell front window to set current tab to (make new tab with properties {URL:\(q(url))})")
            } else {
                try osa("tell application \"Google Chrome\" to tell front window to make new tab with properties {URL:\(q(url))}")
            }
            return "New tab"
        case "search":
            let query = a.query ?? a.text ?? ""
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: query)]
            try setURL(c.url!.absoluteString)
            return "Searching \(query)"
        case "close_tab":
            try osa("tell application \"\(app.rawValue)\" to close \(tab) of front window")
            return "Closed tab"
        case "switch_tab":
            let i = a.index ?? 1
            if app == .safari {
                try osa("tell application \"Safari\" to tell front window to set current tab to \(i == -1 ? "last tab" : "tab \(i)")")
            } else {
                let n = Int(try osa("tell application \"Google Chrome\" to count tabs of front window")) ?? 1
                try osa("tell application \"Google Chrome\" to set active tab index of front window to \(i == -1 ? n : max(1, min(i, n)))")
            }
            return i == -1 ? "Last tab" : "Tab \(i)"
        case "back", "forward", "reload":
            if app == .chrome {
                // Native Chrome commands: work even with "Allow JavaScript from Apple Events" off.
                let verb = ["back": "go back", "forward": "go forward", "reload": "reload"][a.action]!
                try osa("tell application \"Google Chrome\" to \(verb) active tab of front window")
                return ""
            }
            try js(["back": "history.back()", "forward": "history.forward()", "reload": "location.reload()"][a.action]!)
            return ""
        case "scroll":
            let d = a.direction ?? "down"
            try js([
                "down": "scrollBy({top: innerHeight*0.8, behavior:'smooth'})",
                "up": "scrollBy({top: -innerHeight*0.8, behavior:'smooth'})",
                "top": "scrollTo({top: 0, behavior:'smooth'})",
                "bottom": "scrollTo({top: document.body.scrollHeight, behavior:'smooth'})",
            ][d] ?? "scrollBy(0, innerHeight*0.8)")
            return ""
        case "click":
            let r = try js(Self.clickJS.replacingOccurrences(of: "__WANT__", with: jsString(a.text ?? "")))
            return r == "NOTFOUND" ? "Couldn't find \(a.text ?? "that")" : "Clicked \(r)"
        case "type":
            let r = try js(Self.typeJS
                .replacingOccurrences(of: "__TEXT__", with: jsString(a.text ?? ""))
                .replacingOccurrences(of: "__SUBMIT__", with: a.submit == true ? "true" : "false"))
            return r == "NOINPUT" ? "No text box on this page" : "Typed"
        case "summarize":
            let page = try js("document.title + '\\n\\n' + document.body.innerText.slice(0, 8000)")
            let s = try await Brain.chat([
                ["role": "system", "content": "Summarize this web page in 3 short spoken sentences. No markdown."],
                ["role": "user", "content": page],
            ], model: model)
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case "escalate":
            return try escalate(a.text ?? "")
        default:
            return "I don't know how to \(a.action)"
        }
    }

    // MARK: - Claude hand-off

    /// Multi-step tasks go to Claude: the Claude Code CLI with Claude in Chrome when installed,
    /// otherwise the task is copied and the Claude app opened.
    private func escalate(_ task: String) throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        if let cli = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let cmd = "\(shellQuote(cli)) --chrome \(shellQuote(task))"
            try osa("tell application \"Terminal\"\nactivate\ndo script \(q(cmd))\nend tell")
            return "Handing that to Claude"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(task, forType: .string)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.open(url)
            return "Copied the task. Paste it into Claude"
        }
        return "Copied the task to your clipboard"
    }

    // MARK: - Page context (for Claude and offline answers)

    /// Title and URL of the active tab, if the browser is open. Needs no JavaScript setting.
    func currentTab() -> [String: String] {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == app.rawValue }) else { return [:] }
        let tab = app == .safari ? "current tab" : "active tab"
        let title = (try? osa("tell application \"\(app.rawValue)\" to get title of \(tab) of front window")) ?? ""
        let url = (try? osa("tell application \"\(app.rawValue)\" to get URL of \(tab) of front window")) ?? ""
        return url.isEmpty ? [:] : ["browser": app.rawValue, "page_title": title, "page_url": url]
    }

    /// Puts text into the focused text box of the active tab, if one is focused. Never submits.
    func insertIntoFocused(_ text: String) -> Bool {
        let code = """
        (() => { const el = document.activeElement;
          if (!el || !(el.isContentEditable || el.matches('textarea,input[type=text],input:not([type])'))) return 'NOFOCUS';
          el.focus();
          if (el.isContentEditable) { document.execCommand('insertText', false, \(jsString(text))); }
          else { const set = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value').set;
                 set.call(el, (el.value ? el.value + ' ' : '') + \(jsString(text)));
                 el.dispatchEvent(new Event('input', {bubbles: true})); }
          return 'OK'; })()
        """
        return (try? js(code)) == "OK"
    }

    /// Visible text of the active tab (first 12,000 characters).
    func pageText() throws -> String {
        try js("document.body.innerText.slice(0, 12000)")
    }

    // MARK: - AppleScript plumbing

    private func ensureWindow() throws {
        try osa("tell application \"\(app.rawValue)\"\nactivate\nif (count of windows) = 0 then make new window\nend tell")
    }

    private func setURL(_ url: String) throws {
        let tab = app == .safari ? "current tab" : "active tab"
        try osa("tell application \"\(app.rawValue)\" to set URL of \(tab) of front window to \(q(url))")
    }

    @discardableResult
    private func js(_ code: String) throws -> String {
        let code = code.replacingOccurrences(of: "\n", with: " ")
        if app == .safari {
            return try osa("tell application \"Safari\" to do JavaScript \(q(code)) in current tab of front window")
        }
        return try osa("tell application \"Google Chrome\" to execute active tab of front window javascript \(q(code))")
    }

    @discardableResult
    private func osa(_ source: String) throws -> String {
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err {
            let code = err[NSAppleScript.errorNumber] as? Int ?? -1
            var msg = err[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
            if code == -1743 {
                msg = "Allow Jarvis to control \(app.rawValue) in System Settings → Privacy & Security → Automation."
            } else if msg.localizedCaseInsensitiveContains("JavaScript") {
                msg = app == .chrome
                    ? "In Chrome, turn on View → Developer → Allow JavaScript from Apple Events."
                    : "In Safari, turn on Develop → Allow JavaScript from Apple Events."
            }
            throw NSError(domain: "AppleScript", code: code, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return result?.stringValue ?? ""
    }

    private func normalize(_ url: String) -> String {
        url.range(of: "^(https?|chrome)://", options: .regularExpression) != nil ? url : "https://" + url
    }

    private func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed)
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Page scripts

    private static let clickJS = #"""
    (() => {
      const want = __WANT__.toLowerCase().trim();
      const els = [...document.querySelectorAll('a,button,[role=button],[role=link],[role=tab],[role=menuitem],input[type=submit],input[type=button],summary,label')]
        .filter(e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; });
      const label = e => (e.innerText || e.value || e.getAttribute('aria-label') || e.title || '').toLowerCase().trim().replace(/\s+/g, ' ');
      let best = null, score = 0;
      for (const e of els) {
        const l = label(e); if (!l) continue;
        let s = l === want ? 100 : l.startsWith(want) ? 80 : l.includes(want) ? 60 : 0;
        if (!s) { const w = want.split(' '); s = 40 * w.filter(x => l.includes(x)).length / w.length; }
        const r = e.getBoundingClientRect();
        if (r.top >= 0 && r.bottom <= innerHeight) s += 5;
        if (s > score) { score = s; best = e; }
      }
      if (!best || score < 30) return 'NOTFOUND';
      best.scrollIntoView({block: 'center'}); best.focus(); best.click();
      return label(best).slice(0, 60);
    })()
    """#

    private static let typeJS = #"""
    (() => {
      const text = __TEXT__;
      const ok = e => e && e.matches && e.matches('input:not([type=hidden]):not([type=submit]):not([type=button]),textarea,[contenteditable=true]');
      let el = document.activeElement;
      if (!ok(el)) el = [...document.querySelectorAll('input[type=search],input[type=text],input:not([type]),textarea,[contenteditable=true]')]
        .find(e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; });
      if (!el) return 'NOINPUT';
      el.focus();
      if (el.isContentEditable) { document.execCommand('insertText', false, text); }
      else {
        const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value').set;
        setter.call(el, text);
        el.dispatchEvent(new Event('input', {bubbles: true}));
        el.dispatchEvent(new Event('change', {bubbles: true}));
      }
      if (__SUBMIT__) {
        el.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true}));
        if (el.form) { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); }
      }
      return 'OK';
    })()
    """#
}
