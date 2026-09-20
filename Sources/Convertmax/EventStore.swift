import Foundation
import SQLite3

final class EventStore {
    private var db: OpaquePointer?

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("events.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            db = nil
            return
        }
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS events (message_id TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL, created_at INTEGER NOT NULL);", nil, nil, nil)
        migrateJSON(from: directory)
    }

    deinit { if let db { sqlite3_close(db) } }

    func load() -> [ConvertmaxEvent] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM events ORDER BY created_at ASC;", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var events: [ConvertmaxEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                let data = Data(bytes: text, count: Int(sqlite3_column_bytes(statement, 0)))
                if let event = try? JSONDecoder().decode(ConvertmaxEvent.self, from: data) { events.append(event) }
            }
        }
        return Array(events.prefix(1000))
    }

    func save(_ events: [ConvertmaxEvent]) {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM events;", nil, nil, nil)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO events(message_id, payload, created_at) VALUES (?, ?, ?);", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        for (index, event) in events.enumerated() {
            guard let payload = try? JSONEncoder().encode(event), let json = String(data: payload, encoding: .utf8) else { continue }
            sqlite3_bind_text(statement, 1, event.messageId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, json, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 3, Int64(index))
            sqlite3_step(statement)
            sqlite3_reset(statement)
        }
    }

    private func migrateJSON(from directory: URL) {
        let url = directory.appendingPathComponent("events.json")
        guard let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode([ConvertmaxEvent].self, from: data) else { return }
        save(Array(stored.prefix(1000)))
        try? FileManager.default.removeItem(at: url)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
