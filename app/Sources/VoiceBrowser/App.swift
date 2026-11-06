import AppKit
import AVFoundation
import Carbon

@main
@MainActor
enum Main {
    static let delegate = AppDelegate()

    static func main() {
        // `VoiceBrowser --parse "open github"` prints the chosen action as JSON (for testing).
        let args = CommandLine.arguments
        // `VoiceBrowser --mcp` is the MCP server Claude launches (stdio); it talks to the running app.
        if args.count > 1, args[1] == "--mcp" { MCPServer.run() }
        // `VoiceBrowser --doctor` shows which existing installs Jarvis would reuse.
        if args.count > 1, args[1] == "--doctor" {
            print("Voice folders searched:", Paths.voiceDirs.map(Paths.pretty).joined(separator: ", "))
            print("Python env:", Paths.installedPython.map(Paths.pretty) ?? "none")
            print("Voice models:", Paths.installedModels.map(Paths.pretty) ?? "none")
            print("Voice server script:", Paths.serverScript.map(Paths.pretty) ?? "missing from app bundle")
            exit(0)
        }
        // `VoiceBrowser --do "what time is it"` also carries it out.
        if args.count > 2, args[1] == "--parse" || args[1] == "--do" {
            let model = UserDefaults.standard.string(forKey: "model") ?? Brain.defaultModel
            Task {
                for text in args.dropFirst(2) {
                    do {
                        let (a, viaModel) = try await Brain.parse(text, model: model)
                        let json = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
                        print("\(text) -> \(json)\(viaModel ? "" : "  [instant]")")
                        if args[1] == "--do" {
                            let result = MacDriver.actions.contains(a.action)
                                ? try MacDriver().execute(a)
                                : try await AppleScriptDriver().execute(a, model: model)
                            print("   = \(result)")
                        }
                    } catch {
                        print("\(text) -> ERROR \(error.localizedDescription)")
                    }
                }
                exit(0)
            }
            RunLoop.main.run()
        }

        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let state = AppState()
    private let listener = SpeechListener()
    private let driver = AppleScriptDriver()
    private let mac = MacDriver()
    private let speaker = Speaker()
    private let setup = SetupWindow()
    private let bridge = Bridge()
    private let answersMenu = NSMenu()
    private var statusItem: NSStatusItem!
    private var hud: HUD!
    private var hotKey: HotKey?
    private var keyDownAt = Date()
    private var hideWork: DispatchWorkItem?
    private var installedModels: [String] = []
    private let modelsMenu = NSMenu()
    private let browserMenu = NSMenu()
    private let recentMenu = NSMenu()
    private var speakItem: NSMenuItem!
    private var pinItem: NSMenuItem!
    private var wakeItem: NSMenuItem!
    private var sessionItem: NSMenuItem!
    private let wakeMenu = NSMenu()
    private let voiceMenu = NSMenu()
    /// Session mode: keep listening for command after command, no wake word needed.
    private var session = false
    private var sessionDeadline = Date()
    private var lastWakeActive = false
    /// Full Control: Claude may use screenshot / keyboard / mouse / AppleScript / shell until this time.
    /// Never persisted; extended by 30 min on each use.
    private var fullControlUntil: Date?
    private var fullControl: Bool { (fullControlUntil ?? .distantPast) > Date() }
    private var fullControlItem: NSMenuItem!
    private var clapItem: NSMenuItem!
    private var followUpItem: NSMenuItem!
    /// Listening for a follow-up right after a reply (no wake word needed).
    private var inConversation = false
    /// Start follow-up listening once Jarvis has finished speaking.
    private var pendingFollowUp = false
    /// Who answered the last command ("Claude (MCP)", "gemma2:2b (offline)", "instant rule"…).
    private var lastEngine = ""
    private var followUpEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "followUp") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "followUp") }
    }
    private var clapEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "clap") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "clap"); listener.clapEnabled = newValue }
    }
    /// Where a command came from: spoken, or sent over the bridge (Claude, scripts, iPhone).
    enum Source: String { case voice, bridge, phone }
    private var phoneTimer: Timer?
    /// Muted: no listening, no speaking, nothing executed (including bridge commands). Persists.
    private var muted: Bool {
        get { UserDefaults.standard.bool(forKey: "muted") }
        set { UserDefaults.standard.set(newValue, forKey: "muted"); state.muted = newValue }
    }
    /// Bumped by Stop: results of commands started before it are not shown or spoken.
    private var runGeneration = 0
    private var muteItem: NSMenuItem!
    private var whisperItem: NSMenuItem!
    /// Second pass over each command with Whisper (via Creator Studio's voice server) when it's running.
    private var whisperEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "whisper") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "whisper"); listener.recordForWhisper = newValue }
    }
    private var strictItem: NSMenuItem!
    private var cpuItem: NSMenuItem!
    private let memory: Memory? = try? Memory()

    private var model: String {
        get { UserDefaults.standard.string(forKey: "model") ?? Brain.defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: "model") }
    }
    private var speak: Bool {
        get { UserDefaults.standard.object(forKey: "speak") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "speak") }
    }
    private var recent: [String] {
        get { UserDefaults.standard.stringArray(forKey: "recent") ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(10)), forKey: "recent") }
    }
    /// "always", "apps" (only while one of `wakeApps` is running) or "off".
    private var wakeMode: String {
        get {
            UserDefaults.standard.string(forKey: "wakeMode")
                ?? (UserDefaults.standard.object(forKey: "wake") as? Bool == false ? "off" : "apps")
        }
        set { UserDefaults.standard.set(newValue, forKey: "wakeMode") }
    }
    private var wakeApps: [String] {
        get { UserDefaults.standard.stringArray(forKey: "wakeApps") ?? ["Google Chrome"] }
        set { UserDefaults.standard.set(newValue, forKey: "wakeApps") }
    }
    private var wakeActive: Bool {
        switch wakeMode {
        case "always": return true
        case "apps": return NSWorkspace.shared.runningApplications.contains { wakeApps.contains($0.localizedName ?? "") }
        default: return false
        }
    }
    /// Who answers questions: "auto" (Claude when connected, else offline), "claude" or "local".
    private var answerMode: String {
        get { UserDefaults.standard.string(forKey: "answers") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "answers") }
    }
    private var pinned: Bool {
        get { UserDefaults.standard.bool(forKey: "pinned") }
        set { UserDefaults.standard.set(newValue, forKey: "pinned"); state.pinned = newValue }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        driver.app = BrowserApp(rawValue: UserDefaults.standard.string(forKey: "browser") ?? "") ?? .chrome
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(listening: false)
        buildMenu()
        hud = HUD(state: state)
        state.pinned = pinned
        state.log(.sys, "Online · model \(model) · \(driver.app.rawValue)")
        if pinned { hud.show() }

        listener.onPartial = { [weak self] text in
            self?.state.transcript = text
            self?.hud.show()
        }
        listener.onFinal = { [weak self] text, wav in self?.heard(text, wav: wav) }
        listener.recordForWhisper = whisperEnabled
        listener.onLevel = { [weak self] level in
            guard let self, self.state.phase == .listening || level == 0 else { return }
            self.state.level = level
        }
        listener.onWake = { [weak self] in self?.woke() }
        listener.onClap = { [weak self] in self?.clapped() }
        listener.clapEnabled = clapEnabled

        speaker.voice = UserDefaults.standard.string(forKey: "voice") ?? Speaker.defaultVoice
        speaker.onLog = { [weak self] msg in self?.state.log(.sys, msg) }
        Task {
            await speaker.start()
            // Load Whisper now so the first command isn't slowed by the model loading (~8 s once).
            if whisperEnabled, speaker.backend == .studio {
                let r = AudioRecorder()
                r.reset(rate: 16000)
                [Float](repeating: 0, count: 8000).withUnsafeBufferPointer { r.append($0) }
                if let wav = r.write(to: Paths.support.appendingPathComponent("whisper-warmup.wav")) {
                    let t = Date()
                    _ = try? await Whisper.transcribe(wav, timeout: 60)
                    state.log(.sys, "Whisper ready (\(ms(since: t)))")
                }
            }
        }
        state.muted = muted
        SpeechListener.strictWake = UserDefaults.standard.object(forKey: "strictWake") as? Bool ?? true
        if let peak = UserDefaults.standard.object(forKey: "clapMinPeak") as? Float { listener.clapMinPeak = peak }
        CPUGuard.enabled = UserDefaults.standard.object(forKey: "cpuGuard") as? Bool ?? true
        CPUGuard.start()
        if memory == nil { state.log(.err, "Memory database couldn't open; Jarvis works without memory") }
        if muted { state.log(.sys, "Jarvis is muted · menu → Unmute, or press ⌥Space") }

        bridge.onLog = { [weak self] kind, msg in self?.state.log(kind, msg) }
        bridge.onSay = { [weak self] text in
            guard let self, !self.muted else { return }
            self.state.log(.ok, "Claude says: \(text)")
            self.flash(.done, "Claude", text)
            self.speaker.speak(Self.spoken(text))
        }
        bridge.onCommand = { [weak self] text in await self?.perform(text) ?? [:] }
        bridge.onHear = { [weak self] text in
            guard let self else { return "" }
            self.state.log(.heard, "“\(text)” (typed)")
            return await self.run(text, source: .bridge)
        }
        bridge.onStatus = { [weak self] in self?.status() ?? [:] }
        bridge.onPage = { [weak self] in self?.page() ?? [:] }
        bridge.onContext = { [weak self] in self?.context() ?? [:] }
        bridge.onFull = { [weak self] name, body in await self?.full(name, body) ?? [:] }
        bridge.onMemory = { [weak self] op, body in self?.memoryOp(op, body) ?? [:] }
        bridge.start()
        bridge.onPhoneState = { [weak self] in self?.phoneState() ?? [:] }
        bridge.onPhoneSay = { [weak self] text in
            guard let self else { return "" }
            self.state.log(.heard, "“\(text)” (phone)")
            return await self.run(text, source: .phone)
        }
        bridge.onPhoneScreen = { [weak self] in await self?.phoneScreen() ?? (nil, "unavailable") }
        bridge.onPhoneControl = { [weak self] name in self?.phoneControl(name) ?? "" }
        updatePhoneLink()
        phoneTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePhoneLink() }
        }

        setup.model.onFinished = { [weak self] in
            guard let self else { return }
            self.setup.close()
            self.state.log(.sys, "Setup complete")
            Task {
                self.installedModels = await Brain.installedModels()
                await self.speaker.start()
                await Brain.warmUp(model: self.model)
                self.updateWake(reason: "setup")
                self.speaker.speak("Jarvis online. Say Hey Jarvis whenever you need me.")
            }
        }
        if !UserDefaults.standard.bool(forKey: "setupDone") { setup.show() }

        // Arm / pause the wake word as the chosen apps open and quit.
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.localizedName ?? "app"
                let verb = name == NSWorkspace.didLaunchApplicationNotification ? "opened" : "quit"
                Task { @MainActor in self?.updateWake(reason: "\(app) \(verb)") }
            }
        }

        let key = HotKey(keyCode: kVK_Space, modifiers: optionKey)
        key.onDown = { [weak self] in self?.hotKeyDown() }
        key.onUp = { [weak self] in self?.hotKeyUp() }
        hotKey = key
        if !key.registered {
            flash(.error, "⌥Space is taken by another app", "Use the menu bar icon → Listen instead.")
        }

        SpeechListener.authorize { [weak self] ok in
            guard let self else { return }
            if !ok {
                self.state.log(.err, "Microphone or Speech Recognition not allowed")
                self.flash(.error, "Jarvis needs Microphone and Speech Recognition", "Allow both in System Settings → Privacy & Security.")
            } else {
                self.updateWake(reason: nil)
            }
        }
        Task {
            installedModels = await Brain.installedModels()
            if installedModels.isEmpty {
                state.log(.err, "Ollama unreachable or no models installed")
            } else if !installedModels.contains(model) {
                state.log(.err, "\(model) not installed. Run: ollama pull \(model)")
            }
            let t = Date()
            await Brain.warmUp(model: model)
            state.log(.sys, "\(model) loaded in \(ms(since: t))")
        }
    }

    // MARK: - Hotkey: hold to talk, or tap to talk hands-free (ends on a pause)

    private func hotKeyDown() {
        if muted { setMuted(false, why: "⌥Space") }
        if speaker.isSpeaking && state.phase != .listening {
            stopEverything(why: "⌥Space")
            return
        }
        if state.phase == .listening {
            listener.holdOpen = false
            listener.stop()
            return
        }
        keyDownAt = Date()
        listener.holdOpen = true
        startListening()
    }

    private func hotKeyUp() {
        guard state.phase == .listening else { return }
        listener.holdOpen = false
        if Date().timeIntervalSince(keyDownAt) > 0.45 { listener.stop() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        speaker.shutdown()
    }

    // MARK: - Wake word and sessions

    /// Arms or pauses the wake word when its condition (always / chosen apps running / off) changes.
    private func updateWake(reason: String?) {
        let active = wakeActive
        defer { lastWakeActive = active }
        let why = reason.map { " · \($0)" } ?? ""
        if active && !lastWakeActive {
            state.log(.sys, "Wake word armed: “Hey Jarvis”\(why)")
            resumeListening()
        } else if !active && lastWakeActive {
            if listener.isWaitingForWake { listener.cancel() }
            state.log(.sys, "Wake word paused\(why)")
        }
    }

    private func startSession() {
        session = true
        state.session = true
        sessionDeadline = Date().addingTimeInterval(120)
        state.log(.sys, "Session started · no wake word needed · say “end session” to stop")
        flash(.done, "Session started", "Listening for commands. Say “end session” when you're done.")
        speaker.speak("Session started. I'm listening.")
        resumeListening()
    }

    private func endSession(_ why: String) {
        guard session else { return }
        session = false
        state.session = false
        if state.phase == .listening { listener.cancel(); setIcon(listening: false) }
        state.log(.sys, "Session ended · \(why)")
        flash(.done, "Session ended", why)
        speaker.speak("Session ended.")
        resumeListening()
    }

    private func woke() {
        hideWork?.cancel()
        speaker.stop()
        state.log(.mic, "Wake word detected")
        state.phase = .listening
        state.transcript = ""
        state.detail = "Yes? Go ahead…"
        setIcon(listening: true)
        NSSound(named: "Tink")?.play()
        hud.show()
    }

    /// After a command: in a session, listen for the next one; otherwise wait for "Hey Jarvis".
    /// Waits until Jarvis has finished speaking so it doesn't hear itself.
    private func resumeListening() {
        guard !muted, state.phase != .listening, state.phase != .thinking else { return }
        guard session || pendingFollowUp || (wakeActive && !listener.isWaitingForWake) else { return }
        if speaker.isSpeaking {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.resumeListening() }
            return
        }
        if session { return startListening() }
        if pendingFollowUp {
            // A short pause after Jarvis stops talking, so the tail of its own voice isn't heard as a reply.
            pendingFollowUp = false
            inConversation = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.inConversation, !self.muted, self.state.phase != .listening, self.state.phase != .thinking else { return }
                self.startListening()
            }
            return
        }
        do {
            try listener.startWake()
        } catch {
            state.log(.err, "Wake word: \(error.localizedDescription)")
        }
    }

    // MARK: - Pipeline

    private func startListening() {
        hideWork?.cancel()
        speaker.stop()
        state.phase = .listening
        state.transcript = ""
        state.detail = session ? "Session · go ahead…" : inConversation ? "Anything else? I'm listening…" : "Listening… release ⌥Space or pause to send"
        setIcon(listening: true)
        hud.show()
        if inConversation {
            state.log(.mic, "Listening for a follow-up")
        } else if !session {
            state.log(.mic, "Listening")
        }
        do {
            try listener.start()
        } catch {
            setIcon(listening: false)
            endSession("microphone error")
            flash(.error, "Couldn't start listening", error.localizedDescription)
            resumeListening()
        }
    }

    private func heard(_ text: String, wav: URL? = nil) {
        setIcon(listening: false)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            state.phase = .idle
            if session {
                if Date() > sessionDeadline { return endSession("no commands for 2 minutes") }
            } else if inConversation {
                inConversation = false // silence ends the conversation; back to "Hey Jarvis"
                state.log(.mic, "Conversation ended (silence)")
                if !pinned { hud.hide() }
            } else {
                state.log(.mic, "Nothing heard")
                if !pinned { hud.hide() }
            }
            resumeListening()
            return
        }
        state.log(.heard, "“\(text)”")
        Task { await run(await improved(text, wav: wav)) }
    }

    /// Whisper's transcript of the same audio when it's available and differs; otherwise Apple's.
    private func improved(_ text: String, wav: URL?) async -> String {
        guard whisperEnabled, let wav, speaker.backend == .studio else { return text }
        state.detail = "Checking with Whisper…"
        let t = Date()
        guard let w = try? await Whisper.transcribe(wav, timeout: 6) else {
            state.log(.err, "Whisper didn't answer; using Apple's transcript")
            return text
        }
        let cleaned = w.replacingOccurrences(of: #"^\s*(?:(?:hey|hi|ok|okay)[ ,]+)?(?:jarvis|jarvas|jarves|jervis|javis)\b[ ,.!?]*"#,
                                             with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return text }
        if cleaned.lowercased().trimmingCharacters(in: .punctuationCharacters) != text.lowercased().trimmingCharacters(in: .punctuationCharacters) {
            state.log(.heard, "Whisper: “\(cleaned)”  \(ms(since: t))")
        }
        return cleaned
    }

    /// Runs one command and returns what Jarvis said (or the error).
    @discardableResult
    private func run(_ command: String, source: Source = .voice) async -> String {
        state.phase = .idle // listening has ended by the time a command runs
        // In a session people still say "Hey Jarvis, ..." out of habit; drop it.
        let command = command.replacingOccurrences(
            of: #"^\s*(?:(?:hey|hi|ok|okay)[ ,]+)?(?:jarvis|jarvas|jarves|jervis|javis)\b[ ,.!?]*"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        if muted {
            state.log(.err, "Muted: ignored “\(command)” from \(source.rawValue)")
            return "Jarvis is muted. Unmute from the menu or press Option-Space."
        }
        let generation = runGeneration
        switch Meta.detect(command, inSession: session || inConversation) {
        case .mute:
            setMuted(true, why: "by voice")
            return "Muted"
        case .stop:
            stopEverything(why: "by voice")
            return "Stopped"
        case .startSession:
            session ? resumeListening() : startSession()
            return "Session started"
        case .endSession:
            if session {
                endSession("by voice")
                return "Session ended"
            }
            inConversation = false
            pendingFollowUp = false
            state.log(.sys, "Conversation ended")
            flash(.done, "Okay", "")
            speaker.speak("Okay.")
            resumeListening()
            return "Okay"
        case .fullControlOn:
            // Only the person at the Mac can hand over control, never a bridge client.
            guard source == .voice else {
                state.log(.err, "Refused: Full Control can only be turned on by voice or the menu")
                return "Full Control can only be turned on by voice or from the menu."
            }
            setFullControl(true, why: "by voice")
            return "Full Control on"
        case .fullControlOff:
            setFullControl(false, why: "by voice")
            return "Full Control off"
        case nil:
            break
        }
        guard !command.isEmpty else { resumeListening(); return "" }
        sessionDeadline = Date().addingTimeInterval(120)
        hideWork?.cancel()
        state.phase = .thinking
        state.transcript = command
        state.detail = "Thinking with \(model)…"
        hud.show()
        recent = [command] + recent.filter { $0 != command }
        var said = ""
        do {
            var t = Date()
            let (understood, viaModel) = try await understand(command)
            let action = Conversation.sticky(understood, inConversation: inConversation, lastEngine: lastEngine)
            if action != understood { state.log(.sys, "Follow-up: keeping it with Claude") }
            state.log(.parse, "\(viaModel) → \(actionJSON(action))  \(ms(since: t))")
            state.detail = action.summary
            hud.show()
            t = Date()
            let result: String
            var engine = "jarvis"
            if ["remember", "recall", "forget"].contains(action.action) {
                result = remember(action)
            } else if action.action == "type_text" {
                result = typeText(action)
            } else if action.action == "screen" {
                let (reply, via) = try await lookAtScreen(action, command: command)
                result = reply
                engine = via
                state.log(.exec, "Screen answered by \(via)  \(ms(since: t))")
            } else if action.action == "draft_reply" {
                let (reply, via) = try await draft(action)
                result = reply
                engine = via
                state.log(.exec, "Drafted by \(via)  \(ms(since: t))")
            } else if action.action == "ask" || action.action == "escalate" {
                let (reply, via) = try await answer(action, command: command)
                result = reply
                engine = via
                state.log(.exec, "Answered by \(via)  \(ms(since: t))")
            } else {
                let onMac = MacDriver.actions.contains(action.action)
                result = onMac ? try mac.execute(action) : try await driver.execute(action, model: model)
                state.log(.exec, "\(action.summary) via \(onMac ? "macOS" : driver.app.rawValue)  \(ms(since: t))")
            }
            memory?.log(source: source.rawValue, heard: command, action: action, result: result, engine: engine,
                        context: ["front_app": NSWorkspace.shared.frontmostApplication?.localizedName ?? ""])
            guard generation == runGeneration else { return "Stopped" } // the user said stop meanwhile
            lastEngine = engine
            pendingFollowUp = Conversation.shouldFollowUp(source: source, enabled: followUpEnabled, inSession: session, muted: muted, stopped: false)
            state.log(.ok, result.isEmpty ? "Done" : result)
            flash(.done, command, result.isEmpty ? action.summary : result)
            if speak && !result.isEmpty { say(result) }
            said = result
        } catch {
            memory?.log(source: source.rawValue, heard: command, action: nil, result: error.localizedDescription, engine: "", ok: false)
            guard generation == runGeneration else { return "Stopped" }
            state.log(.err, error.localizedDescription)
            flash(.error, command, error.localizedDescription)
            if speak { say("Sorry, that didn't work") }
            said = "Error: \(error.localizedDescription)"
            pendingFollowUp = Conversation.shouldFollowUp(source: source, enabled: followUpEnabled, inSession: session, muted: muted, stopped: false)
        }
        resumeListening()
        return said
    }

    // MARK: - Answers: Claude (online) or the local model (offline)

    static let claudeSystem = """
    You are the online brain of Jarvis, the user's voice assistant on their Mac. Your final message is spoken \
    aloud: 1–3 short plain sentences, no markdown, no lists, no URLs unless asked. Use jarvis_page to read the \
    current browser tab and jarvis_command to act in the browser or on the Mac (one action per call). Ask before \
    sending messages, posting, buying or deleting anything.
    """

    private static let localSystem = """
    You are Jarvis, a concise voice assistant running offline on the user's Mac. Answer in 1–3 short spoken \
    sentences, no markdown. If the answer needs live information (news, weather, prices, today's events) or you \
    aren't sure, say so briefly instead of guessing.
    """

    /// Questions ("ask") and multi-step tasks ("escalate"). Claude first when allowed and reachable
    /// (a Claude session over MCP, else the Claude CLI), otherwise the local model.
    private func answer(_ a: Action, command: String) async throws -> (String, String) {
        let task = a.action == "escalate"
        let question = (a.text?.isEmpty == false ? a.text : nil) ?? command
        var context = self.context()
        if inConversation, let prev = memory?.recent(2).dropFirst().first {
            // This is a follow-up: tell Claude what it continues.
            context["follow_up"] = "yes"
            context["previous_exchange"] = "\(prev.heard) → \(prev.result.prefix(400))"
        }
        let useClaude = a.engine == "claude" || (a.engine != "local" && (task || answerMode != "local"))
        var note = ""

        if useClaude {
            if bridge.claudeConnected {
                state.detail = "Asking Claude…"
                state.log(.exec, "Sent to Claude over MCP")
                if let reply = await bridge.ask(kind: task ? "task" : "ask", text: question, context: context, timeout: task ? 300 : 90) {
                    return (Self.spoken(reply), "Claude (MCP)")
                }
                state.log(.err, "Claude didn't answer in time")
            } else if await ClaudeCLI.signedIn() {
                state.detail = "Asking Claude…"
                let where_ = context.isEmpty ? "" : "\nContext: " + context.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
                let prompt = (task ? "Do this for the user, using the jarvis tools: " : "The user asked: ") + "\"\(question)\"" + where_
                do {
                    return (Self.spoken(try await ClaudeCLI.ask(prompt, system: Self.claudeSystem, timeout: task ? 300 : 90)), "Claude (CLI)")
                } catch {
                    state.log(.err, "Claude CLI: \(error.localizedDescription)")
                }
            } else {
                state.log(.sys, "Claude not connected: no Claude session over MCP, and the Claude CLI isn't signed in")
            }
            if task { return (try await driver.execute(a, model: model), "hand-off") } // copy + open the Claude app
            if a.engine == "claude" || answerMode == "claude" { note = "Claude isn't connected, so here's an offline answer. " }
        }

        state.detail = "Answering offline with \(model)…"
        let page = context["page_title"].map { "\n(The user is looking at: \($0) — \(context["page_url"] ?? ""))" } ?? ""
        let facts = memory?.relevantFacts(question).map(\.text) ?? []
        let known = facts.isEmpty ? "" : "\n\nThings the user told you to remember:\n" + facts.map { "- \($0)" }.joined(separator: "\n")
        if CPUGuard.busy {
            return ("Your Mac is busy right now, CPU at \(Int(CPUGuard.usage)) percent, so I won't run the local model. Ask Claude, or try again in a moment.", "CPU guardrail")
        }
        let reply = try await Brain.chat([["role": "system", "content": Self.localSystem + known],
                                          ["role": "user", "content": question + page]], model: model)
        return (note + Self.spoken(reply), "\(model) (offline)")
    }

    /// Text that reads well aloud: no markdown symbols.
    nonisolated static func spoken(_ text: String) -> String {
        text.replacingOccurrences(of: #"[*_`#>]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Bridge handlers (what Claude can do through Jarvis)

    /// One browser or Mac action requested by Claude through `jarvis_command`.
    private func perform(_ text: String) async -> [String: String] {
        if muted { return ["error": "Jarvis is muted; nothing will be executed until the user unmutes it."] }
        do {
            let (a, _) = try await Brain.parse(text, model: model)
            guard a.action != "ask", a.action != "escalate" else {
                return ["error": "That isn't a single browser or Mac action. Answer it yourself, or send one step, e.g. \"open github.com\" or \"click Sign in\"."]
            }
            state.log(.parse, "Claude ▸ “\(text)” → \(actionJSON(a))")
            let onMac = MacDriver.actions.contains(a.action)
            let result = onMac ? try mac.execute(a) : try await driver.execute(a, model: model)
            state.log(.ok, result.isEmpty ? a.summary : result)
            return ["action": actionJSON(a), "result": result.isEmpty ? "Done: \(a.summary)" : result]
        } catch {
            state.log(.err, "Claude ▸ \(text): \(error.localizedDescription)")
            return ["error": error.localizedDescription]
        }
    }

    // MARK: - Draft a reply

    private static let draftSystem = """
    You draft replies for the user. Write only the reply text in the user's voice: natural, concise, matching \
    the tone of the conversation. No subject line, no preamble, no placeholders like [Name] unless unavoidable.
    """

    /// Drafts a reply to what's on screen (selection, page, or clipboard), puts it in the focused text box
    /// when there is one and on the clipboard. Never sends.
    private func draft(_ a: Action) async throws -> (String, String) {
        var c = ContextProbe.gather(.full, driver: driver)
        guard let convo = ContextProbe.conversation(in: c) else {
            // Nothing to reply to: "Jarvis, reply <words>" types the words where the cursor is.
            if let words = a.text, !words.isEmpty { return (typeText(Action(action: "type_text", text: words)), "typed") }
            return ("I don't see a conversation to reply to. Select the message, or copy it, and ask again.", "nothing")
        }
        let how = (a.text ?? "").isEmpty ? "Reply appropriately." : "The reply should say: \(a.text!)"
        c["conversation"] = convo.text
        c["conversation_source"] = convo.source
        let request = "Draft a reply to the conversation in context.conversation. \(how)"
        var text: String?
        var via = ""

        if answerMode != "local" {
            if bridge.claudeConnected {
                state.detail = "Claude is drafting…"
                text = await bridge.ask(kind: "draft", text: request, context: c, timeout: 120)
                via = "Claude (MCP)"
            } else if await ClaudeCLI.signedIn() {
                state.detail = "Claude is drafting…"
                let prompt = "\(request)\n\nConversation (from \(convo.source)):\n\(convo.text)\n\nReturn only the reply text."
                text = try? await ClaudeCLI.ask(prompt, system: Self.draftSystem, timeout: 120)
                via = "Claude (CLI)"
            }
        }
        if text == nil {
            state.detail = "Drafting offline with \(model)…"
            text = try await Brain.chat([["role": "system", "content": Self.draftSystem],
                                         ["role": "user", "content": "Conversation:\n\(convo.text.prefix(4000))\n\n\(how)"]], model: model)
            via = "\(model) (offline)"
        }
        let reply = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reply, forType: .string)
        let inserted = driver.insertIntoFocused(reply)
        state.log(.ok, "Draft (\(reply.count) chars) → \(inserted ? "reply box + clipboard" : "clipboard")")
        let first = reply.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? reply
        let where_ = inserted ? "It's in the reply box." : "It's on the clipboard; press Command V to paste."
        return ("Here's a draft: \(first.prefix(140)). \(where_) I haven't sent it.", via)
    }

    // MARK: - Context and Full Control

    private func context() -> [String: String] {
        var c = ContextProbe.gather(fullControl ? .full : .basic, driver: driver)
        c["full_control"] = fullControl ? "on" : "off"
        if let memory {
            let history = memory.recent(5).reversed().map { "\($0.heard) → \($0.result.prefix(120))" }
            if !history.isEmpty { c["recent_history"] = history.joined(separator: "\n") }
            let facts = memory.facts().suffix(30).map(\.text)
            if !facts.isEmpty { c["memory_facts"] = facts.joined(separator: "\n") }
        }
        return c
    }

    private func setFullControl(_ on: Bool, why: String) {
        if on {
            FullControl.requestPermissions()
            fullControlUntil = Date().addingTimeInterval(30 * 60)
            state.log(.sys, "Claude has Full Control for 30 min (\(why)) · say “take back control” to stop")
            flash(.done, "Claude has Full Control", "Screenshot, keyboard, mouse, AppleScript and shell. Say “take back control” to stop.")
            speaker.speak("Full control handed to Claude. Say take back control to stop.")
        } else {
            guard fullControlUntil != nil else { return }
            fullControlUntil = nil
            state.log(.sys, "Full Control off (\(why))")
            flash(.done, "Full Control off", "Claude is back to standard tools.")
            speaker.speak("You have control.")
        }
        state.fullControl = fullControl
    }

    /// Full Control tools, called by Claude through the bridge.
    private func full(_ name: String, _ body: [String: Any]) async -> [String: String] {
        if muted { return ["error": "Jarvis is muted; nothing will be executed until the user unmutes it."] }
        guard fullControl else {
            if fullControlUntil != nil { setFullControl(false, why: "30 minutes passed") }
            return ["error": "Full Control is off. Ask the user to say “Hey Jarvis, give Claude full control” or use the menu."]
        }
        fullControlUntil = Date().addingTimeInterval(30 * 60)
        let arg = ["shell": "command", "applescript": "script", "type": "text", "key": "keys"][name].flatMap { body[$0] as? String } ?? ""
        let detail = name == "click" ? "\(body["x"] ?? "?"),\(body["y"] ?? "?")" : String(arg.prefix(80))
        state.log(.exec, "Claude ▸ \(name.uppercased()) \(detail)")
        let r: [String: String]
        switch name {
        case "shell": r = await FullControl.shell(arg)
        case "applescript": r = FullControl.applescript(arg)
        case "screenshot": r = await FullControl.screenshot()
        case "type": r = FullControl.type(arg)
        case "key": r = FullControl.key(arg)
        case "click":
            let x = (body["x"] as? NSNumber)?.doubleValue ?? -1, y = (body["y"] as? NSNumber)?.doubleValue ?? -1
            r = x < 0 || y < 0 ? ["error": "need x and y"]
                : FullControl.click(x: x, y: y, double: body["double"] as? Bool ?? false, right: body["right"] as? Bool ?? false)
        default: r = ["error": "Unknown Full Control tool \(name)"]
        }
        if let e = r["error"] { state.log(.err, "Claude ▸ \(name): \(e)") }
        return r
    }

    // MARK: - Typing into the front app

    private func typeText(_ a: Action) -> String {
        let text = a.text ?? ""
        guard !text.isEmpty else { return "What should I type? Say: Jarvis, type, then the words." }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "the front app"
        let method = TextInserter.insert(text, driver: driver)
        state.log(.ok, "Typed \(text.count) chars into \(app) via \(method.rawValue)")
        if method == .clipboard {
            if !AXIsProcessTrusted() { FullControl.requestPermissions() }
            return "It's on the clipboard; press Command V to paste. To type straight into apps, allow Jarvis under Accessibility."
        }
        if a.submit == true {
            _ = FullControl.key("return")
            return "Typed and sent in \(app)."
        }
        return "Typed into \(app) and highlighted. I haven't sent it."
    }

    // MARK: - Mute and Stop

    private func setMuted(_ on: Bool, why: String) {
        guard on != muted else { return }
        if on {
            if session { session = false; state.session = false }
            inConversation = false
            pendingFollowUp = false
            listener.cancel()
            speaker.stop()
            muted = true
            state.phase = .idle
            state.log(.sys, "Muted (\(why)): not listening, not executing anything")
            flash(.done, "Muted", "Not listening and not executing anything. Unmute from the menu or press ⌥Space.")
            speaker.speak("Muted.")
        } else {
            muted = false
            state.log(.sys, "Unmuted (\(why))")
            flash(.done, "Unmuted", "Listening again.")
            resumeListening()
        }
        setIcon(listening: false)
    }

    /// Stops talking and listening; a command still running finishes silently.
    private func stopEverything(why: String) {
        runGeneration += 1
        inConversation = false
        pendingFollowUp = false
        speaker.stop()
        if state.phase == .listening { listener.cancel(); setIcon(listening: false) }
        state.phase = .idle
        state.log(.sys, "Stopped (\(why))")
        flash(.done, "Stopped", "")
        resumeListening()
    }

    // MARK: - Understanding a command, with memory

    /// Follow-ups first ("do that again", "close it"), then the parser with recent history.
    /// When the CPU guardrail blocks the local model, the command goes to Claude if it's reachable.
    private func understand(_ command: String) async throws -> (Action, String) {
        if let a = FollowUp.resolve(command, last: memory?.lastAction()) { return (a, "follow-up") }
        let history = (memory?.recent(4) ?? []).reversed().compactMap { e in e.action.map { "\(e.heard) → \($0.summary)" } }
        do {
            let (a, viaModel) = try await Brain.parse(command, model: model, history: Array(history))
            return (a, viaModel ? model : "instant rule")
        } catch BrainError.cpuBusy(let u) {
            let claudeReachable = bridge.claudeConnected ? true : await ClaudeCLI.signedIn()
            if claudeReachable {
                state.log(.sys, "CPU at \(Int(u))%: sending this to Claude instead of the local model")
                return (Action(action: "escalate", text: command), "CPU guardrail → Claude")
            }
            throw BrainError.cpuBusy(u)
        }
    }

    private func remember(_ a: Action) -> String {
        guard let memory else { return "My memory isn't available right now." }
        switch a.action {
        case "remember":
            memory.remember(a.text ?? "")
            state.log(.sys, "Remembered: \(a.text ?? "")")
            return "Got it. I'll remember that."
        case "recall":
            let facts = memory.facts()
            guard !facts.isEmpty else { return "You haven't asked me to remember anything yet." }
            facts.forEach { state.log(.sys, "Memory: \($0.text)") }
            let spoken = facts.suffix(5).map(\.text).joined(separator: ". ")
            return "Here's what I remember: \(spoken)." + (facts.count > 5 ? " And \(facts.count - 5) more in the console." : "")
        default:
            if a.text == "all" {
                memory.forgetAll()
                state.log(.sys, "Memory cleared")
                return "Done. I've forgotten everything."
            }
            return memory.forgetLastFact().map { "Forgotten: \($0)." } ?? "There's nothing to forget."
        }
    }

    /// "Look at my screen…": screenshot + on-device OCR. Claude gets the image and text; offline, Gemma gets the text.
    private func lookAtScreen(_ a: Action, command: String) async throws -> (String, String) {
        state.detail = "Looking at your screen…"
        let shot = await ScreenReader.capture()
        if let e = shot.error, shot.text.isEmpty { return (e, "nothing") }
        var c = context()
        c["screen_text"] = shot.text
        if !shot.labels.isEmpty { c["screen_labels"] = shot.labels.joined(separator: ", ") }
        if let p = shot.path { c["screenshot_path"] = p }
        let question = a.text ?? command
        if answerMode != "local" {
            if bridge.claudeConnected,
               let r = await bridge.ask(kind: "ask", text: question + " (A screenshot is at context.screenshot_path; its text is in context.screen_text.)",
                                        context: c, timeout: 120) {
                return (Self.spoken(r), "Claude (MCP) + screenshot")
            }
            if await ClaudeCLI.signedIn(),
               let r = try? await ClaudeCLI.ask("The user asked: \"\(question)\"\nText on their screen:\n\(shot.text.prefix(6000))",
                                                system: Self.claudeSystem, timeout: 120) {
                return (Self.spoken(r), "Claude (CLI) + screen text")
            }
        }
        if CPUGuard.busy {
            return ("Your Mac is busy right now, so I won't run the local model. Ask Claude, or try again in a moment.", "CPU guardrail")
        }
        let reply = try await Brain.chat([["role": "system", "content": Self.localSystem],
                                          ["role": "user", "content": "Text on the user's screen:\n\(shot.text.prefix(4000))\n\nIt looks like: \(shot.labels.joined(separator: ", "))\n\nQuestion: \(question)"]],
                                         model: model)
        return (Self.spoken(reply), "\(model) (offline, screen text)")
    }

    /// Memory over the bridge, for Claude and other agents.
    private func memoryOp(_ op: String, _ body: [String: Any]) -> [String: String] {
        guard let memory else { return ["error": "Memory isn't available"] }
        switch op {
        case "remember":
            guard let fact = body["fact"] as? String, !fact.isEmpty else { return ["error": "need fact"] }
            memory.remember(fact)
            state.log(.sys, "Remembered (from Claude): \(fact)")
            return ["result": "Remembered"]
        case "search":
            let q = body["query"] as? String ?? ""
            let facts = q.isEmpty ? memory.facts().map(\.text) : memory.relevantFacts(q, limit: 20).map(\.text)
            let reqs = (q.isEmpty ? memory.recent(10) : memory.searchRequests(q)).map { "\($0.date.formatted(date: .abbreviated, time: .shortened)) · \($0.heard) → \($0.result.prefix(160))" }
            return ["facts": facts.joined(separator: "\n"), "requests": reqs.joined(separator: "\n")]
        default:
            return ["error": "unknown memory operation \(op)"]
        }
    }

    // MARK: - Clap

    private func clapped() {
        guard clapEnabled, !muted, state.phase == .idle || state.phase == .done else { return }
        listener.cancel()
        state.log(.mic, "Clap detected")
        hideWork?.cancel()
        state.phase = .listening
        state.transcript = "Clap detected"
        state.detail = "Are you looking for something?"
        hud.show()
        speaker.speak("Are you looking for something? Clap detected.")
        listenAfterSpeaking()
    }

    /// Starts listening for a command once Jarvis stops talking.
    private func listenAfterSpeaking() {
        if speaker.isSpeaking {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.listenAfterSpeaking() }
            return
        }
        state.phase = .idle
        startListening()
    }

    private func status() -> [String: String] {
        var s = driver.currentTab()
        s["front_app"] = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        s["model"] = model
        s["answers"] = answerMode
        s["wake_word"] = wakeActive ? "listening for Hey Jarvis" : "off"
        s["session"] = session ? "on" : "off"
        s["full_control"] = fullControl ? "on (until \(fullControlUntil!.formatted(date: .omitted, time: .shortened)))" : "off"
        s["recent_log"] = state.entries.suffix(10).map { "\($0.time) \($0.kind.rawValue) \($0.text)" }.joined(separator: "\n")
        return s
    }

    private func page() -> [String: String] {
        var p = driver.currentTab()
        guard !p.isEmpty else { return ["error": "No browser tab open in \(driver.app.rawValue)"] }
        do { p["text"] = try driver.pageText() } catch { p["text_error"] = error.localizedDescription }
        return p
    }

    private func flash(_ phase: AppState.Phase, _ title: String, _ detail: String) {
        state.phase = phase
        state.transcript = title
        state.detail = detail
        hud.show()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state.phase != .listening, self.state.phase != .thinking else { return }
            self.state.phase = .idle
            if self.pinned || self.session {
                self.state.transcript = ""
                self.state.detail = ""
            } else {
                self.hud.hide()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(4, Double(detail.count) / 14), execute: work)
    }

    private func ms(since start: Date) -> String {
        "\(Int(Date().timeIntervalSince(start) * 1000)) ms"
    }

    private func actionJSON(_ a: Action) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(a)).map { String(decoding: $0, as: UTF8.self) } ?? a.action
    }

    private func say(_ text: String) {
        speaker.speak(text)
    }

    private func setIcon(listening: Bool) {
        let image = NSImage(systemSymbolName: muted ? "mic.slash" : listening ? "mic.fill" : "mic", accessibilityDescription: "Jarvis")
        image?.isTemplate = !listening
        statusItem.button?.image = listening ? image?.withSymbolConfiguration(.init(paletteColors: [.systemRed])) : image
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item("Listen  (⌥Space)", #selector(listenClicked)))
        sessionItem = item("Start Session", #selector(toggleSession))
        menu.addItem(sessionItem)
        fullControlItem = item("Give Claude Full Control (30 min)", #selector(toggleFullControl))
        menu.addItem(fullControlItem)
        menu.addItem(item("Connect Phone…", #selector(connectPhone)))
        followUpItem = item("Keep Listening After Replies", #selector(toggleFollowUp))
        menu.addItem(followUpItem)
        clapItem = item("Respond to Claps", #selector(toggleClap))
        menu.addItem(clapItem)
        menu.addItem(item("Teach My Clap…", #selector(teachClap)))
        strictItem = item("Wake Only on “Hey Jarvis”", #selector(toggleStrict))
        menu.addItem(strictItem)
        cpuItem = item("Skip Local Model When CPU Is Busy", #selector(toggleCPUGuard))
        menu.addItem(cpuItem)
        menu.addItem(.separator())
        muteItem = item("Mute Jarvis", #selector(toggleMute))
        menu.addItem(muteItem)
        menu.addItem(item("Stop", #selector(stopClicked)))
        wakeItem = NSMenuItem(title: "Hey Jarvis", action: nil, keyEquivalent: "")
        wakeItem.submenu = wakeMenu
        menu.addItem(wakeItem)
        menu.addItem(item("Type a Command…", #selector(typeCommand)))
        menu.addItem(.separator())

        let models = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        models.submenu = modelsMenu
        menu.addItem(models)

        let browsers = NSMenuItem(title: "Browser", action: nil, keyEquivalent: "")
        browsers.submenu = browserMenu
        menu.addItem(browsers)

        let answers = NSMenuItem(title: "Answers", action: nil, keyEquivalent: "")
        answers.submenu = answersMenu
        menu.addItem(answers)
        let voices = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        voices.submenu = voiceMenu
        menu.addItem(voices)
        speakItem = item("Speak Responses", #selector(toggleSpeak))
        menu.addItem(speakItem)
        pinItem = item("Keep Console Open", #selector(togglePinned))
        menu.addItem(pinItem)
        menu.addItem(item("Open Log File", #selector(openLog)))

        let recents = NSMenuItem(title: "Recent Commands", action: nil, keyEquivalent: "")
        recents.submenu = recentMenu
        menu.addItem(recents)

        menu.addItem(.separator())
        menu.addItem(item("Setup…", #selector(showSetup)))
        menu.addItem(item("Help…", #selector(showHelp)))
        menu.addItem(item("Quit Jarvis", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        speakItem.state = speak ? .on : .off
        pinItem.state = pinned ? .on : .off
        sessionItem.title = session ? "End Session" : "Start Session"
        fullControlItem.title = fullControl ? "Take Back Control from Claude" : "Give Claude Full Control (30 min)"
        clapItem.state = clapEnabled ? .on : .off
        followUpItem.state = followUpEnabled ? .on : .off
        strictItem.state = SpeechListener.strictWake ? .on : .off
        cpuItem.state = CPUGuard.enabled ? .on : .off
        cpuItem.title = "Skip Local Model When CPU Is Busy (now \(Int(CPUGuard.usage))%)"
        muteItem.title = muted ? "Unmute Jarvis" : "Mute Jarvis"
        setIcon(listening: state.phase == .listening)
        wakeItem.title = "Hey Jarvis: " + ["always": "Always", "apps": "With \(wakeApps.joined(separator: ", "))", "off": "Off"][wakeMode, default: "Off"]

        wakeMenu.removeAllItems()
        for (mode, title) in [("always", "Always Listen"), ("apps", "Only While These Apps Are Open:")] {
            let mi = item(title, #selector(pickWakeMode(_:)))
            mi.representedObject = mode
            mi.state = wakeMode == mode ? .on : .off
            wakeMenu.addItem(mi)
        }
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .compactMap(\.localizedName)
        for name in Set(wakeApps + running).sorted() {
            let mi = item(name, #selector(toggleWakeApp(_:)))
            mi.representedObject = name
            mi.indentationLevel = 1
            mi.state = wakeApps.contains(name) ? .on : .off
            wakeMenu.addItem(mi)
        }
        let off = item("Off", #selector(pickWakeMode(_:)))
        off.representedObject = "off"
        off.state = wakeMode == "off" ? .on : .off
        wakeMenu.addItem(off)

        answersMenu.removeAllItems()
        for (mode, title) in [("auto", "Auto: Claude When Connected, Else Offline"), ("claude", "Claude (Online)"), ("local", "Offline Only (\(model))")] {
            let mi = item(title, #selector(pickAnswerMode(_:)))
            mi.representedObject = mode
            mi.state = answerMode == mode ? .on : .off
            answersMenu.addItem(mi)
        }
        answersMenu.addItem(.separator())
        let link = NSMenuItem(title: bridge.claudeConnected ? "Claude: connected over MCP" : "Claude: no session connected", action: nil, keyEquivalent: "")
        link.isEnabled = false
        answersMenu.addItem(link)
        answersMenu.addItem(item("Sign In to Claude CLI (answers without a session)…", #selector(signInClaude)))
        answersMenu.addItem(item("Connect Claude Code (MCP)", #selector(connectClaude)))
        answersMenu.addItem(item("Start Claude Brain in Terminal…", #selector(startBrain)))
        answersMenu.addItem(item("Connect Google Antigravity (MCP)", #selector(connectAntigravity)))

        voiceMenu.removeAllItems()
        let using = NSMenuItem(title: "Speaking with: \(speaker.backend.rawValue)", action: nil, keyEquivalent: "")
        using.isEnabled = false
        voiceMenu.addItem(using)
        if speaker.backend != .studio {
            voiceMenu.addItem(item("Start Creator Studio Voice Server (Kokoro + Whisper)", #selector(startStudioVoice)))
        }
        whisperItem = item("Use Whisper for Better Accuracy" + (speaker.backend == .studio ? "" : " (needs the voice server)"), #selector(toggleWhisper))
        whisperItem.state = whisperEnabled ? .on : .off
        voiceMenu.addItem(whisperItem)
        voiceMenu.addItem(.separator())
        for v in Speaker.voices {
            let mi = item(v.label, #selector(pickVoice(_:)))
            mi.representedObject = v.id
            mi.state = speaker.voice == v.id ? .on : .off
            voiceMenu.addItem(mi)
        }

        modelsMenu.removeAllItems()
        let names = installedModels.contains(model) ? installedModels : [model] + installedModels
        for name in names {
            let mi = item(name + (installedModels.contains(name) ? "" : "  (not installed)"), #selector(pickModel(_:)))
            mi.representedObject = name
            mi.state = name == model ? .on : .off
            modelsMenu.addItem(mi)
        }
        modelsMenu.addItem(.separator())
        modelsMenu.addItem(item("Install \(Brain.defaultModel) in Terminal", #selector(pullModel)))
        Task { installedModels = await Brain.installedModels() } // fresh list for next open

        browserMenu.removeAllItems()
        for b in BrowserApp.allCases {
            let mi = item(b.rawValue, #selector(pickBrowser(_:)))
            mi.representedObject = b.rawValue
            mi.state = b == driver.app ? .on : .off
            browserMenu.addItem(mi)
        }

        recentMenu.removeAllItems()
        if recent.isEmpty { recentMenu.addItem(NSMenuItem(title: "None yet", action: nil, keyEquivalent: "")) }
        for cmd in recent {
            let mi = item(cmd, #selector(rerun(_:)))
            mi.representedObject = cmd
            recentMenu.addItem(mi)
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    @objc private func listenClicked() { hotKeyDown(); listener.holdOpen = false }

    @objc private func typeCommand() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Browser command"
        alert.informativeText = "Type it, or press your Dictation key and speak."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "open github and search for ollama"
        alert.accessoryView = field
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            let cmd = field.stringValue
            Task { await run(cmd) }
        }
    }

    @objc private func pickModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        model = name
        state.log(.sys, "Model → \(name)")
        Task { await Brain.warmUp(model: name) }
    }

    @objc private func pullModel() {
        let script = "tell application \"Terminal\"\nactivate\ndo script \"ollama pull \(Brain.defaultModel)\"\nend tell"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    @objc private func pickBrowser(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let b = BrowserApp(rawValue: raw) else { return }
        driver.app = b
        UserDefaults.standard.set(raw, forKey: "browser")
        state.log(.sys, "Browser → \(raw)")
    }

    @objc private func toggleSpeak() { speak.toggle() }

    @objc private func togglePinned() {
        pinned.toggle()
        if pinned { hud.show() } else if state.phase == .idle { hud.hide() }
    }

    @objc private func pickWakeMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        wakeMode = mode
        updateWake(reason: "menu")
    }

    @objc private func toggleWakeApp(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        wakeApps = wakeApps.contains(name) ? wakeApps.filter { $0 != name } : wakeApps + [name]
        wakeMode = "apps"
        updateWake(reason: "apps changed")
    }

    @objc private func toggleFullControl() {
        setFullControl(!fullControl, why: "menu")
    }

    // MARK: - Phone

    /// Serves the phone page on the Tailscale address while Tailscale is up; follows it if it changes.
    private func updatePhoneLink() {
        let addr = Tailnet.address()
        guard addr != bridge.phoneHost else { return }
        if let addr {
            bridge.startPhone(host: addr, port: PhoneLink.port, token: PhoneLink.token())
            state.log(.sys, "Phone link on at \(addr):\(PhoneLink.port) (Tailscale only) · menu → Connect Phone")
        } else if bridge.phoneHost != nil {
            bridge.stopPhone()
            state.log(.sys, "Phone link off (Tailscale stopped)")
        }
    }

    private func phoneState() -> [String: Any] {
        let status: String = muted ? "MUTED" : [.idle: "STANDBY", .listening: "LISTENING", .thinking: "PROCESSING", .done: "COMPLETE", .error: "FAULT"][state.phase] ?? "STANDBY"
        let tab = driver.currentTab()
        return [
            "status": status, "transcript": state.transcript, "detail": state.detail,
            "front_app": NSWorkspace.shared.frontmostApplication?.localizedName ?? "", "page_title": tab["page_title"] ?? "",
            "full_control": fullControl, "session": session,
            "log": state.entries.suffix(25).map { ["time": $0.time, "kind": $0.kind.rawValue, "text": $0.text] },
        ]
    }

    private func phoneScreen() async -> (Data?, String?) {
        guard !muted else { return (nil, "Jarvis is muted at the Mac.") }
        state.log(.exec, "Phone ▸ screenshot")
        let shot = await FullControl.screenshot()
        guard let path = shot["path"] else { return (nil, shot["error"] ?? "Screenshot failed") }
        return (PhoneLink.thumbnail(URL(fileURLWithPath: path)), nil)
    }

    /// The phone can mute and stop, but not unmute: that stays with the person at the Mac.
    private func phoneControl(_ name: String) -> String {
        switch name {
        case "mute":
            setMuted(true, why: "phone")
            return "Muted. Unmute at the Mac (menu or ⌥Space)."
        case "stop":
            stopEverything(why: "phone")
            return "Stopped."
        default:
            return "Unknown"
        }
    }

    @objc private func connectPhone() {
        updatePhoneLink()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        guard let host = bridge.phoneHost else {
            alert.messageText = "Turn on Tailscale first"
            alert.informativeText = """
            The phone page is only served over Tailscale, your private network, never the open internet.
            1. Open Tailscale on this Mac and sign in.
            2. Install Tailscale on your iPhone with the same account.
            3. Come back here: Connect Phone shows a QR code.
            """
            alert.runModal()
            return
        }
        let url = PhoneLink.url(host: host, token: PhoneLink.token())
        alert.messageText = "Connect your phone"
        alert.informativeText = "With Tailscale on, scan this with the iPhone camera, then Share → Add to Home Screen. Anyone with this link can send Jarvis commands, so keep it private."
        if let qr = PhoneLink.qrCode(url) { alert.accessoryView = NSImageView(image: qr) }
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Copy Link")
        alert.addButton(withTitle: "Reset Link")
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
        case .alertThirdButtonReturn:
            _ = PhoneLink.token(reset: true)
            bridge.stopPhone()
            updatePhoneLink()
            state.log(.sys, "Phone link reset: the old link no longer works")
            connectPhone()
        default:
            break
        }
    }

    @objc private func toggleFollowUp() {
        followUpEnabled.toggle()
        state.log(.sys, "Keep listening after replies: \(followUpEnabled ? "on" : "off")")
    }

    @objc private func toggleMute() { setMuted(!muted, why: "menu") }

    @objc private func stopClicked() { stopEverything(why: "menu") }

    @objc private func toggleStrict() {
        SpeechListener.strictWake.toggle()
        UserDefaults.standard.set(SpeechListener.strictWake, forKey: "strictWake")
        state.log(.sys, SpeechListener.strictWake ? "Wake word: only “Hey Jarvis”" : "Wake word: “Jarvis” alone also works")
    }

    @objc private func toggleCPUGuard() {
        CPUGuard.enabled.toggle()
        UserDefaults.standard.set(CPUGuard.enabled, forKey: "cpuGuard")
        state.log(.sys, "CPU guardrail \(CPUGuard.enabled ? "on (≥ \(Int(CPUGuard.threshold))%)" : "off")")
    }

    /// Listens for 5 seconds while the user claps, then sets the clap threshold from their claps.
    @objc private func teachClap() {
        guard !muted else { return flash(.error, "Jarvis is muted", "Unmute first.") }
        listener.cancel()
        flash(.listening, "Teach My Clap", "Clap three times now…")
        speaker.speak("Clap three times now.")
        Task {
            while speaker.isSpeaking { try? await Task.sleep(for: .milliseconds(200)) }
            do {
                let peaks = try await ClapCalibrator.record(seconds: 5)
                guard let threshold = ClapCalibrator.threshold(from: peaks) else {
                    flash(.error, "I didn't hear clear claps", "Try again a little closer to the Mac.")
                    speaker.speak("I didn't hear clear claps. Try again.")
                    state.phase = .idle
                    return resumeListening()
                }
                listener.clapMinPeak = threshold
                UserDefaults.standard.set(threshold, forKey: "clapMinPeak")
                state.log(.sys, "Clap learned: \(peaks.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: ", ")) → threshold \(String(format: "%.2f", threshold))")
                flash(.done, "Clap learned", "Softer sounds will be ignored now.")
                speaker.speak("Got it. I'll respond to claps like that.")
            } catch {
                flash(.error, "Couldn't use the microphone", error.localizedDescription)
            }
            state.phase = .idle
            resumeListening()
        }
    }

    @objc private func toggleClap() {
        clapEnabled.toggle()
        state.log(.sys, "Respond to claps: \(clapEnabled ? "on" : "off") (takes effect next time Jarvis listens)")
        if listener.isWaitingForWake { listener.cancel(); resumeListening() }
    }

    @objc private func toggleSession() {
        session ? endSession("from menu") : startSession()
    }

    @objc private func pickAnswerMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        answerMode = mode
        state.log(.sys, "Answers → \(mode)")
    }

    @objc private func signInClaude() {
        guard let cli = ClaudeCLI.path else { return flash(.error, "Claude CLI not found", "Install the Claude desktop app or Claude Code.") }
        let cmd = "'\(cli.replacingOccurrences(of: "'", with: "'\\''"))' auth login"
        _ = try? runAppleScript("tell application \"Terminal\"\nactivate\ndo script \"\(cmd.replacingOccurrences(of: "\"", with: "\\\""))\"\nend tell")
    }

    @objc private func connectClaude() {
        Task {
            do {
                let msg = try await ClaudeCLI.registerMCP()
                state.log(.sys, "Claude Code: \(msg)")
                flash(.done, "Claude connected", msg)
            } catch {
                state.log(.err, error.localizedDescription)
                flash(.error, "Couldn't connect Claude", error.localizedDescription)
            }
        }
    }

    /// Adds Jarvis to Antigravity's MCP config (~/.gemini/antigravity/mcp_config.json), keeping other servers.
    @objc private func connectAntigravity() {
        do {
            let msg = try AgentConfig.addJarvis(to: AgentConfig.antigravityURL)
            state.log(.sys, "Antigravity: \(msg)")
            flash(.done, "Antigravity connected", msg + " In Antigravity: Agent panel → MCP Servers → Refresh.")
        } catch {
            flash(.error, "Couldn't update Antigravity's MCP config", error.localizedDescription)
        }
    }

    /// Opens Terminal with a Claude Code session that serves Jarvis (signs in first if needed).
    @objc private func startBrain() {
        guard let cli = ClaudeCLI.path else { return flash(.error, "Claude CLI not found", "Install the Claude desktop app or Claude Code.") }
        Task {
            _ = try? await ClaudeCLI.registerMCP()
            let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let cmd = "cd \(q(Paths.support.path)) && \(q(cli)) \(q(ClaudeCLI.servePrompt))"
            let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            _ = try? runAppleScript("tell application \"Terminal\"\nactivate\ndo script \"\(esc)\"\nend tell")
            state.log(.sys, "Started a Claude brain session in Terminal")
        }
    }

    @objc private func startStudioVoice() {
        let msg = speaker.startStudioServer()
        state.log(.sys, msg)
        flash(.done, "Voice server", msg)
    }

    @objc private func toggleWhisper() {
        whisperEnabled.toggle()
        state.log(.sys, "Whisper second pass: \(whisperEnabled ? "on" : "off")")
    }

    @objc private func pickVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if id == "personal" {
            Task {
                let msg = await Speaker.requestPersonalVoice()
                state.log(.sys, "Personal Voice: \(msg)")
                guard Speaker.personalVoice != nil else { return flash(.error, "Personal Voice", msg) }
                speaker.voice = id
                UserDefaults.standard.set(id, forKey: "voice")
                speaker.speak("This is your Personal Voice.")
            }
            return
        }
        speaker.voice = id
        UserDefaults.standard.set(id, forKey: "voice")
        let name = Speaker.voices.first { $0.id == id }?.label ?? id
        state.log(.sys, "Voice → \(name)")
        speaker.speak("Voice set to \(name.components(separatedBy: " ·").first ?? name).")
    }

    @objc private func openLog() { NSWorkspace.shared.open(LogFile.url) }

    @objc private func rerun(_ sender: NSMenuItem) {
        guard let cmd = sender.representedObject as? String else { return }
        Task { await run(cmd) }
    }

    @objc private func showSetup() { setup.show() }

    @objc private func showHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Using Jarvis"
        alert.informativeText = """
        1. Install a model: ollama pull \(Brain.defaultModel)
        2. Chrome: View → Developer → Allow JavaScript from Apple Events
           (Safari: Develop → Allow JavaScript from Apple Events)
        3. Allow Microphone, Speech Recognition and Automation when macOS asks.

        Say “Hey Jarvis, open YouTube”. Or hold ⌥Space and speak, then let go.
        Say “Hey Jarvis, start session” to give several commands without the wake word; \
        “end session” to stop.

        Try: "open hacker news", "search for ollama models", "click sign in", \
        "type hello and press enter", "scroll down", "go to tab 2", \
        "what's this page about". Multi-step tasks are handed to Claude.
        """
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
