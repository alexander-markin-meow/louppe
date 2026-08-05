import Foundation
import AppKit

/// Photo-wide luminance distribution plus the two warning-zone populations
/// used by both the Info panel and clipping-warning overlay.
struct HistogramAnalysis: Equatable, Sendable {
    static let nearBlackUpperBound: UInt8 = 5
    static let nearWhiteLowerBound: UInt8 = 250
    static let highPercentageThreshold = 10.0

    let bins: [Int]
    let sampleCount: Int
    let shadowCount: Int
    let highlightCount: Int

    var shadowPercentage: Double {
        percentage(for: shadowCount)
    }

    var highlightPercentage: Double {
        percentage(for: highlightCount)
    }

    static func isHighPercentage(_ value: Double) -> Bool {
        value > highPercentageThreshold
    }

    private func percentage(for count: Int) -> Double {
        guard sampleCount > 0 else { return 0 }
        return Double(count) * 100 / Double(sampleCount)
    }
}

/// Deterministic 8-bit sRGB pixel work shared by the histogram and overlay.
///
/// The threshold is deliberately luminance-based: the Info panel draws one
/// neutral histogram rather than RGB channels, and the photograph overlay
/// must mark exactly the same pixels its percentages describe.
enum ClippingWarningProcessor {
    static func luminance(red: UInt8, green: UInt8, blue: UInt8) -> UInt8 {
        // Integer Rec. 709 coefficients, summing to 256.
        let redContribution = 54 * Int(red)
        let greenContribution = 183 * Int(green)
        let blueContribution = 19 * Int(blue)
        let weighted =
            redContribution + greenContribution + blueContribution + 128
        return UInt8(min(weighted >> 8, 255))
    }

    static func isWarning(red: UInt8, green: UInt8, blue: UInt8) -> Bool {
        let value = luminance(red: red, green: green, blue: blue)
        return value <= HistogramAnalysis.nearBlackUpperBound
            || value >= HistogramAnalysis.nearWhiteLowerBound
    }

    static func analyze(_ image: CGImage) -> HistogramAnalysis? {
        guard let buffer = rgbaBuffer(for: image) else { return nil }
        var bins = Array(repeating: 0, count: 256)
        var sampleCount = 0
        var shadowCount = 0
        var highlightCount = 0
        let pixelCount = buffer.width * buffer.height

        buffer.bytes.withUnsafeBytes { rawBytes in
            guard let bytes = rawBytes.bindMemory(to: UInt8.self).baseAddress
            else { return }
            for pixel in 0..<pixelCount {
                let offset = pixel * 4
                guard bytes[offset + 3] > 0 else { continue }
                let value = luminance(
                    red: bytes[offset],
                    green: bytes[offset + 1],
                    blue: bytes[offset + 2]
                )
                sampleCount += 1
                bins[Int(value)] += 1
                if value <= HistogramAnalysis.nearBlackUpperBound {
                    shadowCount += 1
                }
                if value >= HistogramAnalysis.nearWhiteLowerBound {
                    highlightCount += 1
                }
            }
        }

        return HistogramAnalysis(
            bins: bins,
            sampleCount: sampleCount,
            shadowCount: shadowCount,
            highlightCount: highlightCount
        )
    }

    static func overlay(on image: CGImage) -> CGImage? {
        guard var buffer = rgbaBuffer(for: image) else { return nil }
        let pixelCount = buffer.width * buffer.height

        buffer.bytes.withUnsafeMutableBytes { rawBytes in
            guard let bytes = rawBytes.bindMemory(to: UInt8.self).baseAddress
            else { return }
            for pixel in 0..<pixelCount {
                let offset = pixel * 4
                guard isWarning(
                    red: bytes[offset],
                    green: bytes[offset + 1],
                    blue: bytes[offset + 2]
                ) else { continue }
                // Blend 72% warning red over the original pixel. The alpha is
                // retained so transparent image edges stay transparent.
                bytes[offset] = blend(bytes[offset], with: 255)
                bytes[offset + 1] = blend(bytes[offset + 1], with: 0)
                bytes[offset + 2] = blend(bytes[offset + 2], with: 0)
            }
        }

        return buffer.makeImage()
    }

    private static func blend(_ original: UInt8, with warning: UInt8) -> UInt8 {
        let originalContribution = 28 * Int(original)
        let warningContribution = 72 * Int(warning)
        return UInt8(
            (originalContribution + warningContribution + 50) / 100
        )
    }

    private struct RGBABuffer {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        var bytes: [UInt8]

        func makeImage() -> CGImage? {
            bytes.withUnsafeBytes { rawBytes in
                guard let baseAddress = rawBytes.baseAddress,
                      let context = CGContext(
                        data: UnsafeMutableRawPointer(mutating: baseAddress),
                        width: width,
                        height: height,
                        bitsPerComponent: 8,
                        bytesPerRow: bytesPerRow,
                        space: Self.colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      )
                else { return nil }
                return context.makeImage()
            }
        }

        static let colorSpace =
            CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
    }

    private static func rgbaBuffer(for image: CGImage) -> RGBABuffer? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var bytes = Array(
            repeating: UInt8(0),
            count: bytesPerRow * height
        )
        let rendered = bytes.withUnsafeMutableBytes { rawBytes -> Bool in
            guard let baseAddress = rawBytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: RGBABuffer.colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.interpolationQuality = .high
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        guard rendered else { return nil }
        return RGBABuffer(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bytes: bytes
        )
    }
}

/// Bounded, coalesced histogram work. At most two 1,024-pixel analysis
/// previews are decoded at once; the cache retains tiny value results, never
/// decoded bitmaps.
final class HistogramPipeline: @unchecked Sendable {
    static let shared = HistogramPipeline()
    static let analysisPixelSize: CGFloat = 1024
    static let resultCacheLimit = 256

    private final class PendingAnalysis {
        var waiters: [CheckedContinuation<HistogramAnalysis?, Never>]
        let operation: BlockOperation

        init(
            waiters: [CheckedContinuation<HistogramAnalysis?, Never>],
            operation: BlockOperation
        ) {
            self.waiters = waiters
            self.operation = operation
        }
    }

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "louppe.histogram"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let lock = NSLock()
    private var cache: [String: HistogramAnalysis] = [:]
    private var cacheOrder: [String] = []
    private var inFlight: [String: PendingAnalysis] = [:]

    private init() {}

    func analysis(for item: PhotoItem) async -> HistogramAnalysis? {
        guard item.mediaKind == .photo, item.isSupported else { return nil }
        let key = ImagePipeline.cacheKey(for: item)
        let url = item.primaryURL
        return await withCheckedContinuation { continuation in
            lock.lock()
            if let cached = cache[key] {
                touch(key)
                lock.unlock()
                continuation.resume(returning: cached)
                return
            }
            if let pending = inFlight[key] {
                pending.waiters.append(continuation)
                lock.unlock()
                return
            }

            let operation = BlockOperation { [weak self] in
                guard let self else { return }
                let result = autoreleasepool {
                    ImagePipeline.decodeImage(
                        url: url,
                        maxPixel: Self.analysisPixelSize
                    ).flatMap(ClippingWarningProcessor.analyze)
                }
                self.finish(key: key, result: result)
            }
            operation.qualityOfService = .userInitiated
            inFlight[key] = PendingAnalysis(
                waiters: [continuation],
                operation: operation
            )
            lock.unlock()
            queue.addOperation(operation)
        }
    }

    private func finish(key: String, result: HistogramAnalysis?) {
        lock.lock()
        guard let pending = inFlight.removeValue(forKey: key) else {
            lock.unlock()
            return
        }
        if let result {
            cache[key] = result
            touch(key)
            while cacheOrder.count > Self.resultCacheLimit {
                let removed = cacheOrder.removeFirst()
                cache.removeValue(forKey: removed)
            }
        }
        let waiters = pending.waiters
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    private func touch(_ key: String) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }
}

/// Cached clipping-warning counterparts for the existing 4,096-pixel Gallery
/// previews. Source decoding stays coalesced in ImagePipeline; only the pixel
/// transform has its own two-operation lane and 128 MiB cache.
final class ClippingPreviewPipeline: @unchecked Sendable {
    static let shared = ClippingPreviewPipeline()
    static let cacheCostLimit = 128 * 1024 * 1024

    private final class PendingImage {
        var waiters: [CheckedContinuation<NSImage?, Never>]
        let operation: BlockOperation

        init(
            waiters: [CheckedContinuation<NSImage?, Never>],
            operation: BlockOperation
        ) {
            self.waiters = waiters
            self.operation = operation
        }
    }

    private let cache = NSCache<NSString, NSImage>()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "louppe.clipping-preview"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let lock = NSLock()
    private var inFlight: [String: PendingImage] = [:]

    private init() {
        cache.countLimit = 2
        cache.totalCostLimit = Self.cacheCostLimit
    }

    func cachedImage(for item: PhotoItem) -> NSImage? {
        cache.object(
            forKey: ImagePipeline.cacheKey(for: item) as NSString
        )
    }

    func image(for item: PhotoItem) async -> NSImage? {
        guard item.mediaKind == .photo, item.isSupported else { return nil }
        let key = ImagePipeline.cacheKey(for: item)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        guard let source = await ImagePipeline.shared.fullImage(for: item),
              let cgImage = source.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
              )
        else { return nil }

        return await withCheckedContinuation { continuation in
            lock.lock()
            if let cached = cache.object(forKey: key as NSString) {
                lock.unlock()
                continuation.resume(returning: cached)
                return
            }
            if let pending = inFlight[key] {
                pending.waiters.append(continuation)
                lock.unlock()
                return
            }
            let operation = BlockOperation { [weak self] in
                guard let self else { return }
                let processed = autoreleasepool {
                    ClippingWarningProcessor.overlay(on: cgImage).map {
                        NSImage(cgImage: $0, size: .zero)
                    }
                }
                self.finish(
                    key: key,
                    image: processed,
                    cost: processed.map {
                        Int($0.size.width * $0.size.height * 4)
                    } ?? 0
                )
            }
            operation.qualityOfService = .userInitiated
            inFlight[key] = PendingImage(
                waiters: [continuation],
                operation: operation
            )
            lock.unlock()
            queue.addOperation(operation)
        }
    }

    private func finish(key: String, image: NSImage?, cost: Int) {
        lock.lock()
        guard let pending = inFlight.removeValue(forKey: key) else {
            lock.unlock()
            return
        }
        if let image {
            cache.setObject(
                image,
                forKey: key as NSString,
                cost: cost
            )
        }
        let waiters = pending.waiters
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: image)
        }
    }
}
