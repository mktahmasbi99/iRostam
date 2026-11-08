import Darwin
import Foundation
import SQLite3

struct LocalLedger {
    let databaseURL: URL

    enum State: String {
        case missing, empty, imported
    }

    func state() throws -> State {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return .missing }
        return try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { database in
            let tables = try Self.values(database, Self.tables)
            if tables.isEmpty { return .missing }
            if tables == ["profile_settings"],
               try Self.values(database, "SELECT count(*) FROM profile_settings") == ["0"] {
                return .empty
            }
            guard tables.contains("backup_metadata") else { throw Failure.database }
            return .imported
        }
    }

    func importBackup(from source: URL) throws {
        guard try state() != .imported else { throw Failure.existingLedger }
        let files = FileManager.default
        let metadata = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard metadata.isRegularFile == true, metadata.isSymbolicLink != true, let size = metadata.fileSize, size <= 100 * 1024 * 1024 else {
            throw Failure.fileSize
        }
        let directory = databaseURL.deletingLastPathComponent()
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent("import-\(UUID().uuidString).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? files.removeItem(atPath: staged.path + suffix)
            }
        }
        try files.copyItem(at: source, to: staged)

        try withDatabase(at: staged, flags: SQLITE_OPEN_READWRITE) { database in
            guard try Self.values(database, Self.tables) == Self.columns.keys.sorted(),
                  try Self.values(database, "SELECT name FROM sqlite_schema WHERE type IN ('trigger', 'view') OR (type = 'table' AND sql LIKE 'CREATE VIRTUAL TABLE%')").isEmpty,
                  try Self.values(database, "SELECT app_id FROM backup_metadata WHERE id = 1 AND format_version = 1") == ["rostam"],
                  try Self.values(database, "SELECT max(version) FROM schema_migrations") == ["17"] else {
                throw Failure.unsupported
            }
            for (table, columns) in Self.columns {
                let actual = try Self.values(database, "SELECT name FROM pragma_table_info('\(table)')")
                guard Set(actual) == Set(columns.split(separator: " ").map(String.init)) else {
                    throw Failure.unsupported
                }
            }
            guard try Self.values(database, "PRAGMA integrity_check") == ["ok"],
                  try Self.values(database, "PRAGMA foreign_key_check").isEmpty,
                  try Self.values(database, "PRAGMA journal_mode = DELETE") == ["delete"] else {
                throw Failure.database
            }
        }
        guard rename(staged.path, databaseURL.path) == 0 else { throw Failure.database }
    }

    func importedCounts() throws -> (workouts: Int, sets: Int, photos: Int) {
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { database in
            let workouts = try Self.values(database, "SELECT count(*) FROM workouts")
            let sets = try Self.values(database, "SELECT count(*) FROM exercise_sets")
            let photos = try Self.values(database, "SELECT count(*) FROM daily_photos")
            guard let workoutCount = workouts.first.flatMap(Int.init),
                  let setCount = sets.first.flatMap(Int.init),
                  let photoCount = photos.first.flatMap(Int.init) else { throw Failure.database }
            return (workoutCount, setCount, photoCount)
        }
    }

    private static let tables = """
        SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT GLOB 'sqlite_*' ORDER BY name
        """

    private static let columns = [
        "activities": "id name normalized_name archived_at created_at",
        "activity_entries": "id activity_id started_at ended_at note created_at updated_at",
        "backup_metadata": "id app_id format_version created_at category",
        "backup_runs": "category last_scheduled_date",
        "backup_settings": "id daily_enabled daily_time daily_retention weekly_enabled weekly_weekday weekly_time weekly_retention safety_retention",
        "body_measurements": "id entry_date measurement_type weight_grams waist_mm created_at updated_at",
        "daily_notes": "entry_date body created_at updated_at",
        "daily_photos": "id entry_date display_order jpeg thumbnail_jpeg width height created_at",
        "day_exercises": "entry_date exercise_id display_order created_at",
        "exercise_images": "image_key jpeg created_at",
        "exercise_muscles": "exercise_id muscle_slug role",
        "exercise_sets": "id exercise_id entry_date occurred_at repetitions duration_seconds hold_seconds resistance_kind weight_grams equipment custom_equipment created_at updated_at workout_exercise_id",
        "exercises": "id seed_key name normalized_name measurement_type default_resistance_kind default_equipment default_custom_equipment default_weight_grams image_key archived_at created_at updated_at base_name equipment custom_equipment allow_bodyweight exercise_note recommendation_paused_until recommendation_paused_forever",
        "muscle_groups": "slug name display_order",
        "profile_settings": "id height_mm date_of_birth",
        "rotation_members": "member_id rotation_id exercise_id position enrolled_date enroll_sequence auto_order",
        "rotations": "id name active due_exercise_id resolved_date resolved_kind due_position archived_at",
        "schema_migrations": "version applied_at",
        "system_notifications": "id message created_at",
        "workout_exercises": "id workout_id exercise_id position",
        "workouts": "id name started_at ended_at"
    ]

    private static func values(_ database: OpaquePointer, _ sql: String) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure.database
        }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let text = sqlite3_column_text(statement, 0) else { throw Failure.database }
                rows.append(String(cString: text))
            case SQLITE_DONE: return rows
            default: throw Failure.database
            }
        }
    }

    func initialize() throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) { database in
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

    func withDatabase<T>(
        at url: URL, flags: Int32, _ operation: (OpaquePointer) throws -> T
    ) throws -> T {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        defer { sqlite3_close(handle) }
        guard result == SQLITE_OK, let database = handle else { throw Failure.database }
        guard sqlite3_exec(database, "PRAGMA trusted_schema = OFF; PRAGMA foreign_keys = ON", nil, nil, nil) == SQLITE_OK else {
            throw Failure.database
        }
        return try operation(database)
    }

    enum Failure: LocalizedError {
        case database, unsupported, fileSize, existingLedger

        var errorDescription: String? {
            switch self {
            case .database: return "The database could not be read or failed an integrity check."
            case .unsupported: return "Choose a Rostam format 1, schema 17 backup downloaded from Rostam Settings."
            case .fileSize: return "Choose a backup file up to 100 MiB."
            case .existingLedger: return "A backup is already imported. Your local database was kept."
            }
        }
    }
}
