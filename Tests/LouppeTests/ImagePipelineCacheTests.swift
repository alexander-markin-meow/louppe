import Foundation
import ImageIO
import XCTest
@testable import Louppe

final class ImagePipelineCacheTests: XCTestCase {
    func testContentRevisionDistinguishesSamePathSameMtimeIdentity() throws {
        let folder = try makeTemporaryDirectory(named: "identity")
        defer { try? FileManager.default.removeItem(at: folder) }
        let firstPhysical = folder.appendingPathComponent("first.bin")
        let secondPhysical = folder.appendingPathComponent("second.bin")
        try Data("first".utf8).write(to: firstPhysical)
        try Data("other".utf8).write(to: secondPhysical)
        let firstIdentity = try FileOperationJournal.captureIdentity(
            at: firstPhysical
        )
        let secondIdentity = try FileOperationJournal.captureIdentity(
            at: secondPhysical
        )
        let logicalURL = folder.appendingPathComponent("SAME.JPG")
        let modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        let first = makeItem(
            at: logicalURL,
            modificationDate: modificationDate,
            fileSize: 5,
            scannedIdentity: firstIdentity
        )
        let replacement = makeItem(
            at: logicalURL,
            modificationDate: modificationDate,
            fileSize: 5,
            scannedIdentity: secondIdentity
        )

        XCTAssertEqual(first.id, replacement.id)
        XCTAssertEqual(
            first.primaryModificationDate,
            replacement.primaryModificationDate
        )
        XCTAssertNotEqual(first.contentRevision, replacement.contentRevision)
        XCTAssertNotEqual(
            ImagePipeline.cacheKey(for: first),
            ImagePipeline.cacheKey(for: replacement)
        )
    }

    func testLegacyASCIIThumbnailIsReadAndPromotedInIsolatedCache() async throws {
        let folder = try makeTemporaryDirectory(named: "warm-v3")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.JPG")
        let fixedDate = Date(timeIntervalSince1970: 1_650_000_000)
        let item = try makeIdentitylessInvalidSourceItem(
            at: source,
            date: fixedDate
        )
        let cacheRoot = folder.appendingPathComponent("cache", isDirectory: true)
        let pipeline = ImagePipeline(testingDiskCacheRoot: cacheRoot)
        let legacyKey = try XCTUnwrap(
            ImagePipeline.legacyThumbnailCacheKey(for: item)
        )
        let legacyURL = cacheRoot.appendingPathComponent(
            ImagePipeline.diskFileName(for: legacyKey)
        )
        let currentURL = currentCacheURL(
            for: item,
            root: cacheRoot
        )
        try copyFixture(to: legacyURL)

        XCTAssertTrue(
            ImagePipeline.compatibilityThumbnailIsSafe(
                at: legacyURL,
                for: item
            )
        )
        let warmThumbnail = await pipeline.thumbnail(for: item)
        XCTAssertNotNil(
            warmThumbnail,
            "a validated warm thumbnail should avoid decoding invalid source bytes"
        )
        await pipeline.waitForPendingDiskWrites()

        XCTAssertTrue(isDecodableImage(at: currentURL))
    }

    func testValidSourceAtomicallyHealsCorruptCurrentEntry() async throws {
        let folder = try makeTemporaryDirectory(named: "corrupt-current")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.JPG")
        try copyFixture(to: source)
        let values = try source.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        let item = PhotoItem(
            id: source.lastPathComponent,
            primaryURL: source,
            pairedURL: nil,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            primaryModificationDate: values.contentModificationDate,
            fileSize: Int64(values.fileSize ?? 0)
        )
        let cacheRoot = folder.appendingPathComponent("cache", isDirectory: true)
        let pipeline = ImagePipeline(testingDiskCacheRoot: cacheRoot)
        let currentURL = currentCacheURL(for: item, root: cacheRoot)
        try FileManager.default.createDirectory(
            at: cacheRoot,
            withIntermediateDirectories: true
        )
        try Data("not an image".utf8).write(to: currentURL)
        XCTAssertFalse(isDecodableImage(at: currentURL))

        let recoveredThumbnail = await pipeline.thumbnail(for: item)
        XCTAssertNotNil(recoveredThumbnail)
        await pipeline.waitForPendingDiskWrites()

        XCTAssertTrue(
            isDecodableImage(at: currentURL),
            "a fresh source decode must replace, not preserve, a corrupt current entry"
        )
    }

    func testCompatibilityCachesOlderThanReplacementIdentityAreRejected() async throws {
        let folder = try makeTemporaryDirectory(named: "replacement")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.JPG")
        let fixedDate = Date(timeIntervalSince1970: 1_650_000_000)
        let cacheRoot = folder.appendingPathComponent("cache", isDirectory: true)
        let pipeline = ImagePipeline(testingDiskCacheRoot: cacheRoot)

        let initialItem = try makeInvalidSourceItem(
            at: source,
            date: fixedDate
        )
        let v4URL = cacheRoot.appendingPathComponent(
            ImagePipeline.diskFileName(
                for: ImagePipeline.previousThumbnailCacheKey(
                    for: initialItem
                )
            )
        )
        let v3URL = cacheRoot.appendingPathComponent(
            ImagePipeline.diskFileName(
                for: try XCTUnwrap(
                    ImagePipeline.legacyThumbnailCacheKey(for: initialItem)
                )
            )
        )
        try copyFixture(to: v4URL)
        try copyFixture(to: v3URL)
        try await Task.sleep(for: .milliseconds(20))

        try FileManager.default.removeItem(at: source)
        let replacement = try makeInvalidSourceItem(
            at: source,
            date: fixedDate
        )
        XCTAssertEqual(
            ImagePipeline.previousThumbnailCacheKey(for: initialItem),
            ImagePipeline.previousThumbnailCacheKey(for: replacement)
        )
        XCTAssertFalse(
            ImagePipeline.compatibilityThumbnailIsSafe(
                at: v4URL,
                for: replacement
            )
        )
        XCTAssertFalse(
            ImagePipeline.compatibilityThumbnailIsSafe(
                at: v3URL,
                for: replacement
            )
        )

        let rejectedThumbnail = await pipeline.thumbnail(for: replacement)
        XCTAssertNil(
            rejectedThumbnail,
            "a replacement with invalid bytes must not display either older cache generation"
        )
    }

    func testIdentityBoundItemRejectsEvenFutureDatedCompatibilityCache() throws {
        let folder = try makeTemporaryDirectory(named: "identity-bound-legacy")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.JPG")
        try Data("current bytes".utf8).write(to: source)
        let identity = try FileOperationJournal.captureIdentity(at: source)
        let values = try source.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        let item = makeItem(
            at: source,
            modificationDate: try XCTUnwrap(values.contentModificationDate),
            fileSize: Int64(values.fileSize ?? 0),
            scannedIdentity: identity
        )
        let cacheURL = folder.appendingPathComponent("old-v4.jpg")
        try copyFixture(to: cacheURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(24 * 60 * 60)],
            ofItemAtPath: cacheURL.path
        )

        XCTAssertFalse(
            ImagePipeline.compatibilityThumbnailIsSafe(
                at: cacheURL,
                for: item
            ),
            "an identity-less cache cannot be proven to belong to a scanned inode"
        )
    }

    func testLegacyFallbackRefusesUnicodePathAmbiguity() {
        let item = PhotoItem(
            id: "café.JPG",
            primaryURL: URL(fileURLWithPath: "/private/tmp/café.JPG"),
            pairedURL: nil,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 1
        )

        XCTAssertNil(ImagePipeline.legacyThumbnailCacheKey(for: item))
    }

    func testDiskPruningIsDailyAndRecoversFromClockRollback() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
        XCTAssertTrue(
            ImagePipeline.shouldPruneDiskCache(
                lastPrunedAt: nil,
                now: now
            )
        )
        XCTAssertFalse(
            ImagePipeline.shouldPruneDiskCache(
                lastPrunedAt: now.addingTimeInterval(-60),
                now: now
            )
        )
        XCTAssertTrue(
            ImagePipeline.shouldPruneDiskCache(
                lastPrunedAt: now.addingTimeInterval(-(24 * 60 * 60)),
                now: now
            )
        )
        XCTAssertTrue(
            ImagePipeline.shouldPruneDiskCache(
                lastPrunedAt: now.addingTimeInterval(60),
                now: now
            )
        )
    }

    func testFailedPruneEnumerationReportsFailure() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-cache-\(UUID().uuidString)")
        XCTAssertFalse(ImagePipeline.pruneDiskCache(at: missing))
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "louppe-cache-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        return folder
    }

    private func makeInvalidSourceItem(
        at url: URL,
        date: Date
    ) throws -> PhotoItem {
        try Data("invalid image bytes".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
        return PhotoItem(
            id: url.lastPathComponent,
            primaryURL: url,
            pairedURL: nil,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            primaryModificationDate: date,
            fileSize: 19
        )
    }

    private func makeIdentitylessInvalidSourceItem(
        at url: URL,
        date: Date
    ) throws -> PhotoItem {
        try Data("invalid image bytes".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
        return PhotoItem(
            primaryFile: PhotoFile(
                id: url.lastPathComponent,
                url: url,
                captureDate: nil,
                cameraModel: nil,
                lensModel: nil,
                modificationDate: date,
                fileSize: 19,
                scannedIdentity: nil
            )
        )
    }

    private func makeItem(
        at url: URL,
        modificationDate: Date,
        fileSize: Int64,
        scannedIdentity: FileOperationJournal.FileIdentity
    ) -> PhotoItem {
        PhotoItem(
            primaryFile: PhotoFile(
                id: url.lastPathComponent,
                url: url,
                captureDate: nil,
                cameraModel: nil,
                lensModel: nil,
                modificationDate: modificationDate,
                fileSize: fileSize,
                scannedIdentity: scannedIdentity
            )
        )
    }

    private func copyFixture(to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: fixtureURL, to: destination)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: destination.path
        )
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "AppIcon/AppIcon.iconset/icon_128x128.png"
            )
    }

    private func currentCacheURL(for item: PhotoItem, root: URL) -> URL {
        root.appendingPathComponent(
            ImagePipeline.diskFileName(
                for: ImagePipeline.cacheKey(for: item)
            )
        )
    }

    private func isDecodableImage(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }
}
