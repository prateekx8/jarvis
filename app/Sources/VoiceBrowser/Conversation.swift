import Foundation

/// Conversation mode: after a spoken reply, Jarvis listens for a follow-up (no "Hey Jarvis") for a few seconds,
/// and keeps follow-up questions with whoever answered last (Claude or the local model).
enum Conversation {
    /// Listen for a follow-up after this command?
    static func shouldFollowUp(source: AppDelegate.Source, enabled: Bool, inSession: Bool, muted: Bool, stopped: Bool) -> Bool {
        source == .voice && enabled && !inSession && !muted && !stopped
    }

    /// A follow-up question goes to the engine that answered the previous one, unless the user picked one.
    static func sticky(_ a: Action, inConversation: Bool, lastEngine: String) -> Action {
        guard inConversation, a.action == "ask", a.engine == nil, lastEngine.hasPrefix("Claude") else { return a }
        var b = a
        b.engine = "claude"
        return b
    }
}
