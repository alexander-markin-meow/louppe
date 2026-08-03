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
    private static let lastDiskPruneDefaultsKey =
        "LouppeThumbnailCacheLastPrune"

    static let thumbPixelSize: CGFloat = 320
    static let fullPixelSize: CGFloat = 4096

    private convenience init() {
        let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        self.init(
            diskCacheRoot: caches.appendingPathComponent(
                "Louppe/Thumbnails",
                isDirectory: true
            ),
            schedulesMaintenance: true
        )
    }

    /// Isolated cache instance for focused tests. Production code always uses
    /// `shared`; this initializer deliberately skips UserDefaults and pruning.
    convenience init(testingDiskCacheRoot: URL) {
        self.init(
            diskCacheRoot: testingDiskCacheRoot,
            schedulesMaintenance: false
        )
    }

    private init(
        diskCacheRoot: URL,
        schedulesMaintenance: Bool
    ) {
        self.diskCacheRoot = diskCacheRoot
        thumbCache.countLimit = 1200
        thumbCache.totalCostLimit = 256 * 1024 * 1024
        fullCache.countLimit = 8
        fullCache.totalCostLimit = 384 * 1024 * 1024
        try? FileManager.default.createDirectory(at: diskCacheRoot, withIntermediateDirectories: true)
        guard schedulesMaintenance else { return }
        let lastPrunedAt = UserDefaults.standard.object(
            forKey: Self.lastDiskPruneDefaultsKey
        ) as? Date
        if Self.shouldPruneDiskCache(
            lastPrunedAt: lastPrunedAt,
            now: Date()
        ) {
            // Cache maintenance can stat thousands of files. Give launch,
            // Gallery rendering, and the first Grid switch uncontested I/O;
            // one delayed daily pass is sufficient for a 90-day cache.
            diskQueue.asyncAfter(deadline: .now() + 30) { [diskCacheRoot] in
                if Self.pruneDiskCache(at: diskCacheRoot) {
                    UserDefaults.standard.set(
                        Date(),
                        forKey: Self.lastDiskPruneDefaultsKey
                    )
                }
            }
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

    /// Test synchronization boundary for best-effort cache promotions/writes.
    func waitForPendingDiskWrites() async {
        await withCheckedContinuation { continuation in
            diskQueue.async {
                continuation.resume()
            }
        }
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
        let diskURL = diskCacheRoot.appendingPathComponent(
            Self.diskFileName(for: key)
        )
        if let cgImage = Self.decodeImage(url: diskURL, maxPixel: Self.thumbPixelSize) {
            let image = NSImage(cgImage: cgImage, size: .zero)
            thumbCache.setObject(image, forKey: key as NSString, cost: Self.cost(of: cgImage))
            return image
        }

        // v5 binds the cache to scan-time physical identity. Identity-less
        // v4/v3 thumbnails are only candidates for synthetic/legacy items
        // that have no scanned identity of their own. Once identity is known,
        // no timestamp comparison can prove which inode produced old cache
        // bytes on every supported filesystem, so production scans take the
        // one-time cold migration and fail closed.
        for legacyKey in Self.compatibilityThumbnailCacheKeys(for: item) {
            let legacyURL = diskCacheRoot.appendingPathComponent(
                Self.diskFileName(for: legacyKey)
            )
            guard Self.compatibilityThumbnailIsSafe(
                at: legacyURL,
                for: item
            ), let cgImage = Self.decodeImage(
                url: legacyURL,
                maxPixel: Self.thumbPixelSize
            ) else { continue }

            let image = NSImage(cgImage: cgImage, size: .zero)
            thumbCache.setObject(
                image,
                forKey: key as NSString,
                cost: Self.cost(of: cgImage)
            )
            // Re-encode the image ImageIO already validated. Atomic write
            // replaces a corrupt v5 destination as well as creating a missing
            // one, without trusting compatibility bytes a second time after a
            // possible prune or another process's cache mutation.
            diskQueue.async {
                let rep = NSBitmapImageRep(cgImage: cgImage)
                if let jpeg = rep.representation(
                    using: .jpeg,
                    properties: [.compressionFactor: 0.8]
                ) {
                    try? jpeg.write(to: diskURL, options: .atomic)
                }
            }
            return image
        }

        let cgImage = item.isVideo
            ? decodeFirstVideoFrame(url: item.primaryURL, maxPixel: Self.thumbPixelSize)
            : Self.decodeImage(url: item.primaryURL, maxPixel: Self.thumbPixelSize)
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
        guard let cgImage = Self.decodeImage(url: url, maxPixel: Self.fullPixelSize) else { return nil }
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
    static func decodeImage(url: URL, maxPixel: CGFloat) -> CGImage? {
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
        // Relative IDs repeat across folders and survive same-folder rescans.
        // v5 adds the scan-time physical identity to byte-exact path, content
        // timestamps, size, and kind so a replacement cannot share pixels.
        "\(item.contentRevision.cacheIdentity)|v5"
    }

    /// Immediately previous key. It is only a compatibility candidate after
    /// its cache-file creation date proves it cannot predate the scanned file.
    static func previousThumbnailCacheKey(for item: PhotoItem) -> String {
        let mtime = item.primaryModificationDate?.timeIntervalSince1970 ?? 0
        let absoluteIdentity = FolderScanner.fileSystemIdentityPath(
            for: item.primaryURL
        )
        return "\(absoluteIdentity)|\(mtime)|\(item.mediaKind.rawValue)|v4"
    }

    /// Previous thumbnail key, used only as a one-way compatibility read for
    /// ASCII filesystem paths where decoded and byte identity cannot diverge.
    static func legacyThumbnailCacheKey(for item: PhotoItem) -> String? {
        let path = item.primaryURL.path
        guard path.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        let mtime = item.primaryModificationDate?.timeIntervalSince1970 ?? 0
        return "\(path)|\(mtime)|\(item.mediaKind.rawValue)|v3"
    }

    private static func compatibilityThumbnailCacheKeys(
        for item: PhotoItem
    ) -> [String] {
        var keys = [previousThumbnailCacheKey(for: item)]
        if let v3 = legacyThumbnailCacheKey(for: item) {
            keys.append(v3)
        }
        return keys
    }

    static func compatibilityThumbnailIsSafe(
        at cacheURL: URL,
        for item: PhotoItem
    ) -> Bool {
        let revision = item.contentRevision
        guard revision.stableFileIdentity == nil,
              let sourceFloor = revision.compatibilityCacheFloorDate,
              let values = try? cacheURL.resourceValues(
                forKeys: [.isRegularFileKey, .contentModificationDateKey]
              ),
              values.isRegularFile == true,
              let cacheDate = values.contentModificationDate
        else {
            return false
        }
        return cacheDate >= sourceFloor
    }

    static func diskFileName(for key: String) -> String {
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

    static func shouldPruneDiskCache(
        lastPrunedAt: Date?,
        now: Date
    ) -> Bool {
        guard let lastPrunedAt else { return true }
        let elapsed = now.timeIntervalSince(lastPrunedAt)
        // A clock correction or corrupt future timestamp must not suppress
        // maintenance until wall time eventually catches up.
        guard elapsed >= 0 else { return true }
        return elapsed >= 24 * 60 * 60
    }

    /// Keep the persistent cache useful but bounded. The caller schedules at
    /// most one delayed pass per day so launch and view construction stay free
    /// of this directory-wide metadata walk.
    @discardableResult
    static func pruneDiskCache(at root: URL) -> Bool {
        let fm = FileManager()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) else { return false }
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
        guard total > limit else { return true }
        for file in files.sorted(by: { $0.date < $1.date }) where total > limit {
            if (try? fm.removeItem(at: file.url)) != nil {
                total -= file.size
            }
        }
        return true
    }
}
