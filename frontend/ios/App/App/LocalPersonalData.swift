import Foundation
import SQLite3

extension LocalLedger {
    func personalHistory(_ path: String) throws -> Row {
        guard let url = URLComponents(string: path) else { throw Failure.database }
        let route = url.path.split(separator: "/").map(String.init)
        let query = url.queryItems ?? []
        return try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { db in
            if route == ["api", "profile"] { return try Self.profile(db) }
            if route == ["api", "body-measurements"] {
                let before = query.first { $0.name == "beforeDate" }?.value
                let beforeID = query.first { $0.name == "beforeId" }?.value.flatMap(Int.init)
                let limit = Int(query.first { $0.name == "limit" }?.value ?? "30") ?? 30
                guard (1...100).contains(limit), (before == nil) == (beforeID == nil) else { throw WorkoutError("Invalid measurement page.") }
                let rows = try Self.rows(db, "SELECT * FROM body_measurements WHERE (? IS NULL OR entry_date < ? OR (entry_date = ? AND id < ?)) ORDER BY entry_date DESC, id DESC LIMIT ?", [before as Any? ?? NSNull(), before as Any? ?? NSNull(), before as Any? ?? NSNull(), beforeID as Any? ?? NSNull(), limit + 1])
                let items = rows.prefix(limit).map(Self.measurement)
                let next = rows.count > limit ? items.last : nil
                return ["items": items, "nextBeforeDate": next?["date"] ?? NSNull(), "nextBeforeId": next?["id"] ?? NSNull()]
            }
            if route == ["api", "body-measurements", "trends"] { return try Self.measurementTrends(db) }
            if route == ["api", "activities"] {
                let status = query.first { $0.name == "status" }?.value ?? "active"
                guard ["active", "archived"].contains(status) else { throw WorkoutError("Activity status must be active or archived.") }
                return ["items": try Self.rows(db, "SELECT id, name FROM activities WHERE archived_at IS \(status == "active" ? "NULL" : "NOT NULL") ORDER BY normalized_name")]
            }
            if route == ["api", "activity-note-groups"] { return ["items": try Self.activityNoteGroups(db)] }
            if route == ["api", "activity-notes"] { return try Self.activityNotes(db, query) }
            if route == ["api", "notes"] {
                let before = query.first { $0.name == "beforeDate" }?.value
                let limit = Int(query.first { $0.name == "limit" }?.value ?? "30") ?? 30
                guard (1...100).contains(limit) else { throw WorkoutError("Limit must be between 1 and 100.") }
                let rows = try Self.rows(db, "SELECT * FROM daily_notes WHERE (? IS NULL OR entry_date < ?) ORDER BY entry_date DESC LIMIT ?", [before as Any? ?? NSNull(), before as Any? ?? NSNull(), limit + 1])
                let items: [Row] = rows.prefix(limit).map { ["date": $0["entry_date"]!, "body": $0["body"]!, "createdAt": $0["created_at"]!, "updatedAt": $0["updated_at"]!] }
                return ["items": items, "nextBeforeDate": rows.count > limit ? (items.last?["date"] ?? NSNull()) : NSNull()]
            }
            throw Failure.database
        }
    }

    func changePersonalData(_ path: String, method: String, payload: Row) throws -> Row {
        let route = path.split(separator: "/").map(String.init)
        if route == ["api", "profile"], method == "PUT" { return try updateProfile(payload) }
        if route.prefix(2) == ["api", "body-measurements"] { return try changeMeasurement(route, method: method, payload: payload) }
        if route.count == 4, route.prefix(2) == ["api", "days"], route[3] == "note" {
            guard let day = route[safe: 2] else { throw WorkoutError("Invalid daily note.") }
            if method == "DELETE" { return try updateDailyNote(day, "") }
            guard let body = payload["body"] as? String else { throw WorkoutError("Invalid daily note.") }
            return try updateDailyNote(day, body)
        }
        if route.prefix(2) == ["api", "activities"] || route.prefix(2) == ["api", "activity-entries"] {
            return try changeActivity(route, method: method, payload: payload)
        }
        throw WorkoutError("This action is unavailable offline.")
    }

    private func updateDailyNote(_ day: String, _ body: String) throws -> Row {
        guard Self.validDay(day), day <= Self.today(), body.count <= 20_000 else { throw WorkoutError("Daily notes must be at most 20,000 characters and cannot be dated in the future.") }
        let stamp = try Self.instant(nil, zone: .current)
        return try write { db in
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try Self.rows(db, "DELETE FROM daily_notes WHERE entry_date = ?", [day])
                return ["date": day, "dailyNote": NSNull()]
            }
            _ = try Self.rows(db, "INSERT INTO daily_notes(entry_date,body,created_at,updated_at) VALUES(?,?,?,?) ON CONFLICT(entry_date) DO UPDATE SET body=excluded.body, updated_at=excluded.updated_at", [day, body, stamp, stamp])
            return ["date": day, "dailyNote": body]
        }
    }

    private func updateProfile(_ payload: Row) throws -> Row {
        let height = try Self.millimetres(payload["heightCm"], label: "Height", maximum: 300)
        let birth = payload["dateOfBirth"] as? String
        if let birth, !Self.validDay(birth) || birth > Self.today() { throw WorkoutError("Date of birth must be a valid date no later than today.") }
        return try write { db in
            _ = try Self.rows(db, "INSERT INTO profile_settings(id,height_mm,date_of_birth) VALUES(1,?,?) ON CONFLICT(id) DO UPDATE SET height_mm=excluded.height_mm,date_of_birth=excluded.date_of_birth", [height as Any? ?? NSNull(), birth as Any? ?? NSNull()])
            return try Self.profile(db)
        }
    }

    private func changeMeasurement(_ route: [String], method: String, payload: Row) throws -> Row {
        let id = route.count == 3 ? Int(route[2]) : nil
        if method == "DELETE", let id {
            return try write { db in
                guard try !Self.rows(db, "DELETE FROM body_measurements WHERE id = ? RETURNING id", [id]).isEmpty else { throw WorkoutError("Measurement not found.") }
                return [:]
            }
        }
        guard let date = payload["date"] as? String, Self.validDay(date), date <= Self.today() else { throw WorkoutError("Choose a valid measurement date.") }
        let weight = try Self.scaledInteger(payload["weightKg"], factor: 1000, label: "Weight", maximum: 10_000)
        let waist = try Self.millimetres(payload["waistCm"], label: "Waist circumference", maximum: 500)
        guard (weight == nil) != (waist == nil) else { throw WorkoutError("Record exactly one measurement.") }
        let type = weight != nil ? "weight" : "waist"
        let stamp = try Self.instant(nil, zone: .current)
        return try write { db in
            guard try Self.rows(db, "SELECT id FROM body_measurements WHERE entry_date=? AND measurement_type=? AND id != COALESCE(?,0)", [date, type, id as Any? ?? NSNull()]).isEmpty else {
                throw WorkoutError("A \(type) measurement already exists for this date.")
            }
            do {
                if method == "POST" && route.count == 2 {
                    _ = try Self.rows(db, "INSERT INTO body_measurements(entry_date,measurement_type,weight_grams,waist_mm,created_at,updated_at) VALUES(?,?,?,?,?,?)", [date, type, weight as Any? ?? NSNull(), waist as Any? ?? NSNull(), stamp, stamp])
                    return try Self.rows(db, "SELECT * FROM body_measurements WHERE id = last_insert_rowid()").first.map(Self.measurement) ?? [:]
                }
                if method == "PATCH", let id {
                    guard try !Self.rows(db, "UPDATE body_measurements SET entry_date=?,measurement_type=?,weight_grams=?,waist_mm=?,updated_at=? WHERE id=? RETURNING id", [date, type, weight as Any? ?? NSNull(), waist as Any? ?? NSNull(), stamp, id]).isEmpty else { throw WorkoutError("Measurement not found.") }
                    return try Self.rows(db, "SELECT * FROM body_measurements WHERE id = ?", [id]).first.map(Self.measurement) ?? [:]
                }
            } catch {
                if String(describing: error).contains("UNIQUE") { throw WorkoutError("A \(type) measurement already exists for this date.") }
                throw error
            }
            throw WorkoutError("This measurement action is unavailable.")
        }
    }

    private func changeActivity(_ route: [String], method: String, payload: Row) throws -> Row {
        let stamp = try Self.instant(nil, zone: .current)
        if route.count == 3, route.prefix(2) == ["api", "activities"], method == "DELETE" {
            guard payload["confirmation"] as? String == "DELETE" else { throw WorkoutError("Type DELETE to permanently delete this activity.") }
            guard try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY, { db in
                try !Self.rows(db, "SELECT id FROM activities WHERE id=?", [Int(route[2]) ?? 0]).isEmpty
            }) else { throw WorkoutError("Activity not found.") }
            try keepRecoveryBackup()
        }
        return try write { db in
            if route == ["api", "activities"], method == "POST" {
                let name = try Self.displayName(payload["name"], limit: 100)
                let key = Self.activityNameKey(name)
                guard try Self.rows(db, "SELECT id FROM activities WHERE normalized_name=?", [key]).isEmpty else { throw WorkoutError("An activity with this name already exists.") }
                _ = try Self.rows(db, "INSERT INTO activities(name,normalized_name,created_at) VALUES(?,?,?)", [name, key, stamp])
                return ["id": Int(sqlite3_last_insert_rowid(db)), "name": name]
            }
            if route.count == 3, route.prefix(2) == ["api", "activities"], let id = Int(route[2]) {
                if method == "DELETE" {
                    guard payload["confirmation"] as? String == "DELETE" else { throw WorkoutError("Type DELETE to permanently delete this activity.") }
                    _ = try Self.rows(db, "DELETE FROM activity_entries WHERE activity_id = ?", [id])
                    _ = try Self.rows(db, "DELETE FROM activities WHERE id = ?", [id])
                    return [:]
                }
                if method == "PATCH" {
                    let name = try Self.displayName(payload["name"], limit: 100)
                    let key = Self.activityNameKey(name)
                    guard try Self.rows(db, "SELECT id FROM activities WHERE normalized_name=? AND id<>?", [key, id]).isEmpty else { throw WorkoutError("An activity with this name already exists.") }
                    _ = try Self.rows(db, "UPDATE activities SET name=?,normalized_name=? WHERE id=?", [name, key, id])
                    return ["id": id, "name": name]
                }
            }
            if route.count == 4, route.prefix(2) == ["api", "activities"], let id = Int(route[2]) {
                if route[3] == "archive" || route[3] == "restore" {
                    let archived: Any = route[3] == "archive" ? stamp : NSNull()
                    _ = try Self.rows(db, "UPDATE activities SET archived_at=? WHERE id=?", [archived, id])
                    guard let activity = try Self.rows(db, "SELECT id,name FROM activities WHERE id=?", [id]).first else { throw WorkoutError("Activity not found.") }
                    return activity
                }
                if route[3] == "entries", method == "POST" {
                    guard let value = payload["startedAt"] as? String else { throw WorkoutError("Choose a start time.") }
                    let start = try Self.activityInstant(value)
                    guard Self.validActivityStart(value) else { throw WorkoutError("Start time must be a valid minute between 00:00 and 23:58.") }
                    guard try !Self.rows(db, "SELECT id FROM activities WHERE id=? AND archived_at IS NULL", [id]).isEmpty else { throw WorkoutError("Activity not found.") }
                    try Self.checkActivityOverlap(db, activity: id, start: start, end: nil)
                    _ = try Self.rows(db, "INSERT INTO activity_entries(activity_id,started_at,created_at,updated_at) VALUES(?,?,?,?)", [id, start, stamp, stamp])
                    return try Self.activityEntry(db, Int(sqlite3_last_insert_rowid(db)))
                }
            }
            if route.count >= 3, route.prefix(2) == ["api", "activity-entries"], let id = Int(route[2]) {
                if route.count == 4, route[3] == "note", method == "PUT" {
                    _ = try Self.rows(db, "UPDATE activity_entries SET note=?,updated_at=? WHERE id=?", [(payload["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines), stamp, id])
                    return try Self.activityEntry(db, id)
                }
                if route.count == 3, method == "DELETE" { _ = try Self.rows(db, "DELETE FROM activity_entries WHERE id=?", [id]); return [:] }
                if route.count == 3, method == "PUT" || method == "PATCH" {
                    guard let startValue = payload["startedAt"] as? String, let endValue = payload["endedAt"] as? String else { throw WorkoutError("Choose start and end times.") }
                    let start = try Self.activityInstant(startValue); let end = try Self.activityInstant(endValue)
                    guard let startDate = Self.parseInstant(start), let endDate = Self.parseInstant(end),
                          endDate > startDate, Self.sameLocalDay(startDate, endDate), Self.validActivityStart(startValue) else { throw WorkoutError("Activity start and end must be valid minutes on the same day, with the end after the start.") }
                    guard let activity = try Self.rows(db, "SELECT activity_id FROM activity_entries WHERE id=?", [id]).first, let activityID = activity["activity_id"] as? Int else { throw WorkoutError("Activity entry not found.") }
                    try Self.checkActivityOverlap(db, activity: activityID, start: start, end: end, excluding: id)
                    _ = try Self.rows(db, "UPDATE activity_entries SET started_at=?,ended_at=?,note=?,updated_at=? WHERE id=?", [start, end, (payload["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines), stamp, id])
                    return try Self.activityEntry(db, id)
                }
            }
            throw WorkoutError("This activity action is unavailable.")
        }
    }

    private static func activityInstant(_ value: String) throws -> String {
        try instant(value, zone: .current, allowFuture: true)
    }

    private static func checkActivityOverlap(_ db: OpaquePointer, activity: Int, start: String, end: String?, excluding: Int? = nil) throws {
        let rows = try Self.rows(db, "SELECT id,started_at,ended_at FROM activity_entries WHERE activity_id=? AND id != COALESCE(?,0)", [activity, excluding as Any? ?? NSNull()])
        for row in rows {
            guard let otherStart = row["started_at"] as? String else { continue }
            let otherEnd = row["ended_at"] as? String
            if end == nil && otherEnd == nil { throw WorkoutError("A session of this activity is already running. Stop it before starting another.") }
            let effectiveEnd = otherEnd ?? Self.instantString(Date())
            let candidateEnd = end ?? Self.instantString(Date().addingTimeInterval(60))
            if start < effectiveEnd && otherStart < (end ?? candidateEnd) { throw WorkoutError("That time overlaps another session of this activity.") }
        }
    }

    private static func activityEntry(_ db: OpaquePointer, _ id: Int) throws -> Row {
        guard let row = try Self.rows(db, "SELECT x.*,a.name FROM activity_entries x JOIN activities a ON a.id=x.activity_id WHERE x.id=?", [id]).first,
              let startValue = row["started_at"] as? String, let start = Self.parseInstant(startValue) else { throw WorkoutError("Activity entry not found.") }
        let end = (row["ended_at"] as? String).flatMap(Self.parseInstant)
        return ["id": id, "activityId": row["activity_id"] ?? 0, "activityName": row["name"] ?? "", "date": Self.dateFormatter("yyyy-MM-dd", zone: .current).string(from: start), "startedAt": Self.dateFormatter("yyyy-MM-dd'T'HH:mm:ssXXXXX", zone: .current).string(from: start), "endedAt": end.map { Self.dateFormatter("yyyy-MM-dd'T'HH:mm:ssXXXXX", zone: .current).string(from: $0) } as Any? ?? NSNull(), "durationSeconds": end.map { Int($0.timeIntervalSince(start)) } as Any? ?? NSNull(), "note": row["note"] ?? "", "createdAt": row["created_at"] ?? ""]
    }

    private static func activityNotes(_ db: OpaquePointer, _ query: [URLQueryItem]) throws -> Row {
        let before = query.first { $0.name == "beforeStartedAt" }?.value
        let beforeID = query.first { $0.name == "beforeId" }?.value.flatMap(Int.init)
        let activityID = query.first { $0.name == "activityId" }?.value.flatMap(Int.init)
        let limit = Int(query.first { $0.name == "limit" }?.value ?? "30") ?? 30
        guard (1...100).contains(limit), (before == nil) == (beforeID == nil) else { throw WorkoutError("Invalid activity notes page.") }
        let rows = try Self.rows(db, "SELECT x.id,x.started_at FROM activity_entries x WHERE x.note != '' AND (? IS NULL OR x.activity_id=?) AND (? IS NULL OR x.started_at < ? OR (x.started_at=? AND x.id < ?)) ORDER BY x.started_at DESC,x.id DESC LIMIT ?", [activityID as Any? ?? NSNull(), activityID as Any? ?? NSNull(), before as Any? ?? NSNull(), before as Any? ?? NSNull(), before as Any? ?? NSNull(), beforeID as Any? ?? NSNull(), limit + 1])
        var items: [Row] = []
        for row in rows.prefix(limit) {
            if let id = row["id"] as? Int { items.append(try Self.activityEntry(db, id)) }
        }
        let last = rows.count > limit ? rows[limit - 1] : nil
        return ["items": items, "nextBeforeStartedAt": last?["started_at"] ?? NSNull(), "nextBeforeId": last?["id"] ?? NSNull()]
    }

    private static func activityNoteGroups(_ db: OpaquePointer) throws -> [Row] {
        try Self.rows(db, "SELECT a.id AS activityId,a.name AS activityName,COUNT(*) AS noteCount,MAX(x.started_at) AS latestStartedAt FROM activities a JOIN activity_entries x ON x.activity_id=a.id WHERE x.note != '' GROUP BY a.id,a.name ORDER BY latestStartedAt DESC,a.id")
    }

    static func activitiesForDay(_ db: OpaquePointer, _ day: String) throws -> [Row] {
        let formatter = dateFormatter("yyyy-MM-dd", zone: .current)
        guard let start = formatter.date(from: day), formatter.string(from: start) == day,
              let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { throw WorkoutError("Choose a valid activity date.") }
        let ids = try rows(db, "SELECT x.id FROM activity_entries x WHERE x.started_at >= ? AND x.started_at < ? ORDER BY x.started_at,x.id", [localBoundary(start), localBoundary(end)])
        var entries: [Row] = []
        for row in ids {
            if let id = row["id"] as? Int { entries.append(try activityEntry(db, id)) }
        }
        return entries
    }

    private static func localBoundary(_ date: Date) -> String {
        dateFormatter("yyyy-MM-dd'T'HH:mm:ss'.000000+00:00'", zone: TimeZone(secondsFromGMT: 0)!).string(from: date)
    }

    private static func profile(_ db: OpaquePointer) throws -> Row {
        let row = try Self.rows(db, "SELECT height_mm,date_of_birth FROM profile_settings WHERE id=1").first
        let birth = row?["date_of_birth"] as? String
        var age: Int? = nil
        if let birth, let date = dateFormatter("yyyy-MM-dd", zone: .current).date(from: birth) {
            let years = Calendar.current.dateComponents([.year], from: date, to: Date()).year
            age = years
        }
        return ["heightCm": row?["height_mm"].map { String(format: "%.1f", Double($0 as? Int ?? 0) / 10) } ?? NSNull(), "dateOfBirth": birth as Any? ?? NSNull(), "age": age as Any? ?? NSNull()]
    }

    private static func measurement(_ row: Row) -> Row {
        ["id": row["id"] ?? 0, "date": row["entry_date"] ?? "", "measurementType": row["measurement_type"] ?? "", "weightKg": row["weight_grams"].map { String(format: "%.3f", Double($0 as? Int ?? 0) / 1000).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) } ?? NSNull(), "waistCm": row["waist_mm"].map { String(format: "%.1f", Double($0 as? Int ?? 0) / 10) } ?? NSNull(), "createdAt": row["created_at"] ?? "", "updatedAt": row["updated_at"] ?? ""]
    }

    private static func measurementTrends(_ db: OpaquePointer) throws -> Row {
        var latest: Row = [:]; var trends: Row = [:]
        for (metric, column, factor) in [("weight", "weight_grams", 1000.0), ("waist", "waist_mm", 10.0)] {
            let rows = try Self.rows(db, "WITH ranked AS (SELECT entry_date,value,NTILE(100) OVER (ORDER BY entry_date,id) bucket FROM (SELECT entry_date,\(column) value,id FROM body_measurements WHERE \(column) IS NOT NULL)) SELECT MIN(entry_date) AS date,AVG(value) AS value FROM ranked GROUP BY bucket ORDER BY MIN(entry_date)")
            let current = try Self.rows(db, "SELECT entry_date AS date,\(column) AS value FROM body_measurements WHERE \(column) IS NOT NULL ORDER BY entry_date DESC,id DESC LIMIT 1").first
            latest[metric] = current.map { ["date": $0["date"] ?? "", "value": Self.measureValue($0["value"], factor: factor)] } as Any? ?? NSNull()
            trends[metric] = rows.map { ["date": $0["date"] ?? "", "value": Self.measureValue($0["value"], factor: factor)] }
        }
        return ["latest": latest, "trends": trends]
    }

    private static func measureValue(_ value: Any?, factor: Double) -> String {
        let number = (value as? Double) ?? Double(value as? Int ?? 0)
        let normalized = factor == 1000 ? number.rounded() : number
        return String(format: factor == 1000 ? "%.3f" : "%.1f", normalized / factor).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    private static func scaledInteger(_ value: Any?, factor: Double, label: String, maximum: Double) throws -> Int? {
        guard let raw = value as? String, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let number = Double(raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")), number.isFinite, number > 0, number <= maximum else { throw WorkoutError("\(label) must be a positive number no greater than \(maximum).") }
        let scaled = Int((number * factor).rounded())
        guard scaled > 0 else { throw WorkoutError("\(label) is too small.") }
        return scaled
    }

    private static func millimetres(_ value: Any?, label: String, maximum: Double) throws -> Int? {
        try scaledInteger(value, factor: 10, label: label, maximum: maximum)
    }

    private static func displayName(_ value: Any?, limit: Int) throws -> String {
        let name = (value as? String ?? "").precomposedStringWithCompatibilityMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty, name.count <= limit else { throw WorkoutError("Enter a name with up to \(limit) characters.") }
        return name
    }

    private static func activityNameKey(_ name: String) -> String {
        // shortcut: POSIX lowercasing is not full Unicode casefolding; replace if exotic casing is used in activity names.
        name.precomposedStringWithCompatibilityMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func validDay(_ day: String) -> Bool {
        let formatter = dateFormatter("yyyy-MM-dd", zone: .current)
        guard let date = formatter.date(from: day) else { return false }
        return formatter.string(from: date) == day
    }

    private static func today() -> String { dateFormatter("yyyy-MM-dd", zone: .current).string(from: Date()) }
    private static func parseInstant(_ value: String) -> Date? {
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private static func instantString(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date)
    }
    private static func sameLocalDay(_ a: Date, _ b: Date) -> Bool { Calendar.current.isDate(a, inSameDayAs: b) }
    private static func validActivityStart(_ value: String) -> Bool {
        let format = "yyyy-MM-dd'T'HH:mm"
        let formatter = dateFormatter(format, zone: .current)
        let localValue = String(value.prefix(16))
        guard let date = formatter.date(from: localValue), formatter.string(from: date) == localValue else { return false }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 24, parts.minute ?? 60) <= (23, 58)
    }
}

private extension Array where Element == String {
    subscript(safe index: Int) -> String? { indices.contains(index) ? self[index] : nil }
}
