import Darwin
import Foundation

/// Guardrail: while the Mac's CPU is busy, don't start the local model (it would slow everything down
/// and answer slowly). Instant rules still work; questions and unknown commands go to Claude if connected.
enum CPUGuard {
    /// Percent of total CPU (all cores) above which the local model is skipped.
    static var threshold: Double = 85
    static var enabled = true
    /// Average total CPU use over the last few samples, 0–100.
    private(set) static var usage: Double = 0

    static var busy: Bool { enabled && usage >= threshold }

    private static var previous: [UInt32]?
    private static var window: [Double] = []
    private static var timer: Timer?

    static func start() {
        _ = sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            window.append(sample())
            if window.count > 3 { window.removeFirst() }
            usage = window.reduce(0, +) / Double(window.count)
        }
    }

    /// CPU use since the previous sample, from the kernel's per-state tick counters.
    static func sample() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard ok == KERN_SUCCESS else { return usage }
        let t = info.cpu_ticks // (user, system, idle, nice)
        let now = [t.0, t.1, t.2, t.3]
        defer { previous = now }
        guard let prev = previous else { return 0 }
        return usage(from: prev, to: now)
    }

    /// Busy share of the ticks between two samples (user, system, idle, nice), 0–100.
    static func usage(from a: [UInt32], to b: [UInt32]) -> Double {
        let d = zip(a, b).map { Double($1 &- $0) }
        let total = d.reduce(0, +)
        guard total > 0 else { return 0 }
        return (d[0] + d[1] + d[3]) / total * 100
    }
}
