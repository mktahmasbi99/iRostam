import Foundation
import SQLite3

extension LocalLedger {
    private static func rotationToday() -> String {
        dateFormatter("yyyy-MM-dd", zone: .current).string(from: Date())
    }

    func rotationList(_ status: String) throws -> [Row] {
        guard ["active", "archived", "all"].contains(status) else {
            throw WorkoutError("Rotation status must be active, archived, or all.")
        }
        return try write { db in
            let filter = status == "all" ? "" : status == "archived" ? " WHERE archived_at IS NOT NULL" : " WHERE archived_at IS NULL"
            let ids = try Self.rows(db, "SELECT id FROM rotations\(filter) ORDER BY id")
            for item in ids {
                guard let id = item["id"] as? Int else { throw Failure.database }
                if try Self.rows(db, "SELECT active FROM rotations WHERE id = ?", [id]).first?["active"] as? Int == 1 {
                    try Self.rollRotation(db, id)
                }
            }
            return try ids.map { try serializeRotation(db, $0["id"] as! Int) }
        }
    }

    func rotationRecommendations(_ days: Int) throws -> [Row] {
        guard days > 0, days <= 100_000,
              let start = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1 - days, to: Date()) else {
            throw WorkoutError("Choose a valid history period.")
        }
        let today = Self.rotationToday()
        let first = Self.dateFormatter("yyyy-MM-dd", zone: .current).string(from: start)
        return try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { db in
            try Self.rows(db, """
                SELECT de.exercise_id AS exerciseId, de.entry_date AS date
                FROM day_exercises de JOIN exercises e ON e.id = de.exercise_id
                WHERE de.entry_date BETWEEN ? AND ? AND e.archived_at IS NULL
                ORDER BY de.entry_date, de.display_order
                """, [first, today]).map { row in
                    guard let id = row["exerciseId"] as? Int,
                          let exercise = try Self.rows(db, Self.exerciseFields + "WHERE e.id = ?", [id]).first else {
                        throw Failure.database
                    }
                    return ["exercise": try Self.exerciseDetails(db, exercise), "date": row["date"] ?? NSNull()]
                }
        }
    }

    func changeRotation(_ path: String, method: String, payload: Row) throws -> Row {
        guard let url = URLComponents(string: path) else { throw Failure.database }
        let route = url.path.split(separator: "/").map(String.init)
        return try write { db in
            let stamp = try Self.instant(nil, zone: .current)
            if route == ["api", "rotations"], method == "POST" {
                let name = try rotationName(payload["name"])
                _ = try Self.rows(db, "INSERT INTO rotations(name) VALUES (?)", [name])
                return try serializeRotation(db, Int(sqlite3_last_insert_rowid(db)))
            }
            guard route.count >= 3, route.prefix(2) == ["api", "rotations"], let id = Int(route[2]),
                  try !Self.rows(db, "SELECT id FROM rotations WHERE id = ?", [id]).isEmpty else {
                throw WorkoutError("Rotation not found.")
            }
            if route.count == 3 && method == "PATCH" {
                _ = try Self.rows(db, "UPDATE rotations SET name = ? WHERE id = ?", [try rotationName(payload["name"]), id])
            } else if route.count == 3 && method == "DELETE" {
                _ = try Self.rows(db, "DELETE FROM rotations WHERE id = ?", [id])
                return [:]
            } else if route.count == 4 && ["archive", "restore"].contains(route[3]) && method == "POST" {
                if route[3] == "archive" {
                    _ = try Self.rows(db, "UPDATE rotations SET archived_at = ?, active = 0 WHERE id = ?", [stamp, id])
                } else {
                    _ = try Self.rows(db, "UPDATE rotations SET archived_at = NULL WHERE id = ?", [id])
                }
            } else if route.count == 4 && route[3] == "members" && method == "PUT" {
                try setMembers(db, id, payload["exerciseIds"] as? [Int] ?? [])
            } else if route.count == 4 && route[3] == "activate" && method == "POST" {
                let members = try Self.rotationMembers(db, id)
                guard let position = payload["firstPosition"] as? Int, members.indices.contains(position) else {
                    throw WorkoutError("Choose an exercise in this rotation to start with.")
                }
                _ = try Self.rows(db, "UPDATE rotations SET active = 0 WHERE active = 1")
                _ = try Self.rows(db, """
                    UPDATE rotations SET active = 1, due_exercise_id = ?, due_position = ?,
                        resolved_date = NULL, resolved_kind = NULL WHERE id = ?
                    """, [members[position]["exercise_id"]!, position, id])
                try Self.resolveRotationIfLogged(db, id, Self.rotationToday())
            } else if route.count == 4 && route[3] == "deactivate" && method == "POST" {
                _ = try Self.rows(db, "UPDATE rotations SET active = 0 WHERE id = ?", [id])
            } else if route.count == 4 && route[3] == "skip-today" && ["POST", "DELETE"].contains(method) {
                try Self.rollRotation(db, id)
                guard let fresh = try Self.rows(db, "SELECT * FROM rotations WHERE id = ?", [id]).first,
                      fresh["active"] as? Int == 1, !(fresh["due_exercise_id"] is NSNull) else {
                    throw WorkoutError("Activate a rotation with members first.")
                }
                let today = Self.rotationToday()
                if method == "DELETE" {
                    guard fresh["resolved_date"] as? String == today, fresh["resolved_kind"] as? String == "skipped" else {
                        throw WorkoutError("There is no skip to undo today.")
                    }
                    _ = try Self.rows(db, "UPDATE rotations SET resolved_date = NULL, resolved_kind = NULL WHERE id = ?", [id])
                    try Self.resolveRotationIfLogged(db, id, today)
                } else {
                    guard fresh["resolved_date"] as? String != today else {
                        throw WorkoutError("Today's due exercise is already resolved.")
                    }
                    _ = try Self.rows(db, "UPDATE rotations SET resolved_date = ?, resolved_kind = 'skipped' WHERE id = ?", [today, id])
                }
            } else {
                throw WorkoutError("This rotation action is unavailable.")
            }
            return try serializeRotation(db, id)
        }
    }

    private func rotationName(_ value: Any?) throws -> String {
        let name = (value as? String ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty, name.count <= 100 else { throw WorkoutError("Rotation name must be 1–100 characters.") }
        return name
    }

    private static func rotationMembers(_ db: OpaquePointer, _ id: Int) throws -> [Row] {
        try Self.rows(db, "SELECT member_id, exercise_id, position FROM rotation_members WHERE rotation_id = ? ORDER BY position", [id])
    }

    private func setMembers(_ db: OpaquePointer, _ id: Int, _ exerciseIDs: [Int]) throws {
        for exerciseID in exerciseIDs {
            guard let exercise = try Self.rows(db, "SELECT archived_at FROM exercises WHERE id = ?", [exerciseID]).first else {
                throw WorkoutError("Exercise not found.")
            }
            guard exercise["archived_at"] is NSNull else { throw WorkoutError("Archived exercises cannot join a rotation.") }
        }
        let old = try Self.rotationMembers(db, id)
        let rotation = try Self.rows(db, "SELECT due_position FROM rotations WHERE id = ?", [id]).first
        let dueID = (rotation?["due_position"] as? Int).flatMap { old.indices.contains($0) ? old[$0]["member_id"] as? Int : nil }
        var available = old
        var ordered: [Int] = []
        for exerciseID in exerciseIDs {
            if let index = available.firstIndex(where: { $0["exercise_id"] as? Int == exerciseID }) {
                ordered.append(available.remove(at: index)["member_id"] as! Int)
            } else {
                _ = try Self.rows(db, "INSERT INTO rotation_members(rotation_id, exercise_id, position) VALUES (?, ?, ?)", [id, exerciseID, -1_000_000_000 - ordered.count])
                ordered.append(Int(sqlite3_last_insert_rowid(db)))
            }
        }
        for member in available { _ = try Self.rows(db, "DELETE FROM rotation_members WHERE member_id = ?", [member["member_id"]!]) }
        _ = try Self.rows(db, "UPDATE rotation_members SET position = -member_id WHERE rotation_id = ?", [id])
        for (position, memberID) in ordered.enumerated() {
            _ = try Self.rows(db, "UPDATE rotation_members SET position = ?, auto_order = 0 WHERE member_id = ?", [position, memberID])
        }
        let duePosition = dueID.flatMap { ordered.firstIndex(of: $0) } ?? (ordered.isEmpty ? nil : 0)
        let dueExercise: Any = duePosition.map { exerciseIDs[$0] } ?? NSNull() as Any
        _ = try Self.rows(db, "UPDATE rotations SET due_exercise_id = ?, due_position = ? WHERE id = ?", [dueExercise, duePosition as Any? ?? NSNull(), id])
        try Self.rollRotation(db, id)
    }

    private static func rollRotation(_ db: OpaquePointer, _ id: Int) throws {
        guard let rotation = try Self.rows(db, "SELECT * FROM rotations WHERE id = ?", [id]).first else { throw WorkoutError("Rotation not found.") }
        let members = try Self.rotationMembers(db, id)
        let today = Self.rotationToday()
        var duePosition = rotation["due_position"] as? Int
        if duePosition == nil || !members.indices.contains(duePosition!) {
            duePosition = members.isEmpty ? nil : 0
            let due: Any = duePosition.map { members[$0]["exercise_id"]! } ?? NSNull() as Any
            _ = try Self.rows(db, "UPDATE rotations SET due_exercise_id = ?, due_position = ?, resolved_date = NULL, resolved_kind = NULL WHERE id = ?", [due, duePosition as Any? ?? NSNull(), id])
        } else if let resolved = rotation["resolved_date"] as? String, resolved < today, let start = duePosition {
            for offset in 1...max(members.count, 1) {
                let candidatePosition = (start + offset) % members.count
                let isNewlyDone = try !Self.rows(db, """
                    SELECT 1 FROM rotation_members m WHERE m.rotation_id = ? AND m.position = ? AND m.enrolled_date = ?
                    AND EXISTS (SELECT 1 FROM exercise_sets s WHERE s.exercise_id = m.exercise_id AND s.workout_exercise_id IS NULL AND s.entry_date = m.enrolled_date)
                    """, [id, candidatePosition, resolved]).isEmpty
                if !isNewlyDone { duePosition = candidatePosition; break }
            }
            let due: Any = duePosition.map { members[$0]["exercise_id"]! } ?? NSNull() as Any
            _ = try Self.rows(db, "UPDATE rotations SET due_exercise_id = ?, due_position = ?, resolved_date = NULL, resolved_kind = NULL WHERE id = ?", [due, duePosition as Any? ?? NSNull(), id])
        }
    }

    private static func resolveRotationIfLogged(_ db: OpaquePointer, _ id: Int, _ day: String) throws {
        guard let rotation = try Self.rows(db, "SELECT due_exercise_id FROM rotations WHERE id = ?", [id]).first,
              let due = rotation["due_exercise_id"] as? Int,
              try !Self.rows(db, "SELECT 1 FROM exercise_sets WHERE workout_exercise_id IS NULL AND entry_date = ? AND exercise_id = ? LIMIT 1", [day, due]).isEmpty else { return }
        _ = try Self.rows(db, "UPDATE rotations SET resolved_date = ?, resolved_kind = 'completed' WHERE id = ?", [day, id])
    }

    static func updateActiveRotationAfterSet(_ db: OpaquePointer, day: String) throws {
        guard let active = try Self.rows(db, "SELECT id FROM rotations WHERE active = 1").first,
              let id = active["id"] as? Int else { return }
        try rollRotation(db, id)
        try resolveRotationIfLogged(db, id, day)
        guard let state = try Self.rows(db, "SELECT resolved_date, resolved_kind, due_exercise_id FROM rotations WHERE id = ?", [id]).first,
              state["resolved_date"] as? String == day, state["resolved_kind"] as? String == "completed",
              let due = state["due_exercise_id"] as? Int,
              try Self.rows(db, "SELECT 1 FROM exercise_sets WHERE workout_exercise_id IS NULL AND entry_date = ? AND exercise_id = ? LIMIT 1", [day, due]).isEmpty else { return }
        _ = try Self.rows(db, "UPDATE rotations SET resolved_date = NULL, resolved_kind = NULL WHERE id = ?", [id])
    }

    private func serializeRotation(_ db: OpaquePointer, _ id: Int) throws -> Row {
        guard let rotation = try Self.rows(db, "SELECT * FROM rotations WHERE id = ?", [id]).first else { throw WorkoutError("Rotation not found.") }
        let today = Self.rotationToday()
        let todayDate = Self.dateFormatter("yyyy-MM-dd", zone: .current).date(from: today)!
        let members = try Self.rotationMembers(db, id).map { member -> Row in
            guard let exerciseID = member["exercise_id"] as? Int,
                  let exercise = try Self.rows(db, Self.exerciseFields + "WHERE e.id = ?", [exerciseID]).first else { throw Failure.database }
            let detailed = try Self.exerciseDetails(db, exercise)
            let last = try Self.rows(db, "SELECT MAX(entry_date) AS date FROM exercise_sets WHERE workout_exercise_id IS NULL AND exercise_id = ? AND entry_date <= ?", [exerciseID, today]).first?["date"] as? String
            let since = last.flatMap { Self.dateFormatter("yyyy-MM-dd", zone: .current).date(from: $0) }.map { Calendar.current.dateComponents([.day], from: $0, to: todayDate).day ?? 0 }
            return ["exercise": detailed, "position": member["position"]!, "lastDoneDate": last as Any? ?? NSNull(), "daysSinceLastDone": since as Any? ?? NSNull()]
        }
        return ["id": id, "name": rotation["name"]!, "active": (rotation["active"] as? Int ?? 0) == 1,
                "dueExerciseId": rotation["due_exercise_id"] as Any? ?? NSNull(), "duePosition": rotation["due_position"] as Any? ?? NSNull(),
                "resolvedToday": rotation["resolved_date"] as? String == today ? rotation["resolved_kind"] as Any? ?? NSNull() : NSNull(),
                "archivedAt": rotation["archived_at"] as Any? ?? NSNull(), "members": members]
    }
}
