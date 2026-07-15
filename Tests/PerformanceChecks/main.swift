import Foundation

@main
struct PerformanceChecks {
    static func main() async throws {
        try preparedFilterMatchesFoldedMetadataTokens()
        try preparedFilterUsesWholeDayBounds()
        try folderScannerHonorsCancellation()
        try imageCacheKeyDoesNotTouchFilesystemAfterScan()
        try linearRestoreMergePreservesOrderAndOmitsLostPhoto()
        try await olderSidecarSaveCannotOverwriteNewerSnapshot()
        try await emptySidecarSnapshotIsPersisted()
        try cleanUpPairRoundTripsThroughTrash()
        try cleanUpPairFailureRollsBackFirstFile()
        print("Performance checks passed (9/9)")
    }

    private static func preparedFilterMatchesFoldedMetadataTokens() throws {
        let item = makeItem(
            id: "portraits/IMG_0001.JPG",
            camera: "Hasselbläd X2D",
            lens: "XCD 55V"
        )
        var filter = PhotoFilter()
        filter.searchText = "hasselblad 55v"
        try expect(PreparedPhotoFilter(filter).matches(item), "folded metadata query should match")

        filter.searchText = "hasselblad 90v"
        try expect(!PreparedPhotoFilter(filter).matches(item), "different lens token should not match")
    }

    private static func preparedFilterUsesWholeDayBounds() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let captured = calendar.date(from: DateComponents(year: 2026, month: 7, day: 14, hour: 23, minute: 59)),
              let day = calendar.date(from: DateComponents(year: 2026, month: 7, day: 14)) else {
            throw CheckFailure("could not construct test dates")
        }
        let item = makeItem(id: "IMG_0002.JPG", captureDate: captured)
        var filter = PhotoFilter()
        filter.dateEnabled = true
        filter.dateFrom = day
        filter.dateTo = day
        try expect(PreparedPhotoFilter(filter, calendar: calendar).matches(item), "date range should include the whole final day")
    }

    private static func linearRestoreMergePreservesOrderAndOmitsLostPhoto() throws {
        let originals = (0..<5).map { makeItem(id: "\($0).JPG") }
        let survivors = [originals[0], originals[2], originals[4]]
        let restored = [CleanUpPhotoSnapshot(index: 3, item: originals[3])]
        let merged = CleanUpWorker.mergeRestoredItems(
            survivors: survivors,
            allRemovedIndices: [1, 3],
            restored: restored
        )
        try expect(
            merged.map(\.id) == ["0.JPG", "2.JPG", "3.JPG", "4.JPG"],
            "linear restoration merge should preserve original order and omit only the lost item"
        )
    }

    private static func folderScannerHonorsCancellation() throws {
        let folder = try disposableFolder(named: "ScanCancellation")
        defer { try? FileManager.default.removeItem(at: folder) }
        var didCancel = false
        do {
            _ = try FolderScanner.scan(folder, isCancelled: { true }) { _ in }
        } catch is CancellationError {
            didCancel = true
        }
        try expect(didCancel, "superseded folder scan should stop immediately")
    }

    private static func imageCacheKeyDoesNotTouchFilesystemAfterScan() throws {
        let folder = try disposableFolder(named: "ImageCacheKey")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("CACHE.JPG")
        try Data("photo".utf8).write(to: url)
        let modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: url.path)
        let item = makeItem(
            id: "CACHE.JPG",
            primaryURL: url,
            modificationDate: modificationDate
        )

        let beforeRemoval = ImagePipeline.cacheKey(for: item)
        try FileManager.default.removeItem(at: url)
        let afterRemoval = ImagePipeline.cacheKey(for: item)
        try expect(
            beforeRemoval == afterRemoval,
            "thumbnail cache keys must use scan metadata instead of reading the live filesystem"
        )
    }

    private static func olderSidecarSaveCannotOverwriteNewerSnapshot() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LouppePersistenceChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let persistence = SessionPersistence()
        await persistence.save(session(rating: Rating.yes.rawValue), for: folder, sequence: 2)
        await persistence.save(session(rating: Rating.no.rawValue), for: folder, sequence: 1)
        let loaded = await persistence.read(for: folder)
        try expect(loaded?.entries.first?.rating == Rating.yes.rawValue, "older save should not replace newer sidecar")
    }

    private static func emptySidecarSnapshotIsPersisted() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LouppeEmptyPersistenceChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let persistence = SessionPersistence()
        let empty = SessionFile(
            version: 1,
            sourcePath: folder.path,
            scannedAt: Date(timeIntervalSince1970: 0),
            entries: []
        )
        await persistence.save(empty, for: folder, sequence: 1)
        let loaded = await persistence.read(for: folder)
        try expect(loaded?.entries.isEmpty == true, "empty ready session should replace a stale sidecar")
    }

    private static func cleanUpPairRoundTripsThroughTrash() throws {
        let folder = try disposableFolder(named: "CleanUpRoundTrip")
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("PAIR.NEF")
        let jpeg = folder.appendingPathComponent("PAIR.JPG")
        try Data("raw".utf8).write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)
        let item = makeItem(id: "PAIR.NEF", primaryURL: raw, pairedURL: jpeg)

        let trashed = CleanUpWorker.moveToTrash([CleanUpPhotoSnapshot(index: 0, item: item)]) { _, _ in }
        try expect(trashed.succeeded.count == 1, "paired photo should move to Trash")
        try expect(trashed.inconsistentPhotos == 0, "successful Trash move should be consistent")
        try expect(!FileManager.default.fileExists(atPath: raw.path), "RAW should leave its folder")
        try expect(!FileManager.default.fileExists(atPath: jpeg.path), "JPEG should leave its folder")

        let restored = CleanUpWorker.restore(trashed.succeeded) { _, _ in }
        try expect(restored.restored.count == 1, "paired photo should restore from Trash")
        try expect(restored.inconsistentPhotos == 0, "successful restore should be consistent")
        try expect(FileManager.default.fileExists(atPath: raw.path), "RAW should return")
        try expect(FileManager.default.fileExists(atPath: jpeg.path), "JPEG should return")
    }

    private static func cleanUpPairFailureRollsBackFirstFile() throws {
        let folder = try disposableFolder(named: "CleanUpRollback")
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("PAIR.NEF")
        let missingJPEG = folder.appendingPathComponent("MISSING.JPG")
        try Data("raw".utf8).write(to: raw)
        let item = makeItem(id: "PAIR.NEF", primaryURL: raw, pairedURL: missingJPEG)

        let result = CleanUpWorker.moveToTrash([CleanUpPhotoSnapshot(index: 0, item: item)]) { _, _ in }
        try expect(result.succeeded.isEmpty, "incomplete pair must not count as removed")
        try expect(result.failedPhotos == 1, "incomplete pair should report one failure")
        try expect(result.inconsistentPhotos == 0, "successful rollback should remain consistent")
        try expect(FileManager.default.fileExists(atPath: raw.path), "first file must roll back when its pair fails")
    }

    private static func makeItem(
        id: String,
        primaryURL: URL? = nil,
        pairedURL: URL? = nil,
        captureDate: Date? = nil,
        camera: String? = nil,
        lens: String? = nil,
        modificationDate: Date? = nil
    ) -> PhotoItem {
        PhotoItem(
            id: id,
            primaryURL: primaryURL ?? URL(fileURLWithPath: "/tmp/\(id)"),
            pairedURL: pairedURL,
            captureDate: captureDate,
            cameraModel: camera,
            lensModel: lens,
            primaryModificationDate: modificationDate,
            fileSize: 1
        )
    }

    private static func session(rating: String) -> SessionFile {
        SessionFile(
            version: 1,
            sourcePath: "/tmp/photos",
            scannedAt: Date(timeIntervalSince1970: 0),
            entries: [SessionEntry(filename: "IMG.JPG", pairedFilename: nil, rating: rating, ratedAt: nil)]
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckFailure(message) }
    }

    private static func disposableFolder(named name: String) throws -> URL {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/performance-checks/disposable", isDirectory: true)
            .appendingPathComponent("Louppe\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
