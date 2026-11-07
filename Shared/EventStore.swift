import Foundation
import SQLite3

/// Tiny SQLite store: the agent writes, the app reads. WAL mode lets both use it at once.
/// Uses the system libsqlite3, so it adds nothing to the app's size.
nonisolated final class EventStore {
    enum StoreError: Error {
        case open(String)
        case sql(String)
        case invalidLimit
    }

    private var db: OpaquePointer?

    init(url: URL = AppInfo.eventsDatabase) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            let message = Self.message(db)
            sqlite3_close_v2(db)
            db = nil
            throw StoreError.open(message)
        }
        sqlite3_busy_timeout(db, 2_000)
        do {
            try exec("PRAGMA journal_mode = WAL")
            try exec("BEGIN IMMEDIATE")
            do {
                try exec("""
                    CREATE TABLE IF NOT EXISTS events (
                        id        INTEGER PRIMARY KEY AUTOINCREMENT,
                        time      REAL    NOT NULL,
                        kind      TEXT    NOT NULL,
                        pid       INTEGER NOT NULL DEFAULT 0,
                        bundle_id TEXT    NOT NULL DEFAULT '',
                        process   TEXT    NOT NULL DEFAULT '',
                        detail    TEXT    NOT NULL DEFAULT ''
                    );
                    CREATE INDEX IF NOT EXISTS events_time ON events(time);
                    """)
                var hasSourceKey = false
                try withStatement("PRAGMA table_info(events)") { stmt in
                    var result = sqlite3_step(stmt)
                    while result == SQLITE_ROW {
                        if Self.text(stmt, 1) == "source_key" { hasSourceKey = true }
                        result = sqlite3_step(stmt)
                    }
                    guard result == SQLITE_DONE else { throw StoreError.sql(Self.message(db)) }
                }
                if !hasSourceKey { try exec("ALTER TABLE events ADD COLUMN source_key TEXT") }
                try exec("CREATE UNIQUE INDEX IF NOT EXISTS events_source_key ON events(source_key) WHERE source_key IS NOT NULL")
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        } catch {
            sqlite3_close_v2(db)
            db = nil
            throw error
        }
    }

    deinit { sqlite3_close_v2(db) }

    @discardableResult
    func insert(_ e: SoundEvent) throws -> Bool {
        let sql = "INSERT INTO events (time, kind, pid, bundle_id, process, detail, source_key) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(source_key) WHERE source_key IS NOT NULL DO NOTHING"
        var inserted = false
        try withStatement(sql) { stmt in
            sqlite3_bind_double(stmt, 1, e.time.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, e.kind.rawValue, -1, Self.transient)
            sqlite3_bind_int(stmt, 3, e.pid)
            sqlite3_bind_text(stmt, 4, e.bundleID, -1, Self.transient)
            sqlite3_bind_text(stmt, 5, e.processName, -1, Self.transient)
            sqlite3_bind_text(stmt, 6, e.detail, -1, Self.transient)
            if let key = e.sourceKey { sqlite3_bind_text(stmt, 7, key, -1, Self.transient) }
            else { sqlite3_bind_null(stmt, 7) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.sql(Self.message(db)) }
            inserted = sqlite3_changes(db) > 0
        }
        return inserted
    }

    /// Newest first.
    func events(since: Date, limit: Int = 500) throws -> [SoundEvent] {
        guard limit > 0, limit <= 10_000 else { throw StoreError.invalidLimit }
        var out: [SoundEvent] = []
        let sql = "SELECT id, time, kind, pid, bundle_id, process, detail, source_key FROM events WHERE time >= ? ORDER BY time DESC, id DESC LIMIT ?"
        try withStatement(sql) { stmt in
            sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var result = sqlite3_step(stmt)
            while result == SQLITE_ROW {
                out.append(SoundEvent(
                    id: sqlite3_column_int64(stmt, 0),
                    time: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    kind: SoundEvent.Kind(rawValue: Self.text(stmt, 2)) ?? .system,
                    pid: sqlite3_column_int(stmt, 3),
                    bundleID: Self.text(stmt, 4),
                    processName: Self.text(stmt, 5),
                    detail: Self.text(stmt, 6),
                    sourceKey: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Self.text(stmt, 7)))
                result = sqlite3_step(stmt)
            }
            guard result == SQLITE_DONE else { throw StoreError.sql(Self.message(db)) }
        }
        return out
    }

    func prune(olderThan date: Date) throws {
        try withStatement("DELETE FROM events WHERE time < ?") { stmt in
            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.sql(Self.message(db)) }
        }
    }

    // MARK: - SQLite plumbing

    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.sql(Self.message(db)) }
    }

    private func withStatement(_ sql: String, _ body: (OpaquePointer?) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw StoreError.sql(Self.message(db)) }
        defer { sqlite3_finalize(stmt) }
        try body(stmt)
    }

    private static func text(_ stmt: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }

    private static func message(_ db: OpaquePointer?) -> String { String(cString: sqlite3_errmsg(db)) }
}
