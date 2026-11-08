import Foundation
import SQLite3

struct LocalLedger {
    let databaseURL: URL

    func isInitialized() throws -> Bool {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return false }
        return try withDatabase(flags: SQLITE_OPEN_READONLY) { database in
            var statement: OpaquePointer?
            let query = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'profile_settings'"
            guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
                throw Failure.database
            }
            defer { sqlite3_finalize(statement) }
            switch sqlite3_step(statement) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw Failure.database
            }
        }
    }

    func initialize() throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try withDatabase(flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) { database in
            // shortcut: only the profile table exists on a fresh install until ledger migrations are ported.
            let schema = """
                CREATE TABLE IF NOT EXISTS profile_settings (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    height_mm INTEGER CHECK (height_mm > 0),
                    date_of_birth TEXT
                )
                """
            guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
                throw Failure.database
            }
        }
    }

    private func withDatabase<T>(flags: Int32, _ operation: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        defer { sqlite3_close(handle) }
        guard result == SQLITE_OK, let database = handle else { throw Failure.database }
        return try operation(database)
    }

    private enum Failure: Error {
        case database
    }
}
