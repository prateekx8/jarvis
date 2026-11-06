import Foundation
import SQLite3

/// Jarvis's memory, in SQLite: every request with its result, and facts the user asked it to remember.
/// Used for follow-ups ("do that again", "close it"), as history for the local model, and as context for Claude.
final class Memory {
    struct Entry: Equatable {
        let id: Int64
        let date: Date
        let source: String
        let heard: String
        let action: Action?
        let result: String
        let engine: String
        let ok: Bool
    }

    struct Fact: Equatable {
        let id: Int64
        let date: Date
        let text: String
    }

    static let defaultURL = Paths.support.appendingPathComponent("memory.sqlite")
    private var db: OpaquePointer?

    init(url: URL = Memory.defaultURL) throws {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw err("Couldn't open memory database at \(url.path)")
        }
        try exec("""
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS requests (
            id INTEGER PRIMARY KEY, ts REAL NOT NULL, source TEXT NOT NULL, heard TEXT NOT NULL,
            action TEXT, result TEXT NOT NULL DEFAULT '', engine TEXT NOT NULL DEFAULT '',
            context TEXT NOT NULL DEFAULT '{}', ok INTEGER NOT NULL DEFAULT 1);
        CREATE INDEX IF NOT EXISTS requests_ts ON requests(ts);
        CREATE TABLE IF NOT EXISTS facts (id INTEGER PRIMARY KEY, ts REAL NOT NULL, text TEXT NOT NULL UNIQUE);
        """)
    }

    deinit { sqlite3_close(db) }

    // MARK: Requests

    @discardableResult
    func log(source: String, heard: String, action: Action?, result: String, engine: String,
             context: [String: String] = [:], ok: Bool = true, at date: Date = Date()) -> Int64 {
        let actionJSON = action.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        let ctx = (try? JSONSerialization.data(withJSONObject: context)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        run("INSERT INTO requests (ts, source, heard, action, result, engine, context, ok) VALUES (?,?,?,?,?,?,?,?)",
            [date.timeIntervalSince1970, source, heard, actionJSON, result, engine, ctx, ok ? 1 : 0])
        // Keep the last 5,000 requests.
        run("DELETE FROM requests WHERE id <= (SELECT id FROM requests ORDER BY id DESC LIMIT 1 OFFSET 5000)", [])
        return sqlite3_last_insert_rowid(db)
    }

    /// Most recent first.
    func recent(_ limit: Int = 10) -> [Entry] {
        query("SELECT id, ts, source, heard, action, result, engine, ok FROM requests ORDER BY id DESC LIMIT ?", [limit]) { s in
            Entry(id: sqlite3_column_int64(s, 0), date: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                  source: text(s, 2), heard: text(s, 3),
                  action: text(s, 4).isEmpty ? nil : try? JSONDecoder().decode(Action.self, from: Data(text(s, 4).utf8)),
                  result: text(s, 5), engine: text(s, 6), ok: sqlite3_column_int(s, 7) == 1)
        }
    }

    /// The last action that did something follow-ups can refer to (not questions or memory commands).
    func lastAction() -> Action? {
        let skip: Set<String> = ["ask", "escalate", "draft_reply", "summarize", "info", "remember", "recall", "forget", "screen"]
        return recent(20).first { $0.ok && $0.action.map { !skip.contains($0.action) } == true }?.action
    }

    func searchRequests(_ q: String, limit: Int = 10) -> [Entry] {
        let like = "%\(q)%"
        let ids: [Int64] = query("SELECT id FROM requests WHERE heard LIKE ? OR result LIKE ? ORDER BY id DESC LIMIT ?",
                                 [like, like, limit]) { sqlite3_column_int64($0, 0) }
        return recent(5000).filter { ids.contains($0.id) }
    }

    // MARK: Facts

    func remember(_ fact: String) {
        let t = fact.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
        guard !t.isEmpty else { return }
        run("INSERT OR REPLACE INTO facts (ts, text) VALUES (?, ?)", [Date().timeIntervalSince1970, t])
    }

    /// Oldest first.
    func facts() -> [Fact] {
        query("SELECT id, ts, text FROM facts ORDER BY id", []) { s in
            Fact(id: sqlite3_column_int64(s, 0), date: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)), text: text(s, 2))
        }
    }

    /// Facts sharing a word (3+ letters) with the query, most relevant first.
    func relevantFacts(_ q: String, limit: Int = 8) -> [Fact] {
        let words = Set(q.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
        return facts()
            .map { f in (f, words.filter { f.text.lowercased().contains($0) }.count) }
            .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    func forgetLastFact() -> String? {
        guard let last = facts().last else { return nil }
        run("DELETE FROM facts WHERE id = ?", [last.id])
        return last.text
    }

    func forgetAll() {
        run("DELETE FROM facts", [])
        run("DELETE FROM requests", [])
    }

    // MARK: SQLite plumbing

    private func err(_ m: String) -> NSError { NSError(domain: "Memory", code: 1, userInfo: [NSLocalizedDescriptionKey: m]) }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw err(String(cString: sqlite3_errmsg(db))) }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ args: [Any?]) -> OpaquePointer? {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return nil }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case let v as String: sqlite3_bind_text(s, idx, v, -1, Self.transient)
            case let v as Double: sqlite3_bind_double(s, idx, v)
            case let v as Int: sqlite3_bind_int64(s, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(s, idx, v)
            default: sqlite3_bind_null(s, idx)
            }
        }
        return s
    }

    private func run(_ sql: String, _ args: [Any?]) {
        guard let s = prepare(sql, args) else { return }
        sqlite3_step(s)
        sqlite3_finalize(s)
    }

    private func query<T>(_ sql: String, _ args: [Any?], _ row: (OpaquePointer) -> T) -> [T] {
        guard let s = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(s) }
        var out: [T] = []
        while sqlite3_step(s) == SQLITE_ROW { out.append(row(s)) }
        return out
    }

    private func text(_ s: OpaquePointer, _ col: Int32) -> String {
        sqlite3_column_text(s, col).map { String(cString: $0) } ?? ""
    }
}

/// Follow-ups that refer to the last request: "do that again", "close it".
enum FollowUp {
    static func resolve(_ utterance: String, last: Action?) -> Action? {
        guard let last else { return nil }
        let u = utterance.lowercased().replacingOccurrences(of: "[.!?,]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        func has(_ p: String) -> Bool { u.range(of: p, options: .regularExpression) != nil }
        if has(#"^(do (that|it|this) again|again|repeat( that| it)?|one more time|same again)$"#) { return last }
        if has(#"^(now |ok |okay )?(close|quit|exit|shut) (it|that|this)( (down|now))?$"#) {
            switch last.action {
            case "open_app": return Action(action: "quit_app", app: last.app)
            case "open_url", "new_tab", "search": return Action(action: "close_tab")
            default: return nil
            }
        }
        if has(#"^(now )?(open|launch) it again$"#), last.action == "quit_app" { return Action(action: "open_app", app: last.app) }
        return nil
    }
}
