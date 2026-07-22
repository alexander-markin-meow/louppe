import Foundation
import AppKit
import ImageIO
import AVFoundation

/// Decodes images with ImageIO (extracting embedded previews for RAW files),
/// caches thumbnails in memory + on disk, and prefetches around the current photo.
// @unchecked Sendable: safe to share across threads — NSCache and the queues
// are thread-safe; the only mutable dictionary is protected by `inFlightLock`.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let thumbCache = NSCache<NSString, NSImage>()
    private let fullCache = NSCache<NSString, NSImage>()
    private let fullDecodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "louppe.decode.full"
        // Two large decodes keep navigation responsive without allowing fast
        // key-repeat to saturate every CPU core and multiply peak memory.
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let thumbnailDecodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "louppe.decode.thumbnail"
        // Thumbnails are small (320 px, ~0.4 MB decoded), so a wider lane
        // fills a fresh Grid noticeably faster without the peak-memory risk
        // that keeps the full-size queue at two. A separate queue also means
        // the current photo's full decode never waits behind tile backlog.
        queue.maxConcurrentOperationCount = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let diskQueue = DispatchQueue(label: "louppe.thumbnail-disk-cache", qos: .utility)
    private let diskCacheRoot: URL

    private enum DecodeKind: Hashable { case thumbnail, full }
    private struct DecodeRequest: Hashable {
        let kind: DecodeKind
        let key: String
    }
    private final class PendingDecode {
        var waiters: [CheckedContinuation<NSImage?, Never>]
        let operation: BlockOperation

        init(waiters: [CheckedContinuation<NSImage?, Never>], operation: BlockOperation) {
            self.waiters = waiters
            self.operation = operation
        }
    }
    private final class GeneratedImageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var image: CGImage?

        func store(_ image: CGImage?) {
            lock.lock()
            self.image = image
            lock.unlock()
        }

        func load() -> CGImage? {
            lock.lock()
            defer { lock.unlock() }
            return image
        }
    }
    private let inFlightLock = NSLock()
    private var inFlight: [DecodeRequest: PendingDecode] = [:]

    static let thumbPixelSize: CGFloat = 320
    static let fullPixelSize: CGFloat = 4096

    private init() {
        thumbCache.countLimit = 1200
        thumbCache.totalCostLimit = 256 * 1024 * 1024
        fullCache.countLimit = 8
        fullCache.totalCostLimit = 384 * 1024 * 1024
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        diskCacheRoot = caches.appendingPathComponent("Louppe/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheRoot, withIntermediateDirectories: true)
        diskQueue.async { [diskCacheRoot] in
            Self.pruneDiskCache(at: diskCacheRoot)
        }
    }

    // MARK: - Public API

    /// Synchronous memory-cache-only lookups — cheap enough to call during
    /// view construction. They let the Gallery view show *something* the very
    /// frame the photo changes (the prefetched full image, or the Browser
    /// thumbnail as a low-res preview) instead of flashing an empty pane.
    func cachedFullImage(for item: PhotoItem) -> NSImage? {
        fullCache.object(forKey: Self.cacheKey(for: item) as NSString)
    }

    func cachedThumbnail(for item: PhotoItem) -> NSImage? {
        thumbCache.object(forKey: Self.cacheKey(for: item) as NSString)
    }

    func thumbnail(for item: PhotoItem) async -> NSImage? {
        let key = Self.cacheKey(for: item)
        if let cached = thumbCache.object(forKey: key as NSString) { return cached }
        return await decodeOnce(
            kind: .thumbnail,
            key: key,
            qualityOfService: .userInitiated,
            queuePriority: .normal
        ) { [self] in
            loadThumbnailSync(item: item, key: key)
        }
    }

    func fullImage(for item: PhotoItem) async -> NSImage? {
        let key = Self.cacheKey(for: item)
        if let cached = fullCache.object(forKey: key as NSString) { return cached }
        return await fullImage(
            for: item.primaryURL,
            key: key,
            qualityOfService: .userInitiated,
            queuePriority: .veryHigh
        )
    }

    private func fullImage(
        for url: URL,
        key: String,
        qualityOfService: QualityOfService,
        queuePriority: Operation.QueuePriority
    ) async -> NSImage? {
        await decodeOnce(
            kind: .full,
            key: key,
            qualityOfService: qualityOfService,
            queuePriority: queuePriority
        ) { [self] in
            loadFullSync(url: url, key: key)
        }
    }

    /// Warm the full-size cache for the next few photos so navigation feels instant.
    func prefetchFullImages(items: [PhotoItem]) {
        for item in items {
            let key = Self.cacheKey(for: item)
            if fullCache.object(forKey: key as NSString) != nil { continue }
            Task.detached(priority: .utility) { [weak self] in
                _ = await self?.fullImage(
                    for: item.primaryURL,
                    key: key,
                    qualityOfService: .utility,
                    queuePriority: .low
                )
            }
        }
    }

    /// Coalesce all callers waiting for the same decode. Cancellation of one
    /// SwiftUI task does not throw away work another tile/prefetch may need;
    /// the shared bounded operation completes and warms the cache once.
    private func decodeOnce(
        kind: DecodeKind,
        key: String,
        qualityOfService: QualityOfService,
        queuePriority: Operation.QueuePriority,
        work: @escaping @Sendable () -> NSImage?
    ) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let request = DecodeRequest(kind: kind, key: key)
            inFlightLock.lock()
            if let pending = inFlight[request] {
                pending.waiters.append(continuation)
                // A visible photo may join a utility prefetch already waiting
                // in the queue. Promote that shared operation immediately.
                if queuePriority == .veryHigh {
                    pending.operation.queuePriority = .veryHigh
                    pending.operation.qualityOfService = .userInitiated
                }
                inFlightLock.unlock()
                return
            }

            let operation = BlockOperation { [weak self] in
                let result = work()
                self?.finish(request, result: result)
            }
            operation.qualityOfService = qualityOfService
            operation.queuePriority = queuePriority
            inFlight[request] = PendingDecode(waiters: [continuation], operation: operation)
            inFlightLock.unlock()
            switch kind {
            case .thumbnail: thumbnailDecodeQueue.addOperation(operation)
            case .full: fullDecodeQueue.addOperation(operation)
            }
        }
    }

    private func finish(_ request: DecodeRequest, result: NSImage?) {
        inFlightLock.lock()
        let waiters = inFlight.removeValue(forKey: request)?.waiters ?? []
        inFlightLock.unlock()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    // MARK: - Decoding

    private func loadThumbnailSync(item: PhotoItem, key: String) -> NSImage? {
        if let cached = thumbCache.object(forKey: key as NSString) { return cached }

        // Try the on-disk thumbnail cache first.
        let diskURL = diskCacheRoot.appendingPathComponent(diskFileName(for: key))
        if let cgImage = decode(url: diskURL, maxPixel: Self.thumbPixelSize) {
            let image = NSImage(cgImage: cgImage, size: .zero)
            thumbCache.setObject(image, forKey: key as NSString, cost: Self.cost(of: cgImage))
            return image
        }

        let cgImage = item.isVideo
            ? decodeFirstVideoFrame(url: item.primaryURL, maxPixel: Self.thumbPixelSize)
            : decode(url: item.primaryURL, maxPixel: Self.thumbPixelSize)
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        thumbCache.setObject(image, forKey: key as NSString, cost: Self.cost(of: cgImage))

        // The decoded image can render immediately; JPEG compression and disk
        // writing are best-effort background maintenance.
        diskQueue.async {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                try? jpeg.write(to: diskURL, options: .atomic)
            }
        }
        return image
    }

    private func loadFullSync(url: URL, key: String) -> NSImage? {
        if let cached = fullCache.object(forKey: key as NSString) { return cached }
        guard let cgImage = decode(url: url, maxPixel: Self.fullPixelSize) else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        fullCache.setObject(image, forKey: key as NSString, cost: Self.cost(of: cgImage))
        return image
    }

    /// Exact first displayable movie frame. This runs on the existing bounded
    /// thumbnail queue, never the main actor, and shares image thumbnails'
    /// memory/disk caching and request coalescing.
    private func decodeFirstVideoFrame(url: URL, maxPixel: CGFloat) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let box = GeneratedImageBox()
        let semaphore = DispatchSemaphore(value: 0)
        generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in
            box.store(image)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 15) == .success else {
            generator.cancelAllCGImageGeneration()
            return nil
        }
        return box.load()
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

    /// Internal so the performance checks can enforce that cache lookup stays
    /// independent of the live filesystem after scanning.
    static func cacheKey(for item: PhotoItem) -> String {
        let mtime = item.primaryModificationDate?.timeIntervalSince1970 ?? 0
        // v3 adds video first-frame thumbnails to the shared cache.
        return "\(item.primaryURL.path)|\(mtime)|\(item.mediaKind.rawValue)|v3"
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

    private static func cost(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    /// Keep the persistent cache useful but bounded. Pruning runs once at app
    /// startup on the disk queue and never delays view construction.
    private static func pruneDiskCache(at root: URL) {
        let fm = FileManager()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) else { return }
        let cutoff = Date().addingTimeInterval(-90 * 24 * 60 * 60)
        var files: [(url: URL, size: Int64, date: Date)] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let date = values.contentModificationDate ?? .distantPast
            if date < cutoff {
                try? fm.removeItem(at: url)
            } else {
                files.append((url, Int64(values.fileSize ?? 0), date))
            }
        }

        let limit: Int64 = 512 * 1024 * 1024
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return }
        for file in files.sorted(by: { $0.date < $1.date }) where total > limit {
            if (try? fm.removeItem(at: file.url)) != nil {
                total -= file.size
            }
        }
    }
}
