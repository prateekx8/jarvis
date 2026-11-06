import AppKit
import ServiceManagement
import SwiftUI

/// Where Jarvis keeps what it installs. Nothing lives outside the app and this folder.
enum Paths {
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Jarvis")
    static let tts = support.appendingPathComponent("tts")
    static let venv = tts.appendingPathComponent(".venv")
    static let python = venv.appendingPathComponent("bin/python")
    static let models = tts.appendingPathComponent("models")
    static let modelFiles = ["kokoro-v1.0.onnx", "voices-v1.0.bin"]
    static let modelBase = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/"

    /// The voice server ships inside the app bundle.
    static var serverScript: URL? { Bundle.main.url(forResource: "server", withExtension: "py") }

    /// Folders that may already hold a Kokoro install (`.venv/` and `models/`), most preferred first:
    /// a custom "ttsDir" setting, Jarvis's own folder, then a project checkout (the one this app was
    /// built from, or ~/DEV/voice-browser/tts). Existing installs are reused instead of downloading again.
    static var voiceDirs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs = [tts,
                    Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                        .deletingLastPathComponent().appendingPathComponent("tts"),
                    home.appendingPathComponent("DEV/voice-browser/tts")]
        if let custom = UserDefaults.standard.string(forKey: "ttsDir") { dirs.insert(URL(fileURLWithPath: custom), at: 0) }
        return dirs.map(\.standardizedFileURL).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// First Python environment found in `voiceDirs`.
    static var installedPython: URL? {
        voiceDirs.map { $0.appendingPathComponent(".venv/bin/python") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// First folder in `voiceDirs` that has both model files.
    static var installedModels: URL? {
        voiceDirs.map { $0.appendingPathComponent("models") }.first { dir in
            modelFiles.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        }
    }

    static var voiceInstalled: Bool { installedPython != nil && installedModels != nil }

    /// "~/DEV/voice-browser/tts" style path for display.
    static func pretty(_ url: URL) -> String {
        url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}

/// One-time setup: Ollama + model, neural voice, permissions, Chrome, login item.
@MainActor
final class SetupModel: ObservableObject {
    enum Status { case pending, running, done, failed, manual }

    struct Step: Identifiable {
        let id: String
        let title: String
        var status: Status = .pending
        var detail = ""
        var progress: Double? = nil
    }

    @Published var steps: [Step] = [
        Step(id: "ollama", title: "Ollama (runs the AI model locally)"),
        Step(id: "model", title: "Language model · \(Brain.defaultModel)"),
        Step(id: "voice", title: "Natural voice · Kokoro"),
        Step(id: "perms", title: "Microphone, speech & automation permissions"),
        Step(id: "chrome", title: "Chrome: Allow JavaScript from Apple Events"),
        Step(id: "claude", title: "Claude (online answers, optional)"),
        Step(id: "login", title: "Start Jarvis when you log in"),
    ]
    @Published var running = false
    @Published var startAtLogin = true
    var onFinished: () -> Void = {}

    var allDone: Bool { steps.allSatisfy { $0.status == .done || $0.status == .manual } }

    func runAll() async {
        running = true
        defer { running = false }
        for step in steps where step.status != .done {
            await run(step.id)
        }
        if steps.first(where: { $0.id == "perms" })?.status == .done {
            UserDefaults.standard.set(true, forKey: "setupDone")
        }
    }

    func run(_ id: String) async {
        update(id) { $0.status = .running; $0.detail = ""; $0.progress = nil }
        do {
            switch id {
            case "ollama": try await ollama()
            case "model": try await model()
            case "voice": try await voice()
            case "perms": try await permissions()
            case "chrome": try chrome()
            case "claude": try await claude()
            case "login": try login()
            default: break
            }
            if steps.first(where: { $0.id == id })?.status == .running { update(id) { $0.status = .done } }
        } catch {
            update(id) { $0.status = .failed; $0.detail = error.localizedDescription; $0.progress = nil }
        }
    }

    private func update(_ id: String, _ change: (inout Step) -> Void) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        change(&steps[i])
    }

    private func fail(_ msg: String) -> NSError {
        NSError(domain: "Setup", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    // MARK: Ollama

    private func ollamaUp() async -> Bool {
        var req = URLRequest(url: URL(string: Brain.host + "/api/tags")!)
        req.timeoutInterval = 2
        return (try? await URLSession.shared.data(for: req)) != nil
    }

    private func ollama() async throws {
        if await ollamaUp() { return update("ollama") { $0.detail = "Running" } }
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.ollama")
            ?? ["/Applications/Ollama.app"].map(URL.init(fileURLWithPath:)).first { FileManager.default.fileExists(atPath: $0.path) }
        if appURL == nil {
            if let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile) {
                update("ollama") { $0.detail = "Installing with Homebrew…" }
                try await shell(brew, ["install", "--cask", "ollama"])
            } else {
                NSWorkspace.shared.open(URL(string: "https://ollama.com/download/mac")!)
                update("ollama") { $0.detail = "Download Ollama from the page that just opened, install it, then press Set Up again." }
                throw fail("Ollama isn't installed yet.")
            }
        }
        update("ollama") { $0.detail = "Starting…" }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.ollama")
            ?? URL(fileURLWithPath: "/Applications/Ollama.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        for _ in 0..<40 {
            if await ollamaUp() { return update("ollama") { $0.detail = "Running" } }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw fail("Ollama didn't start. Open the Ollama app, then try again.")
    }

    // MARK: Model

    private func model() async throws {
        let model = Brain.defaultModel
        if await Brain.installedModels().contains(model) { return update("model") { $0.detail = "Installed" } }
        var req = URLRequest(url: URL(string: Brain.host + "/api/pull")!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        req.timeoutInterval = 3600
        let (bytes, _) = try await URLSession.shared.bytes(for: req)
        for try await line in bytes.lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let err = obj["error"] as? String {
                throw fail(err.contains("connect") || err.contains("lookup")
                    ? "Ollama can't reach the internet. If a firewall (e.g. LuLu) blocks Ollama, allow it, then retry."
                    : err)
            }
            let status = obj["status"] as? String ?? ""
            let total = obj["total"] as? Double ?? 0
            let done = obj["completed"] as? Double ?? 0
            update("model") {
                $0.detail = total > 0 ? "\(status) · \(Int(done / 1e6)) / \(Int(total / 1e6)) MB" : status
                $0.progress = total > 0 ? done / total : nil
            }
        }
        guard await Brain.installedModels().contains(model) else { throw fail("Download didn't finish. Try again.") }
        update("model") { $0.detail = "Installed"; $0.progress = nil }
    }

    // MARK: Neural voice

    private func voice() async throws {
        // 1. A voice server is already running (e.g. started by an earlier Jarvis): nothing to do.
        var health = URLRequest(url: URL(string: "http://127.0.0.1:8765/health")!)
        health.timeoutInterval = 1
        if let (_, resp) = try? await URLSession.shared.data(for: health), (resp as? HTTPURLResponse)?.statusCode == 200 {
            return update("voice") { $0.detail = "Already running" }
        }

        // 2. Reuse any Python environment that already has the voice engine.
        var python: URL?
        for dir in Paths.voiceDirs {
            let candidate = dir.appendingPathComponent(".venv/bin/python")
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            if (try? await shell(candidate.path, ["-c", "import kokoro_onnx"])) != nil { python = candidate; break }
        }
        let models = Paths.installedModels

        if let python, let models {
            return update("voice") {
                $0.detail = "Using existing install · \(Paths.pretty(python.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()))"
                    + (models.deletingLastPathComponent() == python.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                        ? "" : " + models in \(Paths.pretty(models))")
            }
        }

        // 3. Install only what's missing, into Jarvis's own folder.
        let fm = FileManager.default
        if python == nil {
            update("voice") { $0.detail = "Finding Python 3.10 or newer…" }
            let base = try await findPython()
            update("voice") { $0.detail = "Installing voice engine (about 1 minute)…" }
            try fm.createDirectory(at: Paths.tts, withIntermediateDirectories: true)
            try await shell(base, ["-m", "venv", Paths.venv.path])
            try await shell(Paths.python.path, ["-m", "pip", "install", "-q", "--upgrade", "pip"])
            try await shell(Paths.python.path, ["-m", "pip", "install", "-q", "kokoro-onnx"])
        }
        if models == nil {
            try fm.createDirectory(at: Paths.models, withIntermediateDirectories: true)
            for (i, file) in Paths.modelFiles.enumerated() {
                let dest = Paths.models.appendingPathComponent(file)
                if fm.fileExists(atPath: dest.path) { continue }
                try await Downloader.fetch(URL(string: Paths.modelBase + file)!, to: dest) { [weak self] done, total in
                    Task { @MainActor in
                        self?.update("voice") {
                            $0.detail = "Downloading voice model \(i + 1)/\(Paths.modelFiles.count) · \(Int(done / 1e6)) / \(Int(total / 1e6)) MB"
                            $0.progress = total > 0 ? done / total : nil
                        }
                    }
                }
            }
        } else {
            update("voice") { $0.detail = "Reusing voice model in \(Paths.pretty(models!))" }
        }
        update("voice") { $0.detail = "Installed"; $0.progress = nil }
    }

    private func findPython() async throws -> String {
        let candidates = ["/opt/homebrew/bin/python3.13", "/opt/homebrew/bin/python3.12", "/opt/homebrew/bin/python3",
                          "/usr/local/bin/python3", "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
                          "/usr/bin/python3"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let v = try? await shell(path, ["-c", "import sys; print(sys.version_info >= (3, 10))"])
            if v?.contains("True") == true { return path }
        }
        if let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile) {
            update("voice") { $0.detail = "Installing Python with Homebrew…" }
            try await shell(brew, ["install", "python@3.13"])
            for p in ["/opt/homebrew/bin/python3.13", "/usr/local/bin/python3.13"] where FileManager.default.isExecutableFile(atPath: p) {
                return p
            }
        }
        NSWorkspace.shared.open(URL(string: "https://www.python.org/downloads/macos/")!)
        throw fail("Python 3.10+ is needed for the natural voice. Install it from the page that just opened, then retry.")
    }

    // MARK: Permissions and Chrome

    private func permissions() async throws {
        update("perms") { $0.detail = "Answer the macOS prompts…" }
        let ok = await withCheckedContinuation { cont in SpeechListener.authorize { cont.resume(returning: $0) } }
        guard ok else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            throw fail("Allow Microphone and Speech Recognition for Jarvis in System Settings, then retry.")
        }
        // Harmless reads that make macOS ask for the Automation permissions up front.
        _ = try? runAppleScript("tell application \"System Events\" to get name of current user")
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.google.Chrome" }) {
            _ = try? runAppleScript("tell application \"Google Chrome\" to count windows")
        }
        update("perms") { $0.detail = "Allowed" }
    }

    private func chrome() throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil else {
            return update("chrome") { $0.status = .manual; $0.detail = "Chrome not installed · Safari works too (Develop → Allow JavaScript from Apple Events)" }
        }
        let result = try? runAppleScript("""
        tell application "Google Chrome"
            if (count of windows) = 0 then return "nowindow"
            return execute active tab of front window javascript "'ok'"
        end tell
        """)
        if result == "ok" { return update("chrome") { $0.detail = "On" } }
        update("chrome") {
            $0.status = .manual
            $0.detail = result == "nowindow"
                ? "Open a Chrome window, then retry. Needed for click, type, scroll and summarize."
                : "In Chrome: View → Developer → Allow JavaScript from Apple Events, then retry. Needed for click, type, scroll and summarize."
        }
    }

    private func claude() async throws {
        guard ClaudeCLI.path != nil else {
            return update("claude") { $0.status = .manual; $0.detail = "Install the Claude desktop app to answer online. Offline answers work without it." }
        }
        let msg = try await ClaudeCLI.registerMCP()
        let signedIn = await ClaudeCLI.signedIn()
        update("claude") {
            $0.detail = msg + (signedIn ? " · CLI signed in" : " · For answers without an open Claude session: menu → Answers → Sign In to Claude CLI")
        }
    }

    private func login() throws {
        if startAtLogin {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            update("login") { $0.detail = "On" }
        } else {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            update("login") { $0.detail = "Off" }
        }
    }

    // MARK: Helpers

    @discardableResult
    private func shell(_ path: String, _ args: [String]) async throws -> String {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            guard p.terminationStatus == 0 else {
                throw NSError(domain: "Setup", code: Int(p.terminationStatus), userInfo: [
                    NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: path).lastPathComponent) failed: \(text.suffix(300))",
                ])
            }
            return text
        }.value
    }
}

/// File download with progress.
final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let progress: (Double, Double) -> Void
    private var cont: CheckedContinuation<URL, Error>?
    private let dest: URL

    private init(dest: URL, progress: @escaping (Double, Double) -> Void) {
        self.dest = dest
        self.progress = progress
    }

    static func fetch(_ url: URL, to dest: URL, progress: @escaping (Double, Double) -> Void) async throws {
        let d = Downloader(dest: dest, progress: progress)
        let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        _ = try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            d.cont = c
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(Double(totalBytesWritten), Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
                throw NSError(domain: "Setup", code: 2, userInfo: [NSLocalizedDescriptionKey: "Download failed: \(downloadTask.originalRequest?.url?.lastPathComponent ?? "")"])
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            cont?.resume(returning: dest)
        } catch {
            cont?.resume(throwing: error)
        }
        cont = nil
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { cont?.resume(throwing: error); cont = nil }
    }
}

// MARK: - Window

struct SetupView: View {
    @ObservedObject var model: SetupModel
    private let cyan = Color(red: 0.25, green: 0.88, blue: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ArcReactor(phase: model.running ? .thinking : .idle, level: 0, color: cyan)
                VStack(alignment: .leading, spacing: 4) {
                    Text("J.A.R.V.I.S.").font(.system(size: 22, weight: .heavy, design: .monospaced)).tracking(4).foregroundStyle(cyan)
                    Text("One-time setup. Everything runs on this Mac.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.steps) { step in
                    HStack(alignment: .top, spacing: 10) {
                        icon(step.status).frame(width: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(step.title).font(.system(size: 13, weight: .medium))
                                Spacer()
                                if step.status == .failed || step.status == .manual, !model.running {
                                    Button("Retry") { Task { await model.run(step.id) } }.controlSize(.small)
                                }
                            }
                            if step.id == "login" {
                                Toggle("Start at login", isOn: $model.startAtLogin).toggleStyle(.checkbox).font(.system(size: 11))
                            }
                            if let p = step.progress { ProgressView(value: p).tint(cyan) }
                            if !step.detail.isEmpty {
                                Text(step.detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Text("Downloads about 2 GB the first time.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if model.allDone {
                    Button("Start Jarvis") { model.onFinished() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(model.running ? "Setting up…" : "Set Up Everything") { Task { await model.runAll() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.running)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Color(red: 0.03, green: 0.06, blue: 0.09))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private func icon(_ s: SetupModel.Status) -> some View {
        switch s {
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.orange)
        case .manual: Image(systemName: "hand.raised.fill").foregroundStyle(.yellow)
        }
    }
}

@MainActor
final class SetupWindow {
    private var window: NSWindow?
    let model = SetupModel()

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Jarvis Setup"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SetupView(model: model))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
}
