import AppKit
import Combine
import SwiftUI

struct LogEntry: Identifiable {
    enum Kind: String {
        case sys = "SYS", mic = "MIC", heard = "HEARD", parse = "PARSE", exec = "EXEC", ok = "OK", err = "FAULT"
    }
    let id = UUID()
    let date = Date()
    let kind: Kind
    let text: String

    var time: String { Self.clock.string(from: date) }
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

/// Appends every log line to ~/Library/Logs/Jarvis.log.
enum LogFile {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Jarvis.log")

    static func append(_ e: LogEntry) {
        let line = "\(ISO8601DateFormatter().string(from: e.date)) \(e.kind.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)) \(e.text)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

final class AppState: ObservableObject {
    enum Phase { case idle, listening, thinking, done, error }
    @Published var phase: Phase = .idle
    @Published var transcript = ""
    @Published var detail = ""
    /// Microphone level, 0...1.
    @Published var level: Float = 0
    @Published var entries: [LogEntry] = []
    @Published var pinned = false
    @Published var session = false
    @Published var fullControl = false
    @Published var muted = false

    func log(_ kind: LogEntry.Kind, _ text: String) {
        let e = LogEntry(kind: kind, text: text)
        entries.append(e)
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
        LogFile.append(e)
    }
}

// MARK: - J.A.R.V.I.S.-style console

private enum Jarvis {
    static let cyan = Color(red: 0.25, green: 0.88, blue: 1.0)
    static let amber = Color(red: 1.0, green: 0.62, blue: 0.24)
    static let green = Color(red: 0.35, green: 1.0, blue: 0.7)
    static let mono = Font.system(size: 10.5, design: .monospaced)

    static func color(_ kind: LogEntry.Kind) -> Color {
        switch kind {
        case .err: return amber
        case .ok: return green
        case .heard: return .white
        case .sys: return cyan.opacity(0.6)
        default: return cyan
        }
    }
}

/// Concentric rotating rings; the core pulses with the microphone level.
struct ArcReactor: View {
    let phase: AppState.Phase
    let level: Float
    let color: Color

    var body: some View {
        let speed: Double = switch phase {
        case .thinking: 300
        case .listening: 90
        default: 25
        }
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().stroke(color.opacity(0.18), lineWidth: 1)
                Circle()
                    .stroke(color.opacity(0.55), style: StrokeStyle(lineWidth: 4, dash: [1.5, 4.5]))
                    .padding(3)
                    .rotationEffect(.degrees(t * speed * 0.4))
                Circle()
                    .trim(from: 0, to: 0.68)
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .padding(9)
                    .rotationEffect(.degrees(t * speed))
                Circle()
                    .trim(from: 0.1, to: 0.32)
                    .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .padding(14)
                    .rotationEffect(.degrees(-t * speed * 1.6))
                Circle()
                    .fill(RadialGradient(colors: [.white, color, color.opacity(0)], center: .center, startRadius: 0, endRadius: 12))
                    .padding(19)
                    .scaleEffect(1 + CGFloat(level) * 0.9)
                    .shadow(color: color, radius: 6 + CGFloat(level) * 10)
            }
        }
        .frame(width: 62, height: 62)
    }
}

/// Thin L-shaped brackets in each corner.
struct CornerBrackets: Shape {
    var length: CGFloat = 14

    func path(in r: CGRect) -> Path {
        var p = Path()
        for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0),
                               (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            p.move(to: CGPoint(x: x + dx * length, y: y))
            p.addLine(to: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: x, y: y + dy * length))
        }
        return p
    }
}

struct HUDView: View {
    @ObservedObject var state: AppState

    private var accent: Color { state.phase == .error ? Jarvis.amber : Jarvis.cyan }

    private var status: String {
        switch state.phase {
        case .idle: return state.muted ? "MUTED" : "STANDBY"
        case .listening: return "LISTENING"
        case .thinking: return "PROCESSING"
        case .done: return "COMPLETE"
        case .error: return "FAULT"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                ArcReactor(phase: state.phase, level: state.level, color: accent)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("J.A.R.V.I.S.").font(.system(size: 10, weight: .heavy, design: .monospaced)).tracking(3)
                        Text("// ASSISTANT").font(.system(size: 10, design: .monospaced)).tracking(1.5).opacity(0.6)
                        Spacer()
                        if state.fullControl {
                            Text("CLAUDE · FULL CONTROL")
                                .font(.system(size: 9, weight: .heavy, design: .monospaced)).tracking(1.2)
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color(red: 1.0, green: 0.62, blue: 0.24), in: RoundedRectangle(cornerRadius: 3))
                        }
                        if state.session {
                            Text("SESSION")
                                .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.5)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(accent.opacity(0.7), lineWidth: 1))
                        }
                        Circle().fill(accent).frame(width: 6, height: 6).shadow(color: accent, radius: 4)
                        Text(status).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2)
                    }
                    .foregroundStyle(accent)

                    Text(state.transcript.isEmpty ? "Awaiting command…" : state.transcript)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(state.transcript.isEmpty ? .white.opacity(0.45) : .white)
                        .lineLimit(2)

                    if !state.detail.isEmpty {
                        Text(state.detail)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(accent.opacity(0.85))
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Rectangle()
                .fill(LinearGradient(colors: [accent.opacity(0), accent.opacity(0.6), accent.opacity(0)], startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(state.entries.suffix(state.pinned ? 14 : 6)) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(e.time).foregroundStyle(Jarvis.cyan.opacity(0.4))
                        Text(e.kind.rawValue).foregroundStyle(Jarvis.color(e.kind)).frame(width: 40, alignment: .leading)
                        Text(e.text).foregroundStyle(.white.opacity(0.82)).lineLimit(2)
                    }
                    .font(Jarvis.mono)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: state.entries.count)
        }
        .padding(16)
        .frame(width: 540, alignment: .leading)
        .background(
            ZStack {
                Color(red: 0.01, green: 0.05, blue: 0.08).opacity(0.88)
                LinearGradient(colors: [accent.opacity(0.14), .clear], startPoint: .top, endPoint: .center)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(accent.opacity(0.35), lineWidth: 1))
        .overlay(CornerBrackets().stroke(accent, lineWidth: 2).padding(-3))
        .shadow(color: accent.opacity(0.35), radius: 14)
        .padding(20) // room for the glow
        .environment(\.colorScheme, .dark)
    }
}

/// Floating, non-activating console in the top-right corner. Never steals focus from the browser.
final class HUD {
    private let panel: NSPanel
    private let host: NSHostingView<HUDView>
    private var sub: AnyCancellable?
    private var visible = false

    init(state: AppState) {
        host = NSHostingView(rootView: HUDView(state: state))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 200),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = host
        // Resize to fit whenever the log or text changes.
        sub = state.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            guard let self, self.visible else { return }
            self.layout()
        }
    }

    func show() {
        visible = true
        layout()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hide() {
        visible = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 },
                                             completionHandler: { [panel] in panel.orderOut(nil) })
    }

    private func layout() {
        let size = host.fittingSize
        guard let f = NSScreen.main?.visibleFrame else { return }
        panel.setFrame(NSRect(x: f.maxX - size.width, y: f.maxY - size.height, width: size.width, height: size.height), display: true)
    }
}
