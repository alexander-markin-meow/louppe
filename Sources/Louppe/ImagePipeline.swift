import Foundation
import AppKit
import ImageIO

/// Decodes images with ImageIO (extracting embedded previews for RAW files),
/// caches thumbnails in memory + on disk, and prefetches around the current photo.
// @unchecked Sendable: safe to share across threads — NSCache is thread-safe
// and all other state is set once at init.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let thumbCache = NSCache<NSString, NSImage>()
    private let fullCache = NSCache<NSString, NSImage>()
    private let decodeQueue = DispatchQueue(label: "louppe.decode", qos: .userInitiated, attributes: .concurrent)
    private let prefetchQueue = DispatchQueue(label: "louppe.prefetch", qos: .utility)
    private let diskCacheRoot: URL

    static let thumbPixelSize: CGFloat = 320
    static let fullPixelSize: CGFloat = 4096

    private init() {
        thumbCache.countLimit = 3000
        fullCache.countLimit = 12
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskCacheRoot = caches.appendingPathComponent("Louppe/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheRoot, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    func thumbnail(for url: URL) async -> NSImage? {
        let key = cacheKey(for: url)
        if let cached = thumbCache.object(forKey: key as NSString) { return cached }
        return await withCheckedContinuation { continuation in
            decodeQueue.async { [weak self] in
                continuation.resume(returning: self?.loadThumbnailSync(url: url, key: key))
            }
        }
    }

    func fullImage(for url: URL) async -> NSImage? {
        let key = cacheKey(for: url)
        if let cached = fullCache.object(forKey: key as NSString) { return cached }
        return await withCheckedContinuation { continuation in
            decodeQueue.async { [weak self] in
                continuation.resume(returning: self?.loadFullSync(url: url, key: key))
            }
        }
    }

    /// Warm the full-size cache for the next few photos so navigation feels instant.
    func prefetchFullImages(urls: [URL]) {
        for url in urls {
            let key = cacheKey(for: url)
            if fullCache.object(forKey: key as NSString) != nil { continue }
            prefetchQueue.async { [weak self] in
                _ = self?.loadFullSync(url: url, key: key)
            }
        }
    }

    // MARK: - Decoding

    private func loadThumbnailSync(url: URL, key: String) -> NSImage? {
        if let cached = thumbCache.object(forKey: key as NSString) { return cached }

        // Try the on-disk thumbnail cache first.
        let diskURL = diskCacheRoot.appendingPathComponent(diskFileName(for: key))
        if let data = try? Data(contentsOf: diskURL), let image = NSImage(data: data) {
            thumbCache.setObject(image, forKey: key as NSString)
            return image
        }

        guard let cgImage = decode(url: url, maxPixel: Self.thumbPixelSize) else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        thumbCache.setObject(image, forKey: key as NSString)

        // Persist to disk cache as JPEG (best effort).
        let rep = NSBitmapImageRep(cgImage: cgImage)
        if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            try? jpeg.write(to: diskURL)
        }
        return image
    }

    private func loadFullSync(url: URL, key: String) -> NSImage? {
        if let cached = fullCache.object(forKey: key as NSString) { return cached }
        guard let cgImage = decode(url: url, maxPixel: Self.fullPixelSize) else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        fullCache.setObject(image, forKey: key as NSString)
        return image
    }

    /// ImageIO decode. For RAW files this pulls the embedded preview rather than
    /// doing a full demosaic, which is what keeps the app fast.
    ///
    /// Many JPEGs carry a tiny embedded thumbnail (~160px). Asking ImageIO to
    /// reuse it would return that tiny image upscaled — visibly pixelated. So:
    /// try the fast embedded path first, and if the result is much smaller than
    /// what we asked for, fall back to a real decode of the full image.
    private func decode(url: URL, maxPixel: CGFloat) -> CGImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }

        // The size we actually want: no bigger than the photo itself.
        var target = maxPixel
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions as CFDictionary) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = props[kCGImagePropertyPixelHeight] as? CGFloat {
            target = min(maxPixel, max(width, height))
        }

        let fastOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let fast = CGImageSourceCreateThumbnailAtIndex(source, 0, fastOptions as CFDictionary)
        if let fast, CGFloat(max(fast.width, fast.height)) >= target * 0.9 {
            return fast
        }

        // Embedded preview was too small — decode the real image at full quality.
        let fullOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, fullOptions as CFDictionary) ?? fast
    }

    // MARK: - Cache keys

    private func cacheKey(for url: URL) -> String {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            .flatMap { $0.timeIntervalSince1970 } ?? 0
        // "v2" invalidates thumbnails cached before the pixelation fix.
        return "\(url.path)|\(mtime)|v2"
    }

    private func diskFileName(for key: String) -> String {
        // Stable, filesystem-safe name derived from the cache key.
        var hash: UInt64 = 14695981039346656037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(format: "%016llx.jpg", hash)
    }
}
