import Foundation
import ImageIO
import SQLite3
import UIKit

extension LocalLedger {
    private func processPhoto(_ value: String) throws -> (Data, Data, Int, Int) {
        guard let encoded = value.split(separator: ",", maxSplits: 1).last,
              let source = Data(base64Encoded: String(encoded)), !source.isEmpty,
              source.count <= 50 * 1024 * 1024,
              let sourceRef = CGImageSourceCreateWithData(source as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(sourceRef, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 80_000_000 / height,
              let image = UIImage(data: source), image.cgImage != nil else {
            throw WorkoutError("Choose a valid image of 50 MiB or smaller.")
        }
        let rotated = [.left, .leftMirrored, .right, .rightMirrored].contains(image.imageOrientation)
        let orientedWidth = rotated ? height : width
        let orientedHeight = rotated ? width : height
        let scale = min(1, 2560 / CGFloat(max(orientedWidth, orientedHeight)))
        let size = CGSize(width: max(1, CGFloat(orientedWidth) * scale), height: max(1, CGFloat(orientedHeight) * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let full = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.82) { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard full.count <= 5 * 1024 * 1024 else { throw WorkoutError("This photo is still too large after compression.") }
        let thumbnailScale = min(1, min(480 / size.width, 480 / size.height))
        let thumbnailSize = CGSize(width: size.width * thumbnailScale, height: size.height * thumbnailScale)
        let thumbnail = UIGraphicsImageRenderer(size: thumbnailSize, format: format).jpegData(withCompressionQuality: 0.82) { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: thumbnailSize))
            image.draw(in: CGRect(origin: .zero, size: thumbnailSize))
        }
        return (full, thumbnail, Int(size.width), Int(size.height))
    }

    func addPhotos(_ day: String, payload: Row) throws -> Row {
        guard Self.validDay(day), day <= Self.today(),
              let images = payload["images"] as? [String], !images.isEmpty else {
            throw WorkoutError("Choose one or more photos for a valid day.")
        }
        guard images.count <= 10 else { throw WorkoutError("A day can contain at most 10 photos.") }
        let processed = try images.map(processPhoto)
        let stamp = try Self.instant(nil, zone: .current)
        return try write { db in
            let count = try Self.rows(db, "SELECT count(*) AS count FROM daily_photos WHERE entry_date = ?", [day]).first?["count"] as? Int ?? 0
            guard count + processed.count <= 10 else { throw WorkoutError("A day can contain at most 10 photos.") }
            guard processed.reduce(0, { $0 + $1.0.count }) <= 100 * 1024 * 1024 else { throw WorkoutError("Photos in one upload must total 100 MiB or less.") }
            for (offset, item) in processed.enumerated() {
                _ = try Self.rows(db, "INSERT INTO daily_photos(entry_date,display_order,jpeg,thumbnail_jpeg,width,height,created_at) VALUES(?,?,?,?,?,?,?)", [day, count + offset + 1, item.0, item.1, item.2, item.3, stamp])
            }
            return ["items": try Self.photoSummaries(db, day: day)]
        }
    }

    func deletePhoto(_ id: Int) throws -> Row {
        guard try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY, { db in
            try !Self.rows(db, "SELECT id FROM daily_photos WHERE id = ?", [id]).isEmpty
        }) else { throw WorkoutError("Photo not found.") }
        try keepRecoveryBackup()
        return try write { db in
            guard let row = try Self.rows(db, "SELECT entry_date,display_order FROM daily_photos WHERE id = ?", [id]).first,
                  let day = row["entry_date"] as? String, let order = row["display_order"] as? Int else { throw WorkoutError("Photo not found.") }
            _ = try Self.rows(db, "DELETE FROM daily_photos WHERE id = ?", [id])
            _ = try Self.rows(db, "UPDATE daily_photos SET display_order = display_order - 1 WHERE entry_date = ? AND display_order > ?", [day, order])
            return [:]
        }
    }
}
