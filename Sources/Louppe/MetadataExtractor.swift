import Foundation
import ImageIO

enum MetadataExtractor {

    /// Reads the capture date quickly during the folder scan.
    static func captureDate(for url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let dateString = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        guard let dateString else { return nil }
        return exifDateFormatter.date(from: dateString)
    }

    /// Full field list for the metadata panel.
    static func fields(for item: PhotoItem) -> [MetadataField] {
        var fields: [MetadataField] = []
        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            fields.append(MetadataField(id: label, label: label, value: value))
        }

        add("Filename", item.displayName)
        if let paired = item.pairedURL {
            add("Paired file", paired.lastPathComponent)
        }

        var props: [CFString: Any] = [:]
        if let source = CGImageSourceCreateWithURL(item.primaryURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            props = p
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        if let date = item.captureDate {
            add("Captured", displayDateFormatter.string(from: date))
        }
        add("Camera", tiff[kCGImagePropertyTIFFModel] as? String)
        add("Lens", exif[kCGImagePropertyExifLensModel] as? String)

        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
            add("Focal length", String(format: "%.0f mm", focal))
        }
        if let fNumber = exif[kCGImagePropertyExifFNumber] as? Double {
            add("Aperture", String(format: "f/%.1f", fNumber))
        }
        if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double {
            add("Shutter", formatShutter(exposure))
        }
        if let isoValues = exif[kCGImagePropertyExifISOSpeedRatings] as? [Any],
           let iso = isoValues.first {
            add("ISO", "\(iso)")
        }
        if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? Double, bias != 0 {
            add("Exposure comp.", String(format: "%+.1f EV", bias))
        } else if exif[kCGImagePropertyExifExposureBiasValue] != nil {
            add("Exposure comp.", "0 EV")
        }
        if let wb = exif[kCGImagePropertyExifWhiteBalance] as? Int {
            add("White balance", wb == 0 ? "Auto" : "Manual")
        }
        if let width = props[kCGImagePropertyPixelWidth] as? Int,
           let height = props[kCGImagePropertyPixelHeight] as? Int {
            add("Dimensions", "\(width) × \(height)")
        }
        add("File size", ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
        add("Type", item.fileTypeLabel)

        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            add("GPS", String(format: "%.5f°%@, %.5f°%@", lat, latRef, lon, lonRef))
        }
        return fields
    }

    private static func formatShutter(_ seconds: Double) -> String {
        if seconds >= 1 {
            return String(format: "%.1fs", seconds)
        }
        guard seconds > 0 else { return "—" }
        return "1/\(Int((1.0 / seconds).rounded()))s"
    }

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}
