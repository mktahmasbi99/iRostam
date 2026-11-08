import Foundation
import SQLite3

extension LocalLedger {
    struct WorkoutError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    func prepareWorkouts() throws {
        try write { db in
            for (table, column) in [("workouts", "native_zone"), ("workouts", "native_day"), ("exercise_sets", "native_zone")] {
                if try Self.rows(db, "PRAGMA table_info(\(table))").contains(where: { $0["name"] as? String == column }) {
                    continue
                }
                _ = try Self.rows(db, "ALTER TABLE \(table) ADD COLUMN \(column) TEXT")
            }
        }
    }

    func write<T>(_ action: (OpaquePointer) throws -> T) throws -> T {
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READWRITE) { db in
            _ = try Self.rows(db, "BEGIN IMMEDIATE")
            do {
                let result = try action(db)
                _ = try Self.rows(db, "COMMIT")
                return result
            } catch {
                _ = try? Self.rows(db, "ROLLBACK")
                throw error
            }
        }
    }

    static func instant(_ value: String?, zone: TimeZone, now: Date = Date(), allowFuture: Bool = false) throws -> String {
        let date: Date
        if let value {
            let local = dateFormatter("yyyy-MM-dd'T'HH:mm", zone: zone)
            if let parsed = local.date(from: value), local.string(from: parsed) == value {
                date = parsed
            } else {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let fraction = iso.date(from: value)
                iso.formatOptions = [.withInternetDateTime]
                guard let parsed = fraction ?? iso.date(from: value) else {
                    throw WorkoutError("Choose a valid local date and time.")
                }
                date = parsed
            }
        } else {
            date = now
        }
        guard allowFuture || date <= now else { throw WorkoutError("Times cannot be in the future.") }
        // Preserve the exact microseconds of existing Rostam timestamps.
        if let value, value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}\+00:00$"#, options: .regularExpression) != nil {
            return value
        }
        let utc = TimeZone(secondsFromGMT: 0)!
        let format = dateFormatter("yyyy-MM-dd'T'HH:mm:ss.SSS", zone: utc)
        return format.string(from: date) + "000+00:00"
    }

    func changeWorkout(_ path: String, method: String, payload: Row) throws -> Row {
        let route = path.split(separator: "/").map(String.init)
        if route.prefix(2) == ["api", "exercises"] {
            return try changeExercise(route, method: method, payload: payload)
        }
        if route == ["api", "exercise-images"], method == "POST", let encoded = payload["image"] as? String {
            return try storeExerciseImage(encoded)
        }
        let zone = TimeZone.current
        return try write { db in
            if route == ["api", "workouts"], method == "POST" {
                let start = try Self.instant(payload["startedAt"] as? String, zone: zone)
                let end = try (payload["endedAt"] as? String).map { try Self.instant($0, zone: zone) }
                try Self.checkBounds(start, end)
                if end == nil, let active = try Self.rows(db, "SELECT id FROM workouts WHERE ended_at IS NULL").first?["id"] as? Int {
                    return try Self.workout(db, active)
                }
                let day = Self.localTimestamp(start, format: "yyyy-MM-dd", zone: zone) ?? ""
                _ = try Self.rows(db, """
                    INSERT INTO workouts(name, started_at, ended_at, native_zone, native_day) VALUES (?, ?, ?, ?, ?)
                    """, [try Self.name(payload["name"]), start, end as Any? ?? NSNull(), zone.identifier, day])
                return try Self.workout(db, Int(sqlite3_last_insert_rowid(db)))
            }
            if route.count == 3, route.prefix(2) == ["api", "sets"], let id = Int(route[2]) {
                guard let current = try Self.rows(db, "SELECT * FROM exercise_sets WHERE id = ?", [id]).first else {
                    throw WorkoutError("Set not found.")
                }
                if method == "DELETE" {
                    _ = try Self.rows(db, "DELETE FROM exercise_sets WHERE id = ?", [id])
                    if current["workout_exercise_id"] is NSNull {
                        _ = try Self.rows(db, """
                            DELETE FROM day_exercises WHERE entry_date = ? AND exercise_id = ?
                            AND NOT EXISTS (SELECT 1 FROM exercise_sets WHERE entry_date = day_exercises.entry_date
                                AND exercise_id = day_exercises.exercise_id AND workout_exercise_id IS NULL)
                            """, [current["entry_date"]!, current["exercise_id"]!])
                    }
                    return [:]
                }
                if method == "PATCH", let exercise = current["exercise_id"] as? Int {
                    let member = current["workout_exercise_id"] as? Int
                    let session = try member.map { try Self.sessionForEntry(db, $0) }
                    let setZone = Self.zone(current["native_zone"] ?? session?["native_zone"])
                    return try Self.saveSet(db, exercise: exercise, member: member, session: session,
                                            current: current, day: current["entry_date"] as? String,
                                            payload: payload, zone: setZone)
                }
            }
            if route.count == 6, route.prefix(2) == ["api", "days"],
               route[3] == "exercises", route[5] == "sets", method == "POST", let exercise = Int(route[4]) {
                return try Self.saveSet(db, exercise: exercise, member: nil, session: nil,
                                        current: nil, day: route[2], payload: payload, zone: zone)
            }
            guard route.count >= 3, route.prefix(2) == ["api", "workouts"], let id = Int(route[2]) else {
                throw WorkoutError("This action is unavailable offline.")
            }
            guard let session = try Self.rows(db, "SELECT * FROM workouts WHERE id = ?", [id]).first,
                  let savedStart = session["started_at"] as? String else { throw WorkoutError("Workout not found.") }
            let sessionZone = Self.zone(session["native_zone"])
            let savedEnd = session["ended_at"] as? String
            if (route.count == 3 && method == "PATCH") || (route.count == 4 && route[3] == "finish" && method == "POST") {
                let finish = route.count == 4
                if finish && savedEnd != nil { return try Self.workout(db, id) }
                let start = try (payload["startedAt"] as? String).map { try Self.instant($0, zone: sessionZone) } ?? savedStart
                var end = try (payload["endedAt"] as? String).map { try Self.instant($0, zone: sessionZone) } ?? savedEnd
                if finish && end == nil { end = try Self.instant(nil, zone: sessionZone) }
                try Self.checkBounds(start, end)
                let bounds = try Self.rows(db, """
                    SELECT min(s.occurred_at) AS first, max(s.occurred_at) AS last, count(*) AS count
                    FROM exercise_sets s JOIN workout_exercises x ON x.id = s.workout_exercise_id WHERE x.workout_id = ?
                    """, [id]).first
                if savedEnd == nil && end != nil && (bounds?["count"] as? Int ?? 0) == 0 {
                    throw WorkoutError("Log at least one set or discard this empty workout.")
                }
                if let first = bounds?["first"] as? String, let last = bounds?["last"] as? String,
                   first < start || (end.map { last > $0 } ?? false) {
                    throw WorkoutError("Workout times must contain all its saved sets.")
                }
                let name = try payload["name"].map(Self.name) ?? (session["name"] as? String ?? "Workout")
                let day = Self.localTimestamp(start, format: "yyyy-MM-dd", zone: sessionZone) ?? ""
                _ = try Self.rows(db, "UPDATE workouts SET name = ?, started_at = ?, ended_at = ?, native_day = ? WHERE id = ?",
                                  [name, start, end as Any? ?? NSNull(), day, id])
                return try Self.workout(db, id)
            }
            if route.count == 3 && method == "DELETE" {
                let count = try Self.workout(db, id)["setCount"] as? Int ?? 0
                if count > 0 && payload["confirmation"] as? String != "DELETE" {
                    throw WorkoutError("Confirm deletion of this workout and its sets.")
                }
                _ = try Self.rows(db, "DELETE FROM workouts WHERE id = ?", [id])
                return [:]
            }
            if route.count == 4 && route[3] == "order" && method == "PUT" {
                let ids = payload["exerciseEntryIds"] as? [Int] ?? []
                let existing = try Self.rows(db, "SELECT id FROM workout_exercises WHERE workout_id = ?", [id])
                    .compactMap { $0["id"] as? Int }
                guard ids.count == existing.count, Set(ids) == Set(existing) else {
                    throw WorkoutError("Include each workout exercise exactly once.")
                }
                for (position, entry) in ids.enumerated() {
                    _ = try Self.rows(db, "UPDATE workout_exercises SET position = ? WHERE id = ?", [position, entry])
                }
                return try Self.workout(db, id)
            }
            if route.count == 4 && route[3] == "exercises" && method == "POST",
               let exercise = payload["exerciseId"] as? Int {
                guard try !Self.rows(db, "SELECT id FROM exercises WHERE id = ? AND archived_at IS NULL", [exercise]).isEmpty else {
                    throw WorkoutError("Choose an active exercise.")
                }
                _ = try Self.rows(db, """
                    INSERT OR IGNORE INTO workout_exercises(workout_id, exercise_id, position)
                    VALUES (?, ?, (SELECT coalesce(max(position), -1) + 1 FROM workout_exercises WHERE workout_id = ?))
                    """, [id, exercise, id])
                return try Self.workout(db, id)
            }
            if route.count >= 5, route[3] == "exercises", let entry = Int(route[4]),
               let exercise = try Self.rows(db, "SELECT exercise_id FROM workout_exercises WHERE id = ? AND workout_id = ?", [entry, id]).first?["exercise_id"] as? Int {
                if route.count == 5 && method == "DELETE" {
                    if payload["confirmation"] as? String != "DELETE",
                       try !Self.rows(db, "SELECT id FROM exercise_sets WHERE workout_exercise_id = ? LIMIT 1", [entry]).isEmpty {
                        throw WorkoutError("Confirm removal of this exercise and its sets.")
                    }
                    _ = try Self.rows(db, "DELETE FROM workout_exercises WHERE id = ?", [entry])
                    return [:]
                }
                if route.count == 6 && route[5] == "sets" && method == "POST" {
                    return try Self.saveSet(db, exercise: exercise, member: entry, session: session,
                                            current: nil, day: nil, payload: payload, zone: sessionZone)
                }
            }
            throw WorkoutError("This workout action is unavailable.")
        }
    }

    private static func name(_ value: Any?) throws -> String {
        let name = (value as? String ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard name.count <= 100 else { throw WorkoutError("Workout names can have up to 100 characters.") }
        return name.isEmpty ? "Workout" : name
    }

    private static func checkBounds(_ start: String, _ end: String?) throws {
        if let end, end < start { throw WorkoutError("Workout end must be at or after its start.") }
    }

    private static func zone(_ value: Any?) -> TimeZone {
        (value as? String).flatMap(TimeZone.init(identifier:)) ?? legacyZone
    }

    private static func sessionForEntry(_ db: OpaquePointer, _ entry: Int) throws -> Row {
        guard let session = try rows(db, """
            SELECT w.* FROM workouts w JOIN workout_exercises x ON x.workout_id = w.id WHERE x.id = ?
            """, [entry]).first else { throw WorkoutError("Workout exercise not found.") }
        return session
    }

    private static func saveSet(_ db: OpaquePointer, exercise id: Int, member: Int?, session: Row?,
                                current: Row?, day: String?, payload: Row, zone: TimeZone) throws -> Row {
        guard let exercise = try rows(db, "SELECT * FROM exercises WHERE id = ?", [id]).first,
              current != nil || exercise["archived_at"] is NSNull else { throw WorkoutError("Choose an active exercise.") }
        let now = Date()
        let saved = current?["occurred_at"] as? String
        let occurred: String
        if let session, let start = session["started_at"] as? String {
            occurred = try (payload["occurredAt"] as? String).map { try instant($0, zone: zone, now: now) }
                ?? saved ?? (session["ended_at"] is NSNull ? instant(nil, zone: zone, now: now) : start)
            if occurred < start || (session["ended_at"] as? String).map({ occurred > $0 }) == true {
                throw WorkoutError("Set time must be within the workout’s start and end times.")
            }
        } else if let day {
            let format = dateFormatter("yyyy-MM-dd", zone: zone)
            guard day <= format.string(from: now) else { throw WorkoutError("Choose today or an earlier date.") }
            if let time = payload["time"] as? String {
                occurred = try instant(day + "T" + time, zone: zone, now: now)
            } else if let saved {
                occurred = saved
            } else if day == format.string(from: now) {
                occurred = try instant(nil, zone: zone, now: now)
            } else {
                let time = dateFormatter("HH:mm", zone: zone).string(from: now)
                occurred = try instant(day + "T" + time, zone: zone, now: now)
            }
        } else { throw Failure.database }
        guard let date = day ?? localTimestamp(occurred, format: "yyyy-MM-dd", zone: zone) else { throw Failure.database }
        let reps = payload["repetitions"] as? Int
        let measurement = exercise["measurement_type"] as? String
        if measurement != "duration" && !(1...1_000_000).contains(reps ?? 0) {
            throw WorkoutError("Enter between 1 and 1,000,000 repetitions.")
        }
        func seconds(_ prefix: String) throws -> Int {
            let minutes = payload[prefix + "Minutes"] as? Int ?? 0
            let seconds = payload[prefix + "Seconds"] as? Int ?? 0
            guard (0...1440).contains(minutes), (0...59).contains(seconds), (1...86400).contains(minutes * 60 + seconds) else {
                throw WorkoutError("Enter a duration between 1 second and 24 hours.")
            }
            return minutes * 60 + seconds
        }
        let hasDuration = ["durationMinutes", "durationSeconds"].contains { payload[$0] is Int }
        let hasHold = ["holdMinutes", "holdSeconds"].contains { payload[$0] is Int }
        switch measurement {
        case "repetitions" where !hasDuration && !hasHold: break
        case "duration" where reps == nil && !hasHold: break
        case "timed_repetitions" where !hasDuration: break
        default: throw WorkoutError("Use the measurement fields for this exercise.")
        }
        let duration = measurement == "duration" ? try seconds("duration") : nil
        let hold = measurement == "timed_repetitions" ? try seconds("hold") : nil
        var grams: Int?
        if payload["resistanceKind"] as? String == "external" {
            let input = (payload["weightKg"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ",", with: ".")
            guard input.range(of: #"^(?:\d+(?:\.\d*)?|\.\d+)$"#, options: .regularExpression) != nil,
                  let kg = Decimal(string: input, locale: Locale(identifier: "en_US_POSIX")),
                  kg >= 0, kg <= 10_000, exercise["equipment"] is String else {
                throw WorkoutError("Enter a valid weight up to 10,000 kg for this exercise.")
            }
            var scaled = kg * 1000
            var rounded = Decimal()
            NSDecimalRound(&rounded, &scaled, 0, .plain)
            if kg > 0 {
                grams = NSDecimalNumber(decimal: rounded).intValue
                guard grams != 0 else { throw WorkoutError("Enter at least 0.001 kg.") }
            }
        } else if payload["resistanceKind"] as? String != "bodyweight" {
            throw WorkoutError("Choose a resistance type.")
        }
        if grams == nil && (exercise["allow_bodyweight"] as? Int ?? 0) == 0 {
            throw WorkoutError("Bodyweight is not allowed for this exercise.")
        }
        let stamp = try instant(nil, zone: zone, now: now)
        let values: [Any] = [
            date, occurred, (measurement == "duration" ? nil : reps) as Any? ?? NSNull(),
            duration as Any? ?? NSNull(), hold as Any? ?? NSNull(),
            grams == nil ? "bodyweight" : "external", grams as Any? ?? NSNull(),
            grams == nil ? NSNull() : exercise["equipment"] ?? NSNull(),
            grams == nil ? NSNull() : exercise["custom_equipment"] ?? NSNull(),
            stamp, zone.identifier
        ]
        let setID: Int
        if let existing = current?["id"] as? Int {
            _ = try rows(db, """
                UPDATE exercise_sets SET entry_date = ?, occurred_at = ?, repetitions = ?, duration_seconds = ?,
                    hold_seconds = ?, resistance_kind = ?, weight_grams = ?, equipment = ?, custom_equipment = ?,
                    updated_at = ?, native_zone = ? WHERE id = ?
                """, values + [existing])
            setID = existing
        } else {
            if member == nil {
                _ = try rows(db, """
                    INSERT OR IGNORE INTO day_exercises(entry_date, exercise_id, display_order, created_at)
                    VALUES (?, ?, (SELECT coalesce(max(display_order), 0) + 1 FROM day_exercises WHERE entry_date = ?), ?)
                    """, [date, id, date, stamp])
            }
            _ = try rows(db, """
                INSERT INTO exercise_sets(entry_date, occurred_at, repetitions, duration_seconds, hold_seconds,
                    resistance_kind, weight_grams, equipment, custom_equipment, updated_at, native_zone,
                    exercise_id, created_at, workout_exercise_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, values + [id, stamp, member as Any? ?? NSNull()])
            setID = Int(sqlite3_last_insert_rowid(db))
        }
        guard let result = try sets(db, "id = ?", [setID]).first else { throw Failure.database }
        return result
    }
}
