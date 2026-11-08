import Foundation
import SQLite3
import ImageIO
import UniformTypeIdentifiers

extension LocalLedger {
    private static let equipmentNames = [
        "resistance_band": "Resistance Bands", "resistance_tube": "Resistance tubes",
        "dumbbell": "Dumbbells", "barbell": "Barbell", "kettlebell": "Kettlebell",
        "cable": "Cable", "weight_machine": "Weight Machine", "weighted_vest": "Weighted Vest",
        "weight_plate": "Weight Plate", "ankle_weights": "Ankle Weights", "sandbag": "Sandbag"
    ]

    static func exerciseDetails(_ db: OpaquePointer, _ exercise: Row) throws -> Row {
        guard let id = exercise["id"] as? Int else { throw Failure.database }
        let muscles = try rows(db, "SELECT muscle_slug, role FROM exercise_muscles WHERE exercise_id = ? ORDER BY muscle_slug", [id])
        var result = exercise
        result["primaryMuscle"] = muscles.first { $0["role"] as? String == "primary" }?["muscle_slug"] ?? NSNull()
        result["secondaryMuscles"] = muscles.filter { $0["role"] as? String == "secondary" }.compactMap { $0["muscle_slug"] as? String }
        return result
    }

    func changeExercise(_ route: [String], method: String, payload: Row) throws -> Row {
        let id = route.count >= 3 ? Int(route[2]) : nil
        let stamp = try Self.instant(nil, zone: .current)
        if let id, route.count == 3, method == "DELETE" {
            guard payload["confirmation"] as? String == "DELETE" else {
                throw WorkoutError("Type DELETE to permanently delete this exercise.")
            }
            try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { db in
                guard try !Self.rows(db, "SELECT id FROM exercises WHERE id = ?", [id]).isEmpty else {
                    throw WorkoutError("Exercise not found.")
                }
                guard try Self.rows(db, "SELECT id FROM workout_exercises WHERE exercise_id = ? LIMIT 1", [id]).isEmpty else {
                    throw WorkoutError("Remove this exercise from its workouts before deleting it.")
                }
            }
            try keepRecoveryBackup()
        }
        return try write { db in
            if route.count == 2 && method == "POST" {
                let base = try Self.exerciseName(payload["baseName"])
                let equipment = payload["equipment"] as? String
                let custom = equipment == "other" ? try Self.exerciseName(payload["customEquipment"], limit: 80) : nil
                let allowsBodyweight = payload["allowBodyweight"] as? Bool ?? true
                guard equipment != nil || allowsBodyweight else { throw WorkoutError("Allow bodyweight or choose equipment.") }
                let name = try Self.exerciseTitle(base, equipment, custom)
                let normalized = Self.foldExerciseName(name)
                try Self.checkExerciseName(db, normalized)
                guard let measurement = payload["measurementType"] as? String,
                      ["repetitions", "duration", "timed_repetitions"].contains(measurement) else {
                    throw WorkoutError("Choose a measurement type.")
                }
                let image = try Self.exerciseImageKey(db, payload["imageKey"])
                let equipmentValue = equipment as Any? ?? NSNull()
                let customValue = custom as Any? ?? NSNull()
                _ = try Self.rows(db, """
                    INSERT INTO exercises(name, normalized_name, base_name, measurement_type,
                        default_resistance_kind, default_equipment, default_custom_equipment, image_key,
                        equipment, custom_equipment, allow_bodyweight, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [name, normalized, base, measurement, equipment == nil ? "bodyweight" : "external",
                          equipmentValue, customValue, image, equipmentValue, customValue, allowsBodyweight ? 1 : 0,
                          stamp, stamp])
                let created = Int(sqlite3_last_insert_rowid(db))
                try Self.saveMuscles(db, created, payload)
                return try Self.exercise(db, created)
            }
            guard let id, let current = try Self.rows(db, "SELECT * FROM exercises WHERE id = ?", [id]).first else {
                throw WorkoutError("Exercise not found.")
            }
            if route.count == 3 && method == "PATCH" {
                let base = try Self.exerciseName(payload["baseName"])
                let equipment = current["equipment"] as? String
                let custom = current["custom_equipment"] as? String
                let previousBase = current["base_name"] as? String ?? ""
                let generated = try? Self.exerciseTitle(previousBase, equipment, custom)
                let name = generated == current["name"] as? String ? try Self.exerciseTitle(base, equipment, custom) : base
                let normalized = Self.foldExerciseName(name)
                try Self.checkExerciseName(db, normalized, excluding: id)
                let image = try Self.exerciseImageKey(db, payload["imageKey"])
                _ = try Self.rows(db, """
                    UPDATE exercises SET name = ?, normalized_name = ?, base_name = ?, image_key = ?, updated_at = ?
                    WHERE id = ?
                    """, [name, normalized, base, image, stamp, id])
                if payload["primaryMuscle"] != nil { try Self.saveMuscles(db, id, payload) }
            } else if route.count == 4 && route[3] == "note" && method == "PUT", let body = payload["body"] as? String {
                let note: Any = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSNull() : body
                _ = try Self.rows(db, "UPDATE exercises SET exercise_note = ?, updated_at = ? WHERE id = ?", [note, stamp, id])
            } else if route.count == 4 && ["archive", "restore"].contains(route[3]) && method == "POST" {
                let archiving = route[3] == "archive"
                if archiving { try Self.removeExerciseFromRotations(db, id) }
                let archived: Any = archiving ? stamp : NSNull()
                _ = try Self.rows(db, "UPDATE exercises SET archived_at = ?, updated_at = ? WHERE id = ?", [archived, stamp, id])
            } else if route.count == 3 && method == "DELETE" {
                try Self.removeExerciseFromRotations(db, id)
                _ = try Self.rows(db, "DELETE FROM exercise_sets WHERE exercise_id = ?", [id])
                _ = try Self.rows(db, "DELETE FROM day_exercises WHERE exercise_id = ?", [id])
                _ = try Self.rows(db, "DELETE FROM exercises WHERE id = ?", [id])
                return [:]
            } else {
                throw WorkoutError("This exercise action is unavailable.")
            }
            return try Self.exercise(db, id)
        }
    }

    private static func exercise(_ db: OpaquePointer, _ id: Int) throws -> Row {
        guard let row = try rows(db, exerciseFields + "WHERE e.id = ?", [id]).first else { throw Failure.database }
        return try exerciseDetails(db, row)
    }

    private static func exerciseName(_ value: Any?, limit: Int = 100) throws -> String {
        let name = (value as? String ?? "").precomposedStringWithCompatibilityMapping
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty, name.count <= limit else {
            throw WorkoutError("Enter a name with up to \(limit) characters.")
        }
        return name
    }

    private static func exerciseTitle(_ base: String, _ equipment: String?, _ custom: String?) throws -> String {
        guard let equipment else { return base }
        guard let suffix = equipment == "other" ? custom : equipmentNames[equipment] else {
            throw WorkoutError("Choose valid equipment.")
        }
        return try exerciseName("\(base) (\(suffix))")
    }

    private static func foldExerciseName(_ name: String) -> String {
        name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func checkExerciseName(_ db: OpaquePointer, _ name: String, excluding id: Int = 0) throws {
        guard try rows(db, "SELECT id FROM exercises WHERE normalized_name = ? AND id <> ?", [name, id]).isEmpty else {
            throw WorkoutError("An exercise with this name already exists.")
        }
    }

    private static func exerciseImageKey(_ db: OpaquePointer, _ value: Any?) throws -> Any {
        guard let key = value as? String else { return NSNull() }
        guard key.count <= 100 else { throw WorkoutError("Choose a valid exercise picture.") }
        if key.hasPrefix("custom:"),
           try rows(db, "SELECT image_key FROM exercise_images WHERE image_key = ?", [key]).isEmpty {
            throw WorkoutError("Exercise picture not found.")
        }
        return key
    }

    private static func saveMuscles(_ db: OpaquePointer, _ id: Int, _ payload: Row) throws {
        let primary = payload["primaryMuscle"] as? String
        let secondary = payload["secondaryMuscles"] as? [String] ?? []
        let all = Set(try rows(db, "SELECT slug FROM muscle_groups").compactMap { $0["slug"] as? String })
        let selected = secondary + (primary.map { [$0] } ?? [])
        guard secondary.count <= 11, Set(selected).count == selected.count, Set(selected).isSubset(of: all) else {
            throw WorkoutError("Choose distinct, valid muscle groups.")
        }
        _ = try rows(db, "DELETE FROM exercise_muscles WHERE exercise_id = ?", [id])
        for muscle in selected {
            _ = try rows(db, "INSERT INTO exercise_muscles(exercise_id, muscle_slug, role) VALUES (?, ?, ?)",
                         [id, muscle, muscle == primary ? "primary" : "secondary"])
        }
    }

    private static func removeExerciseFromRotations(_ db: OpaquePointer, _ id: Int) throws {
        let affected = try rows(db, """
            SELECT DISTINCT r.id, r.due_position FROM rotations r JOIN rotation_members m ON m.rotation_id = r.id
            WHERE m.exercise_id = ?
            """, [id])
        for rotation in affected {
            guard let rotationID = rotation["id"] as? Int else { throw Failure.database }
            let members = try rows(db, """
                SELECT member_id, exercise_id, position FROM rotation_members WHERE rotation_id = ? ORDER BY position
                """, [rotationID])
            let kept = members.filter { $0["exercise_id"] as? Int != id }
            let due = (rotation["due_position"] as? Int).flatMap { position in
                kept.firstIndex { $0["position"] as? Int == position }
            } ?? 0
            _ = try rows(db, "DELETE FROM rotation_members WHERE rotation_id = ? AND exercise_id = ?", [rotationID, id])
            _ = try rows(db, "UPDATE rotation_members SET position = -position - 1 WHERE rotation_id = ?", [rotationID])
            for (position, member) in kept.enumerated() {
                guard let memberID = member["member_id"] as? Int else { throw Failure.database }
                _ = try rows(db, "UPDATE rotation_members SET position = ? WHERE member_id = ?", [position, memberID])
            }
            let dueExercise = kept.isEmpty ? NSNull() : kept[due]["exercise_id"] ?? NSNull()
            let duePosition: Any = kept.isEmpty ? NSNull() : due
            _ = try rows(db, """
                UPDATE rotations SET due_exercise_id = ?, due_position = ?, active = CASE WHEN ? = 0 THEN 0 ELSE active END
                WHERE id = ?
                """, [dueExercise, duePosition, kept.count, rotationID])
        }
    }

    func storeExerciseImage(_ encoded: String) throws -> Row {
        let limit = 50 * 1024 * 1024
        guard encoded.utf8.count <= ((limit + 2) / 3) * 4,
              let bytes = Data(base64Encoded: encoded), bytes.count <= limit,
              let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, height <= 40_000_000 / width,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary) else {
            throw WorkoutError("Choose a valid picture up to 50 MiB and 40 megapixels.")
        }
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.database
        }
        CGImageDestinationAddImage(encoder, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { throw Failure.database }
        let key = "custom:" + UUID().uuidString
        return try write { db in
            _ = try Self.rows(db, "INSERT INTO exercise_images(image_key, jpeg, created_at) VALUES (?, ?, ?)",
                              [key, data as Data, try Self.instant(nil, zone: .current)])
            return ["imageKey": key]
        }
    }
}
