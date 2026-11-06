import AVFoundation

/// Detects a hand clap in the microphone stream: a sudden, sharp peak well above the background
/// noise that dies away within ~60 ms (speech and music stay loud for longer, so they don't count).
/// Fed one buffer at a time (~21 ms at 48 kHz) from the audio thread.
final class ClapDetector {
    /// Default minimum peak (0–1). High enough that soft sounds (typing, a cup on the desk) don't count.
    static let defaultMinPeak: Float = 0.45
    /// Minimum peak amplitude (0–1) for a clap.
    var minPeak: Float = ClapDetector.defaultMinPeak
    /// Seconds to ignore after a clap.
    var cooldown: TimeInterval = 3

    private var floor: Float = 0.01
    private var candidate: (rms: Float, buffers: Int)?
    private var lastClap = Date.distantPast

    /// Returns true when this buffer completes a clap.
    func feed(_ samples: UnsafeBufferPointer<Float>, now: Date = Date()) -> Bool {
        guard !samples.isEmpty else { return false }
        var sum: Float = 0
        var peak: Float = 0
        for s in samples {
            sum += s * s
            peak = max(peak, abs(s))
        }
        let rms = (sum / Float(samples.count)).squareRoot()

        if var c = candidate {
            c.buffers += 1
            if rms < c.rms * 0.35 {          // died away quickly: a clap
                candidate = nil
                floor = floor * 0.9 + rms * 0.1
                guard now.timeIntervalSince(lastClap) > cooldown else { return false }
                lastClap = now
                return true
            }
            candidate = c.buffers >= 3 ? nil : c // still loud after ~60 ms: speech, music, a bang that rings
            return false
        }

        if peak > minPeak, peak > floor * 12, peak / max(rms, 1e-6) > 3 {
            candidate = (rms, 0)
        } else {
            floor = floor * 0.95 + rms * 0.05 // adapt to the room
        }
        return false
    }

    /// Convenience for tests.
    func feed(_ samples: [Float], now: Date = Date()) -> Bool {
        samples.withUnsafeBufferPointer { feed($0, now: now) }
    }
}

/// "Teach My Clap": listens for a few seconds while the user claps, and picks a threshold from their
/// claps so quieter sounds are ignored.
enum ClapCalibrator {
    /// Peaks of sharp transients heard, at most one per 0.3 s, loudest first.
    static func record(seconds: TimeInterval) async throws -> [Float] {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let collector = PeakCollector()
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in
            guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return }
            collector.add(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
        }
        engine.prepare()
        try engine.start()
        try await Task.sleep(for: .seconds(seconds))
        engine.stop()
        input.removeTap(onBus: 0)
        return collector.peaks
    }

    /// Threshold from the user's claps: 60% of the median of their three loudest, within sane bounds.
    static func threshold(from peaks: [Float]) -> Float? {
        let top = Array(peaks.sorted(by: >).prefix(3))
        guard top.count >= 2 else { return nil }
        let median = top.sorted()[top.count / 2]
        return min(max(median * 0.6, 0.15), 0.9)
    }
}

/// Collects transient peaks from the audio thread.
final class PeakCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [(Date, Float)] = []

    func add(_ samples: UnsafeBufferPointer<Float>, now: Date = Date()) {
        var peak: Float = 0, sum: Float = 0
        for v in samples { peak = max(peak, abs(v)); sum += v * v }
        let rms = (sum / Float(max(samples.count, 1))).squareRoot()
        guard peak > 0.08, peak / max(rms, 1e-6) > 3 else { return }
        lock.lock(); defer { lock.unlock() }
        if let last = found.last, now.timeIntervalSince(last.0) < 0.3 {
            if peak > last.1 { found[found.count - 1] = (last.0, peak) }
        } else {
            found.append((now, peak))
        }
    }

    var peaks: [Float] {
        lock.lock(); defer { lock.unlock() }
        return found.map(\.1).sorted(by: >)
    }
}
