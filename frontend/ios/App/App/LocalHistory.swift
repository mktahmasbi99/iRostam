import Foundation
import SQLite3

extension LocalLedger {
    typealias Row = [String: Any]

    // Format 1 backups do not carry the server timezone. The deployed source used Warsaw.
    static let legacyZone = TimeZone(identifier: "Europe/Warsaw")!

    func history(_ path: String) throws -> Row {
        guard let url = URLComponents(string: path) else { throw Failure.database }
        let route = url.path.split(separator: "/").map(String.init)
        let query = url.queryItems ?? []
        if route == ["api", "rotations"] {
            return ["items": try rotationList(query.first(where: { $0.name == "status" })?.value ?? "active")]
        }
        if route == ["api", "rotation-recommendations"] {
            let days = Int(query.first(where: { $0.name == "days" })?.value ?? "") ?? 7
            return ["items": try rotationRecommendations(days)]
        }
        if route == ["api", "exercise-recommendations"] {
            return try exerciseRecommendations(path)
        }
        return try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { db in
            if route.count == 3, route.prefix(2) == ["api", "days"] {
                let day = route[2]
                guard let start = Self.localDate(day),
                      let end = Self.legacyCalendar.date(byAdding: .day, value: 1, to: start) else {
                    throw Failure.database
                }
                let sessions = try Self.rows(db, Self.workoutSummaries + """
                    WHERE w.native_day = ? OR (w.native_day IS NULL AND w.started_at >= ? AND w.started_at < ?)
                    OR EXISTS (
                        SELECT 1 FROM workout_exercises x JOIN exercise_sets s ON s.workout_exercise_id = x.id
                        WHERE x.workout_id = w.id AND s.entry_date = ?
                    )
                    ORDER BY w.started_at, w.id
                    """, [day, Self.utcBoundary(start), Self.utcBoundary(end), day])
                let exercises = try Self.rows(db, Self.exerciseFields + """
                    JOIN day_exercises d ON d.exercise_id = e.id WHERE d.entry_date = ? ORDER BY d.display_order
                    """, [day])
                let sections: [Row] = try exercises.enumerated().compactMap { index, exercise in
                    guard let id = exercise["id"] as? Int else { throw Failure.database }
                    let sets = try Self.sets(db, "exercise_id = ? AND entry_date = ? AND workout_exercise_id IS NULL", [id, day])
                    if sets.isEmpty { return nil }
                    return ["exercise": exercise, "displayOrder": index, "sets": sets, "total": Self.total(sets)]
                }
                let active = try Self.rows(db, Self.workoutSummaries + "WHERE w.ended_at IS NULL").first
                return ["date": day, "sections": sections, "workouts": sessions, "activeWorkout": active as Any? ?? NSNull()]
            }
            if route.count == 3, route.prefix(2) == ["api", "calendar"] {
                let month = route[2]
                guard let start = Self.localDate(month + "-01"),
                      let end = Self.legacyCalendar.date(byAdding: .month, value: 1, to: start) else {
                    throw Failure.database
                }
                let dates = try Self.rows(db, """
                    SELECT DISTINCT entry_date FROM exercise_sets WHERE entry_date LIKE ?
                    """, [month + "-%"])
                var active = Set(dates.compactMap { $0["entry_date"] as? String })
                let localWorkouts = try Self.rows(db, "SELECT native_day FROM workouts WHERE native_day LIKE ?", [month + "-%"])
                active.formUnion(localWorkouts.compactMap { $0["native_day"] as? String })
                for table in ["workouts", "activity_entries"] {
                    let legacyOnly = table == "workouts" ? " AND native_day IS NULL" : ""
                    let rows = try Self.rows(db, """
                        SELECT started_at FROM \(table) WHERE started_at >= ? AND started_at < ?\(legacyOnly)
                        """, [Self.utcBoundary(start), Self.utcBoundary(end)])
                    active.formUnion(rows.compactMap { Self.localTimestamp($0["started_at"], format: "yyyy-MM-dd") })
                }
                let today = Self.dateFormatter("yyyy-MM-dd", zone: .current).string(from: Date())
                return ["month": month, "activeDates": active.filter { $0 <= today }.sorted()]
            }
            if route == ["api", "exercises"] {
                let status = query.first { $0.name == "status" }?.value ?? "active"
                let filter = query.first { $0.name == "measurementType" }?.value ?? ""
                let term = query.first { $0.name == "query" }?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let exercises = try Self.rows(db, Self.exerciseFields + """
                    WHERE (? = 'all' OR (? = 'active' AND e.archived_at IS NULL) OR (? = 'archived' AND e.archived_at IS NOT NULL))
                    AND (? = '' OR e.measurement_type = ?) ORDER BY e.name COLLATE NOCASE
                    """, [status, status, status, filter, filter])
                return ["items": try exercises.filter {
                    term.isEmpty || ($0["name"] as? String)?.localizedStandardContains(term) == true
                }.map { try Self.exerciseDetails(db, $0) }]
            }
            if route.count == 3, route.prefix(2) == ["api", "exercise-images"] {
                guard let row = try Self.rows(db, "SELECT jpeg FROM exercise_images WHERE image_key = ?", [route[2]]).first,
                      let data = row["jpeg"] as? Data else { throw Failure.database }
                return ["image": data.base64EncodedString()]
            }
            if route.count == 4, route.prefix(2) == ["api", "exercises"],
               route[3] == "prefill", let id = Int(route[2]) {
                let day = query.first { $0.name == "day" }?.value ?? ""
                let time = query.first { $0.name == "time" }?.value
                let zone = TimeZone.current
                let now = Date()
                let today = Self.dateFormatter("yyyy-MM-dd", zone: zone).string(from: now)
                let local = time.map { day + "T" + $0 } ?? (day == today ? nil :
                    day + "T" + Self.dateFormatter("HH:mm", zone: zone).string(from: now))
                let boundary = try Self.instant(local, zone: zone, now: now, allowFuture: true)
                let latest = """
                    id = (SELECT id FROM exercise_sets WHERE exercise_id = ? AND occurred_at < ?
                        ORDER BY occurred_at DESC, created_at DESC, id DESC LIMIT 1)
                    """
                if var previous = try Self.sets(db, latest, [id, boundary]).first {
                    previous["source"] = "previous"
                    return previous
                }
                return ["source": "defaults", "repetitions": NSNull(), "durationMinutes": NSNull(),
                        "durationSeconds": NSNull(), "holdMinutes": NSNull(), "holdSeconds": NSNull(),
                        "resistanceKind": "external", "weightKg": NSNull()]
            }
            if route.count == 4, route.prefix(2) == ["api", "exercises"],
               route[3] == "history", let exercise = Int(route[2]) {
                let before = query.first { $0.name == "beforeDate" }?.value
                let limit = min(50, max(1, Int(query.first { $0.name == "limit" }?.value ?? "") ?? 20))
                let dates = try Self.rows(db, """
                    SELECT DISTINCT entry_date FROM exercise_sets
                    WHERE exercise_id = ? AND entry_date < ? ORDER BY entry_date DESC LIMIT ?
                    """, [exercise, before ?? "9999-99-99", limit + 1])
                let sessions: [Row] = try dates.prefix(limit).map { row in
                    guard let date = row["entry_date"] as? String else { throw Failure.database }
                    let sets = try Self.sets(db, "exercise_id = ? AND entry_date = ?", [exercise, date])
                    return ["date": date, "sets": sets, "total": Self.total(sets)]
                }
                let next = dates.count > limit ? sessions.last?["date"] : nil
                return ["sessions": sessions, "nextBeforeDate": next ?? NSNull()]
            }
            if route.count == 3, route.prefix(2) == ["api", "workouts"], let id = Int(route[2]) {
                return try Self.workout(db, id)
            }
            throw Failure.database
        }
    }

    static func workout(_ db: OpaquePointer, _ id: Int) throws -> Row {
        guard var workout = try Self.rows(db, Self.workoutSummaries + "WHERE w.id = ?", [id]).first else {
            throw Failure.database
        }
        let entries = try Self.rows(db, """
            SELECT id, exercise_id, position FROM workout_exercises WHERE workout_id = ? ORDER BY position, id
            """, [id])
        workout["exercises"] = try entries.map { entry -> Row in
            guard let entryID = entry["id"] as? Int, let exerciseID = entry["exercise_id"] as? Int,
                  let exercise = try Self.rows(db, Self.exerciseFields + "WHERE e.id = ?", [exerciseID]).first else {
                throw Failure.database
            }
            let sets = try Self.sets(db, "workout_exercise_id = ?", [entryID])
            return ["id": entryID, "position": entry["position"] ?? 0, "exercise": exercise, "sets": sets]
        }
        return workout
    }

    private static let workoutSummaries = """
        SELECT w.id, w.name, w.started_at AS startedAt, w.ended_at AS endedAt, COALESCE(w.native_zone, 'Europe/Warsaw') AS timezone,
            (SELECT count(*) FROM workout_exercises x WHERE x.workout_id = w.id) AS exerciseCount,
            (SELECT count(*) FROM workout_exercises x JOIN exercise_sets s ON s.workout_exercise_id = x.id
                WHERE x.workout_id = w.id) AS setCount
        FROM workouts w

        """

    static let exerciseFields = """
        SELECT e.id, e.name, e.base_name AS baseName, e.measurement_type AS measurementType,
            e.equipment, e.custom_equipment AS customEquipment, e.allow_bodyweight AS allowBodyweight,
            e.image_key AS imageKey, e.exercise_note AS exerciseNote, e.archived_at AS archivedAt,
            e.recommendation_paused_until AS recommendationPausedUntil,
            e.recommendation_paused_forever AS recommendationPausedForever,
            EXISTS(SELECT 1 FROM exercise_sets s WHERE s.exercise_id = e.id) AS hasHistory
        FROM exercises e

        """

    static func sets(_ db: OpaquePointer, _ filter: String, _ parameters: [Any]) throws -> [Row] {
        try rows(db, """
            SELECT id, exercise_id AS exerciseId, workout_exercise_id AS workoutExerciseId,
                entry_date AS date, occurred_at AS occurredAt, repetitions,
                duration_seconds / 60 AS durationMinutes, duration_seconds % 60 AS durationSeconds,
                hold_seconds / 60 AS holdMinutes, hold_seconds % 60 AS holdSeconds,
                resistance_kind AS resistanceKind,
                CASE WHEN weight_grams IS NOT NULL
                    THEN rtrim(rtrim(printf('%.3f', weight_grams / 1000.0), '0'), '.')
                END AS weightKg,
                equipment, custom_equipment AS customEquipment, created_at AS createdAt, native_zone
            FROM exercise_sets WHERE \(filter) ORDER BY occurred_at, created_at, id
            """, parameters).map { row in
                var set = row
                let zone = (set.removeValue(forKey: "native_zone") as? String).flatMap(TimeZone.init(identifier:)) ?? legacyZone
                set["time"] = localTimestamp(row["occurredAt"], format: "HH:mm", zone: zone) ?? ""
                return set
            }
    }

    private static func total(_ sets: [Row]) -> Int {
        sets.reduce(0) { total, row in
            total + ((row["repetitions"] as? Int) ?? ((row["durationMinutes"] as? Int ?? 0) * 60 + (row["durationSeconds"] as? Int ?? 0)))
        }
    }

    private static var legacyCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = legacyZone
        return calendar
    }

    static func dateFormatter(_ format: String, zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = format
        return formatter
    }

    private static func utcBoundary(_ date: Date) -> String {
        dateFormatter("yyyy-MM-dd'T'HH:mm:ss'.000000+00:00'", zone: TimeZone(secondsFromGMT: 0)!).string(from: date)
    }

    private static func localDate(_ value: String) -> Date? {
        let formatter = dateFormatter("yyyy-MM-dd", zone: legacyZone)
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }

    static func localTimestamp(_ value: Any?, format: String, zone: TimeZone = legacyZone) -> String? {
        guard let timestamp = value as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = iso.date(from: timestamp)
        if date == nil {
            iso.formatOptions = [.withInternetDateTime]
            date = iso.date(from: timestamp)
        }
        return date.map { dateFormatter(format, zone: zone).string(from: $0) }
    }

    static func rows(_ db: OpaquePointer, _ sql: String, _ parameters: [Any] = []) throws -> [Row] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw Failure.database }
        defer { sqlite3_finalize(statement) }
        for (index, value) in parameters.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            if let number = value as? Int {
                result = sqlite3_bind_int64(statement, position, Int64(number))
            } else if let data = value as? Data {
                result = data.withUnsafeBytes {
                    sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count),
                                      unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            } else if value is NSNull {
                result = sqlite3_bind_null(statement, position)
            } else if let text = value as? String {
                result = sqlite3_bind_text(statement, position, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                throw Failure.database
            }
            guard result == SQLITE_OK else { throw Failure.database }
        }
        var result: [Row] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return result
            case SQLITE_ROW:
                var row: Row = [:]
                for column in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, column))
                    switch sqlite3_column_type(statement, column) {
                    case SQLITE_INTEGER:
                        let number = Int(sqlite3_column_int64(statement, column))
                        row[name] = ["allowBodyweight", "hasHistory"].contains(name) ? (number != 0) as Any : number
                    case SQLITE_BLOB:
                        if let bytes = sqlite3_column_blob(statement, column) {
                            row[name] = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
                        }
                    case SQLITE_TEXT:
                        if let text = sqlite3_column_text(statement, column) { row[name] = String(cString: text) }
                    default: row[name] = NSNull()
                    }
                }
                result.append(row)
            default: throw Failure.database
            }
        }
    }
}
