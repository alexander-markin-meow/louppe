import Foundation
import CoreImage

/// A lazy, oriented Core Image recipe for one source file. Holding this object
/// does not allocate a full decoded bitmap; individual source-pixel tiles are
/// rendered on demand.
final class ZoomImageSource: @unchecked Sendable {
    let key: String
    let image: CIImage
    let pixelSize: CGSize

    init(key: String, image: CIImage, pixelSize: CGSize) {
        self.key = key
        self.image = image
        self.pixelSize = pixelSize
    }
}

struct ZoomTileCoordinate: Hashable, Sendable {
    let column: Int
    let row: Int

    func pixelRect(
        sourceSize: CGSize,
        tilePixels: Int = HighResolutionImagePipeline.tilePixelSize
    ) -> CGRect? {
        guard column >= 0, row >= 0, tilePixels > 0 else { return nil }
        let x = CGFloat(column * tilePixels)
        let y = CGFloat(row * tilePixels)
        guard x < sourceSize.width, y < sourceSize.height else { return nil }
        return CGRect(
            x: x,
            y: y,
            width: min(CGFloat(tilePixels), sourceSize.width - x),
            height: min(CGFloat(tilePixels), sourceSize.height - y)
        )
    }
}

struct ZoomImageTile: @unchecked Sendable {
    let coordinate: ZoomTileCoordinate
    let pixelRect: CGRect
    let image: CGImage
}

/// Bounded source-region renderer used only by Gallery 100% mode.
///
/// Core Image keeps the source lazy. The operation queue limits expensive RAW
/// work to two tiles at a time, and the LRU stores at most 128 MiB of decoded
/// tile pixels. Requests for the same file/tile are coalesced.
final class HighResolutionImagePipeline: @unchecked Sendable {
    static let shared = HighResolutionImagePipeline()
    static let tilePixelSize = 1024
    static let tileCacheCostLimit = 128 * 1024 * 1024

    private struct TileKey: Hashable {
        let sourceKey: String
        let coordinate: ZoomTileCoordinate
    }

    private final class PendingSource {
        var waiters: [CheckedContinuation<ZoomImageSource?, Never>]
        let operation: BlockOperation

        init(
            waiters: [CheckedContinuation<ZoomImageSource?, Never>],
            operation: BlockOperation
        ) {
            self.waiters = waiters
            self.operation = operation
        }
    }

    private final class PendingTile {
        var waiters: [CheckedContinuation<ZoomImageTile?, Never>]
        let operation: BlockOperation

        init(
            waiters: [CheckedContinuation<ZoomImageTile?, Never>],
            operation: BlockOperation
        ) {
            self.waiters = waiters
            self.operation = operation
        }
    }

    private struct TileCacheEntry {
        let tile: ZoomImageTile
        let cost: Int
        var lastAccess: UInt64
    }

    private let renderQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "louppe.decode.actual-size"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let context = CIContext()
    /// Core Image's GPU service can be unavailable in restricted tests or
    /// after a transient graphics-process failure. The CPU context is a
    /// deterministic fallback rather than leaving 100% view blurry.
    private let softwareContext = CIContext(
        options: [.useSoftwareRenderer: true]
    )
    private let outputColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()
    private let lock = NSLock()
    private var sourceCache: [String: ZoomImageSource] = [:]
    private var sourceCacheOrder: [String] = []
    private var sourceInFlight: [String: PendingSource] = [:]
    private var tileCache: [TileKey: TileCacheEntry] = [:]
    private var tileCacheCost = 0
    private var tileAccessCounter: UInt64 = 0
    private var tileInFlight: [TileKey: PendingTile] = [:]

    private init() {}

    func source(for item: PhotoItem) async -> ZoomImageSource? {
        await source(
            for: item,
            qualityOfService: .userInitiated,
            queuePriority: .veryHigh
        )
    }

    private func source(
        for item: PhotoItem,
        qualityOfService: QualityOfService,
        queuePriority: Operation.QueuePriority
    ) async -> ZoomImageSource? {
        let key = ImagePipeline.cacheKey(for: item)
        let url = item.primaryURL
        return await withCheckedContinuation { continuation in
            lock.lock()
            if let cached = sourceCache[key] {
                touchSource(key)
                lock.unlock()
                continuation.resume(returning: cached)
                return
            }
            if let pending = sourceInFlight[key] {
                pending.waiters.append(continuation)
                if queuePriority == .veryHigh {
                    pending.operation.queuePriority = .veryHigh
                    pending.operation.qualityOfService = .userInitiated
                }
                lock.unlock()
                return
            }

            let operation = BlockOperation { [weak self] in
                guard let self else { return }
                let source = autoreleasepool {
                    self.makeSource(url: url, key: key)
                }
                self.finishSource(key: key, source: source)
            }
            operation.qualityOfService = qualityOfService
            operation.queuePriority = queuePriority
            sourceInFlight[key] = PendingSource(
                waiters: [continuation],
                operation: operation
            )
            lock.unlock()
            renderQueue.addOperation(operation)
        }
    }

    func prefetchSources(items: [PhotoItem]) {
        for item in items where !item.isVideo && item.isSupported {
            Task.detached(priority: .utility) { [weak self] in
                _ = await self?.source(
                    for: item,
                    qualityOfService: .utility,
                    queuePriority: .low
                )
            }
        }
    }

    func tile(
        for source: ZoomImageSource,
        coordinate: ZoomTileCoordinate
    ) async -> ZoomImageTile? {
        guard coordinate.pixelRect(sourceSize: source.pixelSize) != nil else {
            return nil
        }
        let key = TileKey(
            sourceKey: source.key,
            coordinate: coordinate
        )
        return await withCheckedContinuation { continuation in
            lock.lock()
            if var cached = tileCache[key] {
                tileAccessCounter &+= 1
                cached.lastAccess = tileAccessCounter
                tileCache[key] = cached
                lock.unlock()
                continuation.resume(returning: cached.tile)
                return
            }
            if let pending = tileInFlight[key] {
                pending.waiters.append(continuation)
                pending.operation.queuePriority = .veryHigh
                lock.unlock()
                return
            }

            let operation = BlockOperation { [weak self] in
                guard let self else { return }
                let tile = autoreleasepool {
                    self.renderTile(
                        source: source,
                        coordinate: coordinate
                    )
                }
                self.finishTile(key: key, tile: tile)
            }
            operation.qualityOfService = .userInitiated
            operation.queuePriority = .veryHigh
            tileInFlight[key] = PendingTile(
                waiters: [continuation],
                operation: operation
            )
            lock.unlock()
            renderQueue.addOperation(operation)
        }
    }

    /// Cancels queued work the current viewport no longer needs. A tile that
    /// is already inside Core Image may finish, but its removed request has no
    /// waiter and cannot be displayed over a newer photo.
    func retainTileRequests(
        sourceKey: String,
        coordinates: Set<ZoomTileCoordinate>
    ) {
        cancelTileRequests { key in
            key.sourceKey != sourceKey
                || !coordinates.contains(key.coordinate)
        }
    }

    func cancelTileRequests(exceptSourceKey sourceKey: String?) {
        cancelTileRequests { key in
            sourceKey == nil || key.sourceKey != sourceKey
        }
    }

    var cachedTileCost: Int {
        withStateLock { tileCacheCost }
    }

    var cachedTileCount: Int {
        withStateLock { tileCache.count }
    }

    func removeAllTiles() {
        withStateLock {
            tileCache.removeAll(keepingCapacity: false)
            tileCacheCost = 0
        }
        context.clearCaches()
        softwareContext.clearCaches()
    }

    private func makeSource(url: URL, key: String) -> ZoomImageSource? {
        let ext = url.pathExtension.lowercased()
        let original: CIImage?
        if FolderScanner.rawExtensions.contains(ext),
           let filter = CIRAWFilter(imageURL: url) {
            filter.isDraftModeEnabled = false
            filter.scaleFactor = 1
            original = filter.outputImage
        } else {
            original = CIImage(
                contentsOf: url,
                options: [.applyOrientationProperty: true]
            )
        }
        guard let original else { return nil }
        let extent = original.extent.integral
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else { return nil }
        let normalized = original.transformed(
            by: CGAffineTransform(
                translationX: -extent.minX,
                y: -extent.minY
            )
        )
        return ZoomImageSource(
            key: key,
            image: normalized,
            pixelSize: extent.size
        )
    }

    private func renderTile(
        source: ZoomImageSource,
        coordinate: ZoomTileCoordinate
    ) -> ZoomImageTile? {
        guard let topLeftRect = coordinate.pixelRect(
            sourceSize: source.pixelSize
        ) else { return nil }
        // Core Image uses a lower-left origin; the document view and retained
        // viewport use a photographer-friendly upper-left origin.
        let coreImageRect = CGRect(
            x: topLeftRect.minX,
            y: source.pixelSize.height - topLeftRect.maxY,
            width: topLeftRect.width,
            height: topLeftRect.height
        )
        guard let image =
                context.createCGImage(
                    source.image,
                    from: coreImageRect,
                    format: .RGBA8,
                    colorSpace: outputColorSpace
                )
                ?? softwareContext.createCGImage(
                    source.image,
                    from: coreImageRect,
                    format: .RGBA8,
                    colorSpace: outputColorSpace
                )
        else { return nil }
        return ZoomImageTile(
            coordinate: coordinate,
            pixelRect: topLeftRect,
            image: image
        )
    }

    private func finishSource(
        key: String,
        source: ZoomImageSource?
    ) {
        lock.lock()
        guard let pending = sourceInFlight.removeValue(forKey: key) else {
            lock.unlock()
            return
        }
        if let source {
            sourceCache[key] = source
            touchSource(key)
            while sourceCacheOrder.count > 4 {
                let removed = sourceCacheOrder.removeFirst()
                sourceCache.removeValue(forKey: removed)
            }
        }
        let waiters = pending.waiters
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: source)
        }
    }

    private func finishTile(
        key: TileKey,
        tile: ZoomImageTile?
    ) {
        lock.lock()
        guard let pending = tileInFlight.removeValue(forKey: key) else {
            lock.unlock()
            return
        }
        if let tile {
            tileAccessCounter &+= 1
            let cost = tile.image.bytesPerRow * tile.image.height
            tileCache[key] = TileCacheEntry(
                tile: tile,
                cost: cost,
                lastAccess: tileAccessCounter
            )
            tileCacheCost += cost
            evictTilesIfNeeded()
        }
        let waiters = pending.waiters
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: tile)
        }
    }

    private func touchSource(_ key: String) {
        sourceCacheOrder.removeAll { $0 == key }
        sourceCacheOrder.append(key)
    }

    private func evictTilesIfNeeded() {
        while tileCacheCost > Self.tileCacheCostLimit,
              let oldest = tileCache.min(by: {
                  $0.value.lastAccess < $1.value.lastAccess
              }) {
            tileCacheCost -= oldest.value.cost
            tileCache.removeValue(forKey: oldest.key)
        }
    }

    private func cancelTileRequests(
        matching shouldCancel: (TileKey) -> Bool
    ) {
        lock.lock()
        let keys = tileInFlight.keys.filter(shouldCancel)
        let cancelled = keys.compactMap { key -> PendingTile? in
            let pending = tileInFlight.removeValue(forKey: key)
            pending?.operation.cancel()
            return pending
        }
        lock.unlock()
        for pending in cancelled {
            for waiter in pending.waiters {
                waiter.resume(returning: nil)
            }
        }
    }

    private func withStateLock<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
