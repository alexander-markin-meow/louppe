import Foundation
import ImageIO

enum MetadataExtractor {

    /// The metadata read once per file during the folder scan.
    struct ScanInfo {
        var captureDate: Date? = nil
        var cameraModel: String? = nil
        var lensModel: String? = nil
        var aperture: Double? = nil
        var shutterSpeed: Double? = nil
        var iso: Double? = nil
    }

    /// Reads the metadata used by filtering and sorting in a single pass during
    /// the scan, so interactive changes never have to re-open every file.
    static func scanInfo(for url: URL) -> ScanInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return ScanInfo()
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let dateString = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        let aperture = numericValue(exif?[kCGImagePropertyExifFNumber])
        let shutterSpeed = numericValue(exif?[kCGImagePropertyExifExposureTime])
        let iso = firstNumericValue(exif?[kCGImagePropertyExifISOSpeedRatings])
        return ScanInfo(
            captureDate: dateString.flatMap { exifDateFormatter.date(from: $0) },
            cameraModel: tiff?[kCGImagePropertyTIFFModel] as? String,
            lensModel: exif?[kCGImagePropertyExifLensModel] as? String,
            aperture: aperture.flatMap { $0 > 0 ? $0 : nil },
            shutterSpeed: shutterSpeed.flatMap { $0 > 0 ? $0 : nil },
            iso: iso.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    /// Full field list for the metadata panel.
    static func fields(for item: PhotoItem) -> [MetadataField] {
        if item.isVideo { return videoFields(for: item) }
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
            add("Captured", AppDateFormat.dayAndTime(date))
        }
        add("Camera", tiff[kCGImagePropertyTIFFModel] as? String)
        add("Lens", exif[kCGImagePropertyExifLensModel] as? String)

        if let focal = numericValue(exif[kCGImagePropertyExifFocalLength]) {
            add("Focal length", String(format: "%.0f mm", focal))
        }
        if let fNumber = numericValue(exif[kCGImagePropertyExifFNumber]) {
            add("Aperture", String(format: "f/%.1f", fNumber))
        }
        if let exposure = numericValue(exif[kCGImagePropertyExifExposureTime]) {
            add("Shutter", formatShutter(exposure))
        }
        if let iso = firstNumericValue(exif[kCGImagePropertyExifISOSpeedRatings]) {
            add("ISO", String(format: "%.0f", iso))
        }
        if let bias = numericValue(exif[kCGImagePropertyExifExposureBiasValue]), bias != 0 {
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

    private static func videoFields(for item: PhotoItem) -> [MetadataField] {
        var fields: [MetadataField] = [
            MetadataField(id: "Filename", label: "Filename", value: item.displayName),
        ]
        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            fields.append(MetadataField(id: label, label: label, value: value))
        }
        if let date = item.captureDate { add("Captured", AppDateFormat.dayAndTime(date)) }
        add("Duration", MediaDurationFormat.display(item.duration))
        if let size = item.videoDimensions {
            add("Dimensions", "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))")
        }
        add("Codec", item.videoCodec)
        if let frameRate = item.videoFrameRate {
            add("Frame rate", String(format: "%.2f fps", frameRate).replacingOccurrences(of: ".00 ", with: " "))
        }
        add("File size", ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
        add("Type", item.fileTypeLabel)
        return fields
    }

    private static func formatShutter(_ seconds: Double) -> String {
        if seconds >= 1 {
            return String(format: "%.1fs", seconds)
        }
        guard seconds > 0 else { return "—" }
        return "1/\(Int((1.0 / seconds).rounded()))s"
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    /// ISO is normally an array in EXIF, but some encoders store a scalar.
    /// Accept both shapes so filtering, sorting, and the Info panel agree.
    private static func firstNumericValue(_ value: Any?) -> Double? {
        if let values = value as? [Any] {
            return values.lazy.compactMap(numericValue).first
        }
        return numericValue(value)
    }

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()
}
