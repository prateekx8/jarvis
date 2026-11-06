import AVFoundation
import NaturalLanguage

/// Speaks Jarvis's replies, one sentence at a time so long replies start quickly.
///
/// Backends, best first:
/// 1. Creator Studio's voice server (mlx-audio, OpenAI-compatible, port 8765): Kokoro on the GPU, plus Whisper.
/// 2. Jarvis's own Kokoro server (tts/server.py, port 8766), started on demand.
/// 3. The macOS voice.
/// "My Personal Voice" (Apple Personal Voice, trained in System Settings) can be picked instead.
/// After a failure Jarvis falls back for that reply and reconnects in the background, so it never gets
/// stuck on the robotic voice.
@MainActor
final class Speaker {
    enum Backend: String {
        case studio = "Creator Studio voice server"
        case own = "Jarvis voice server"
        case system = "macOS voice"
    }

    static let voices: [(id: String, label: String)] = [
        ("bm_george", "George · British (Jarvis)"), ("bm_fable", "Fable · British"), ("bm_daniel", "Daniel · British"),
        ("bm_lewis", "Lewis · British"), ("am_michael", "Michael · American"), ("af_heart", "Heart · American female"),
        ("bf_emma", "Emma · British female"), ("personal", "My Personal Voice (Apple)"), ("system", "macOS voice (not neural)"),
    ]
    static let defaultVoice = "bm_george"

    nonisolated static let studioURL = ProcessInfo.processInfo.environment["VOICE_URL"] ?? "http://127.0.0.1:8765"
    static let ownPort = 8766
    static let kokoroModel = "mlx-community/Kokoro-82M-bf16"
    /// Creator Studio's voice server, started from the menu when it isn't running.
    static var studioScript: URL {
        URL(fileURLWithPath: UserDefaults.standard.string(forKey: "studioVoiceScript")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("DEV/Workspace/creator-studio/services/voice/run.sh").path)
    }

    var voice = defaultVoice
    var onLog: (String) -> Void = { _ in }
    private(set) var backend: Backend = .system
    var neuralReady: Bool { backend != .system }

    private var ownURL: String { "http://127.0.0.1:\(Self.ownPort)" }
    private var server: Process?
    private var refreshing = false
    private var lastRefresh = Date.distantPast
    private var timer: Timer?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private let synth = AVSpeechSynthesizer()
    private var generation = 0
    private var fetching = false
    private var queued = 0

    var isSpeaking: Bool { fetching || queued > 0 || synth.isSpeaking }

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    // MARK: - Backends

    func start() async {
        await refresh(announce: true)
        timer?.invalidate()
        // Every minute: move up to a better backend if one came back (e.g. Creator Studio's server started).
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(announce: false) }
        }
    }

    func refresh(announce: Bool) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        lastRefresh = Date()
        let old = backend
        if await Self.studioUp() {
            backend = .studio
        } else if await ownHealthy() {
            backend = .own
        } else if await startOwn() {
            backend = .own
        } else {
            backend = .system
        }
        if announce || backend != old {
            onLog("Voice: \(backend.rawValue) · \(Self.voices.first { $0.id == voice }?.label ?? voice)")
        }
    }

    /// Creator Studio's mlx-audio server answers the OpenAI-style /v1/models.
    static func studioUp() async -> Bool {
        var req = URLRequest(url: URL(string: studioURL + "/v1/models")!)
        req.timeoutInterval = 1.5
        return (try? await URLSession.shared.data(for: req)).map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
    }

    private func ownHealthy() async -> Bool {
        var req = URLRequest(url: URL(string: ownURL + "/health")!)
        req.timeoutInterval = 1
        return (try? await URLSession.shared.data(for: req)).map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
    }

    /// Starts tts/server.py (installed by Setup) on port 8766 and waits for it to load.
    private func startOwn() async -> Bool {
        if server?.isRunning != true {
            guard let python = Paths.installedPython, let models = Paths.installedModels, let script = Paths.serverScript else {
                return false
            }
            let p = Process()
            p.executableURL = python
            p.arguments = [script.path]
            p.environment = ["JARVIS_TTS_MODELS": models.path, "JARVIS_TTS_PORT": String(Self.ownPort), "PATH": "/usr/bin:/bin"]
            p.currentDirectoryURL = models.deletingLastPathComponent()
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return false }
            server = p
        }
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(500))
            if await ownHealthy() { return true }
        }
        return false
    }

    /// Starts Creator Studio's voice server (mlx-audio: Kokoro + Whisper) if it's installed.
    func startStudioServer() -> String {
        let script = Self.studioScript
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            return "Creator Studio's voice server isn't at \(script.path)."
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        p.currentDirectoryURL = script.deletingLastPathComponent()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "Couldn't start it: \(error.localizedDescription)" }
        Task {
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                if await Self.studioUp() { await refresh(announce: true); return }
            }
        }
        return "Starting Creator Studio's voice server…"
    }

    func shutdown() {
        server?.terminate()
    }

    // MARK: - Personal Voice

    static var personalVoice: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices().first { $0.voiceTraits.contains(.isPersonalVoice) }
    }

    /// Asks macOS for access to the user's Personal Voice; returns a sentence for the user.
    static func requestPersonalVoice() async -> String {
        let status = await withCheckedContinuation { cont in
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { cont.resume(returning: $0) }
        }
        switch status {
        case .authorized:
            return personalVoice == nil
                ? "Access granted, but no Personal Voice is trained yet: System Settings → Accessibility → Personal Voice."
                : "Using your Personal Voice."
        case .denied: return "Personal Voice access is off: System Settings → Privacy & Security → Personal Voice → Jarvis."
        case .unsupported: return "Personal Voice isn't supported on this Mac."
        default: return "Personal Voice access wasn't decided."
        }
    }

    // MARK: - Speaking

    func speak(_ text: String) {
        stop()
        let g = generation
        let sentences = Self.sentences(text)
        if voice == "system" { return speakSystem(text) }
        if voice == "personal" { return speakSystem(text, voice: Self.personalVoice) }
        guard backend != .system else {
            if Date().timeIntervalSince(lastRefresh) > 20 { Task { await refresh(announce: false) } }
            return speakSystem(text)
        }
        fetching = true
        Task {
            defer { if g == self.generation { self.fetching = false } }
            for (i, sentence) in sentences.enumerated() {
                guard g == generation else { return }
                do {
                    let buffer = try await synthesize(sentence)
                    guard g == generation else { return }
                    play(buffer, generation: g)
                } catch {
                    guard g == generation else { return }
                    onLog("\(backend.rawValue) failed (\(error.localizedDescription)); macOS voice for now, reconnecting")
                    backend = .system
                    Task { await refresh(announce: true) }
                    return speakSystem(sentences[i...].joined(separator: " "))
                }
            }
        }
    }

    func stop() {
        generation += 1
        fetching = false
        queued = 0
        player.stop()
        synth.stopSpeaking(at: .immediate)
    }

    private func play(_ buffer: AVAudioPCMBuffer, generation g: Int) {
        if !engine.isRunning {
            do { try engine.start() } catch { return onLog("Audio output: \(error.localizedDescription)") }
        }
        queued += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, g == self.generation else { return }
                self.queued -= 1
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func synthesize(_ text: String) async throws -> AVAudioPCMBuffer {
        switch backend {
        case .studio: return try await synthesizeStudio(text)
        default: return try await synthesizeOwn(text)
        }
    }

    /// Creator Studio's mlx-audio: OpenAI-style /v1/audio/speech returning a WAV.
    private func synthesizeStudio(_ text: String) async throws -> AVAudioPCMBuffer {
        var req = URLRequest(url: URL(string: Self.studioURL + "/v1/audio/speech")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.kokoroModel, "input": text, "voice": voice,
            "lang_code": voice.hasPrefix("b") ? "b" : "a", "speed": 1.0, "response_format": "wav",
        ] as [String: Any])
        req.timeoutInterval = 30 // the first call loads the model
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 44 else {
            throw NSError(domain: "Voice", code: 1, userInfo: [NSLocalizedDescriptionKey: "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"])
        }
        return try decodeWAV(data)
    }

    /// Jarvis's own server: raw float32 mono PCM at 24 kHz.
    private func synthesizeOwn(_ text: String) async throws -> AVAudioPCMBuffer {
        var req = URLRequest(url: URL(string: ownURL + "/tts")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "voice": voice])
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, data.count >= 4 else {
            throw NSError(domain: "Voice", code: 1, userInfo: [NSLocalizedDescriptionKey: String(decoding: data.prefix(200), as: UTF8.self)])
        }
        let frames = data.count / 4
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            buffer.floatChannelData![0].update(from: raw.bindMemory(to: Float.self).baseAddress!, count: frames)
        }
        return buffer
    }

    /// Any WAV → a buffer in the player's format (24 kHz mono float).
    private func decodeWAV(_ data: Data) throws -> AVAudioPCMBuffer {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-tts-\(UUID().uuidString).wav")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        guard let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "Voice", code: 2, userInfo: [NSLocalizedDescriptionKey: "empty audio"])
        }
        try file.read(into: src)
        if file.processingFormat == format { return src }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw NSError(domain: "Voice", code: 3, userInfo: [NSLocalizedDescriptionKey: "can't convert audio"])
        }
        let ratio = format.sampleRate / file.processingFormat.sampleRate
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(src.frameLength) * ratio) + 1024)!
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return src
        }
        if let error { throw error }
        return out
    }

    private func speakSystem(_ text: String, voice: AVSpeechSynthesisVoice? = nil) {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice ?? Self.systemVoice
        u.rate = 0.5
        synth.speak(u)
    }

    /// Best installed British English voice, else the default.
    private static let systemVoice: AVSpeechSynthesisVoice? = {
        let gb = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-GB" }
        return gb.max { ($0.quality.rawValue, $0.name == "Daniel" ? 1 : 0) < ($1.quality.rawValue, $1.name == "Daniel" ? 1 : 0) }
            ?? AVSpeechSynthesisVoice(language: "en-GB")
    }()

    static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            return true
        }
        return out.isEmpty ? [text] : out
    }
}

/// Whisper (large-v3-turbo) through Creator Studio's voice server: a more accurate second pass over a
/// command Apple's recognizer already heard.
enum Whisper {
    static let model = ProcessInfo.processInfo.environment["WHISPER_MODEL"] ?? "mlx-community/whisper-large-v3-turbo-asr-fp16"

    static func transcribe(_ wav: URL, timeout: TimeInterval = 8) async throws -> String {
        let boundary = "jarvis-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: Speaker.studioURL + "/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        req.httpBody = multipart(boundary: boundary, fields: ["model": model, "language": "en", "response_format": "json"],
                                 file: try Data(contentsOf: wav), filename: wav.lastPathComponent)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = obj["text"] as? String
        else { throw NSError(domain: "Whisper", code: 1, userInfo: [NSLocalizedDescriptionKey: String(decoding: data.prefix(200), as: UTF8.self)]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func multipart(boundary: String, fields: [String: String], file: Data, filename: String) -> Data {
        var body = Data()
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
