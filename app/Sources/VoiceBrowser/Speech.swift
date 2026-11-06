import AVFoundation
import Speech

/// On-device speech recognition (the same engine as macOS Dictation).
///
/// Two ways in:
/// - `start()`: capture a command right away (hotkey / menu).
/// - `startWake()`: listen continuously for "Hey Jarvis"; whatever follows it is the command.
/// Either way the command ends on a pause, or when `stop()` is called (push-to-talk release).
final class SpeechListener {
    var onPartial: (String) -> Void = { _ in }
    /// The command text, and (when `recordForWhisper`) a WAV of the command for a second, more accurate pass.
    var onFinal: (String, URL?) -> Void = { _, _ in }
    var recordForWhisper = false
    let recorder = AudioRecorder()
    /// Microphone level 0...1, about 20 times a second while listening.
    var onLevel: (Float) -> Void = { _ in }
    /// The wake word was heard; listening continues for the command.
    var onWake: () -> Void = {}
    /// A hand clap was heard while waiting for the wake word.
    var onClap: () -> Void = {}
    var clapEnabled = true
    /// Minimum clap loudness (0–1); set by "Teach My Clap".
    var clapMinPeak: Float = ClapDetector.defaultMinPeak
    private let clap = ClapDetector()
    /// While true (hotkey held down), pauses don't end listening.
    var holdOpen = false

    /// "Jarvis", optionally after "hey"/"ok", plus spellings the recognizer commonly produces.
    /// Strict (default): only "hey/ok/hi Jarvis" wakes Jarvis, so "Jarvis" in normal talk doesn't trigger it.
    static var strictWake = true
    static var wakeRegex: NSRegularExpression { strictWake ? strictRegex : looseRegex }
    private static let strictRegex = try! NSRegularExpression(
        pattern: #"\b(?:hey|hi|ok|okay)[ ,]+(?:jarvis|jarvas|jarves|jervis|javis)\b[ ,.!?]*"#, options: [.caseInsensitive])
    private static let looseRegex = try! NSRegularExpression(
        pattern: #"\b(?:(?:hey|hi|ok|okay|yo)[ ,]+)?(?:jarvis|jarvas|jarves|jervis|javis)\b[ ,.!?]*"#, options: [.caseInsensitive])

    private enum Mode { case off, wake, command }
    private var mode = Mode.off
    /// True once the command began after a wake word (vs. started directly).
    private var woke = false
    private var session = UUID()

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timer: Timer?
    private var recycle: Timer?
    private var latest = ""

    var isWaitingForWake: Bool { mode == .wake }

    static func authorize(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            AVCaptureDevice.requestAccess(for: .audio) { mic in
                DispatchQueue.main.async { done(status == .authorized && mic) }
            }
        }
    }

    func start() throws { try begin(.command) }

    func startWake() throws { try begin(.wake) }

    /// Stop capturing audio and deliver the command once the recognizer settles.
    func stop() {
        guard mode == .command else { return }
        stopAudio()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in self?.deliver() }
    }

    func cancel() {
        mode = .off
        session = UUID() // ignore callbacks from the old recognition task
        timer?.invalidate()
        recycle?.invalidate()
        stopAudio()
        task?.cancel()
        task = nil
    }

    private func begin(_ newMode: Mode) throws {
        cancel()
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "Speech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognition isn't available. Turn on Dictation in System Settings → Keyboard."])
        }
        latest = ""
        recorder.reset(rate: engine.inputNode.outputFormat(forBus: 0).sampleRate)
        woke = false

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = false
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.contextualStrings = ["Jarvis", "Hey Jarvis"]
        request = req

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        var lastLevel = Date.distantPast
        let listenForClaps = newMode == .wake && clapEnabled
        let clap = self.clap
        clap.minPeak = clapMinPeak
        let recorder = self.recorder
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buf, _ in
            req.append(buf)
            if let ch = buf.floatChannelData?[0] { recorder.append(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength))) }
            if listenForClaps, let ch = buf.floatChannelData?[0],
               clap.feed(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength))) {
                DispatchQueue.main.async { if self?.mode == .wake { self?.onClap() } }
            }
            guard Date().timeIntervalSince(lastLevel) > 0.05, let samples = buf.floatChannelData?[0], buf.frameLength > 0 else { return }
            lastLevel = Date()
            var sum: Float = 0
            for i in 0..<Int(buf.frameLength) { sum += samples[i] * samples[i] }
            let db = 20 * log10(max(sqrt(sum / Float(buf.frameLength)), 1e-6))
            let level = min(max((db + 50) / 40, 0), 1)
            DispatchQueue.main.async { self?.onLevel(level) }
        }
        engine.prepare()
        try engine.start()

        mode = newMode
        let current = session
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.session == current, self.mode != .off else { return }
                if let result {
                    self.handle(result.bestTranscription.formattedString, final: result.isFinal)
                } else if error != nil {
                    self.mode == .wake ? self.restartWake() : self.deliver()
                }
            }
        }

        if newMode == .command {
            arm(6) // nothing said at all
        } else {
            // Start a fresh recognition task now and then so the transcript stays short.
            recycle = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in self?.restartWake() }
        }
    }

    private func handle(_ text: String, final: Bool) {
        if mode == .wake {
            guard Self.wakeMatch(in: text) != nil else {
                if final { restartWake() }
                return
            }
            mode = .command
            woke = true
            recorder.markStart(secondsBack: 2.5) // include "Hey Jarvis …" said just before
            recycle?.invalidate()
            onWake()
        }
        latest = command(from: text)
        onPartial(latest)
        if final { return deliver() }
        if engine.isRunning { arm(latest.isEmpty ? 5 : 1.3) }
    }

    /// The text after the last wake phrase ("hey jarvis open youtube" -> "open youtube").
    private func command(from text: String) -> String {
        guard woke, let r = Self.wakeMatch(in: text) else { return text }
        return String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    private static func wakeMatch(in text: String) -> Range<String.Index>? {
        let matches = wakeRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.last.flatMap { Range($0.range, in: text) }
    }

    private func restartWake() {
        cancel()
        // Small delay so a persistent error can't spin.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.mode == .off else { return }
            try? self.startWake()
        }
    }

    private func arm(_ seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.holdOpen { self.arm(seconds) } else { self.stop() }
        }
    }

    private func deliver() {
        guard mode == .command else { return }
        let text = latest
        let wav = recordForWhisper && !text.isEmpty ? recorder.write(to: Paths.support.appendingPathComponent("last-command.wav")) : nil
        cancel()
        onFinal(text, wav)
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        onLevel(0)
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
    }
}

/// The last ~30 s of microphone audio (first channel), so a finished command can be saved for Whisper.
final class AudioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var start = 0
    private(set) var sampleRate: Double = 48000

    func reset(rate: Double) {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
        start = 0
        sampleRate = rate > 0 ? rate : 48000
    }

    func append(_ p: UnsafeBufferPointer<Float>) {
        lock.lock(); defer { lock.unlock() }
        samples.append(contentsOf: p)
        let cap = Int(sampleRate * 30)
        if samples.count > cap {
            let drop = samples.count - cap
            samples.removeFirst(drop)
            start = max(0, start - drop)
        }
    }

    /// The command starts this many seconds before now.
    func markStart(secondsBack: Double) {
        lock.lock(); defer { lock.unlock() }
        start = max(0, samples.count - Int(sampleRate * secondsBack))
    }

    var seconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count - start) / sampleRate
    }

    /// Writes the command (from the start mark) as 16-bit mono WAV; nil if under 0.3 s.
    func write(to url: URL) -> URL? {
        lock.lock()
        let slice = Array(samples[min(start, samples.count)...])
        let rate = sampleRate
        lock.unlock()
        guard Double(slice.count) > rate * 0.3,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(slice.count)) else { return nil }
        buf.frameLength = AVAudioFrameCount(slice.count)
        slice.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: slice.count) }
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buf)
            return url
        } catch {
            return nil
        }
    }
}
