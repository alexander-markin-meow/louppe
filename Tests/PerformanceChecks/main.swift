import Combine
import Foundation

@main
struct PerformanceChecks {
    static func main() async throws {
        try preparedFilterMatchesFoldedMetadataTokens()
        try preparedFilterUsesWholeDayBounds()
        try preparedFilterUsesSpecificDateCheckboxes()
        try preparedFilterUsesInclusiveExposureRanges()
        try neutralFullRangesKeepUnknownMetadataVisible()
        try selectionSummaryKeepsEveryDistinctMetadataValue()
        try metadataSortKeepsMissingValuesLast()
        try subfolderFacetFiltersAndSortsByRelativePath()
        try folderScannerHonorsCancellation()
        try folderScannerStopsAfterProgressCancellation()
        try imageCacheKeyDoesNotTouchFilesystemAfterScan()
        try cleanUpScopeResolvesExpectedCandidates()
        try linearRestoreMergePreservesOrderAndOmitsLostPhoto()
        try await olderSidecarSaveCannotOverwriteNewerSnapshot()
        try await emptySidecarSnapshotIsPersisted()
        try cleanUpPairRoundTripsThroughTrash()
        try cleanUpPairFailureRollsBackFirstFile()
        try exportCollisionSuffixSkipsTakenNames()
        try exportCopyCopiesEveryFileAndKeepsSources()
        try exportMoveReportsFullyMovedPhotos()
        try exportMovePairRollsBackOnPartialFailure()
        try exportMoveRefusesInPlaceDestination()
        try clearAllRatingsPublishesOnceForLargeSessions()
        try batchRatingUndoRestoresEveryRating()
        try exportMoveRemovalUpdatesSessionState()
        print("Performance checks passed (25/25)")
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

    private static func preparedFilterUsesSpecificDateCheckboxes() throws {
        let calendar = Calendar.current
        guard let firstDay = calendar.date(from: DateComponents(year: 2026, month: 7, day: 14)),
              let secondDay = calendar.date(from: DateComponents(year: 2026, month: 7, day: 15)),
              let firstCapture = calendar.date(byAdding: .hour, value: 18, to: firstDay),
              let secondCapture = calendar.date(byAdding: .hour, value: 9, to: secondDay) else {
            throw CheckFailure("could not construct specific-date test values")
        }
        let first = makeItem(id: "FIRST.JPG", captureDate: firstCapture)
        let second = makeItem(id: "SECOND.JPG", captureDate: secondCapture)
        let unknown = makeItem(id: "UNKNOWN.JPG")
        var filter = PhotoFilter()
        filter.dateEnabled = true
        filter.dateMode = .specificDates
        filter.excludedDates = [calendar.startOfDay(for: secondDay)]
        filter.excludesUnknownDate = true
        let prepared = PreparedPhotoFilter(filter)
        try expect(prepared.matches(first), "an included calendar day should remain visible")
        try expect(!prepared.matches(second), "an unchecked calendar day should be excluded")
        try expect(!prepared.matches(unknown), "the unknown-date checkbox should exclude undated photos")
    }

    private static func preparedFilterUsesInclusiveExposureRanges() throws {
        let item = makeItem(id: "EXPOSURE.JPG", aperture: 2.8, shutter: 1 / 250, iso: 800)
        var filter = PhotoFilter()
        filter.apertureEnabled = true
        filter.apertureFrom = 2.8
        filter.apertureTo = 5.6
        filter.shutterEnabled = true
        filter.shutterFrom = 1 / 1000
        filter.shutterTo = 1 / 250
        filter.isoEnabled = true
        filter.isoFrom = 100
        filter.isoTo = 800
        try expect(PreparedPhotoFilter(filter).matches(item), "exposure bounds should include both endpoints")

        filter.isoTo = 799
        try expect(!PreparedPhotoFilter(filter).matches(item), "a photo outside one active range should be excluded")
        try expect(
            !PreparedPhotoFilter(PhotoFilter(apertureEnabled: true, apertureFrom: 1, apertureTo: 16)).matches(makeItem(id: "NO-EXIF.JPG")),
            "an active exposure filter should exclude missing metadata"
        )
    }

    private static func neutralFullRangesKeepUnknownMetadataVisible() throws {
        var filter = PhotoFilter()
        filter.dateFrom = Date(timeIntervalSince1970: 1)
        filter.dateTo = Date(timeIntervalSince1970: 2)
        filter.apertureFrom = 1.4
        filter.apertureTo = 16
        filter.shutterFrom = 1 / 8000
        filter.shutterTo = 30
        filter.isoFrom = 64
        filter.isoTo = 12800

        try expect(filter.dateMode == .range, "date should default to range mode")
        try expect(!filter.isActive, "folder-wide default ranges should be neutral")
        try expect(
            PreparedPhotoFilter(filter).matches(makeItem(id: "UNKNOWN-METADATA.JPG")),
            "neutral full ranges should keep photos with unknown metadata visible"
        )
    }

    private static func selectionSummaryKeepsEveryDistinctMetadataValue() throws {
        let calendar = Calendar.current
        guard let firstDay = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1)),
              let middleDay = calendar.date(from: DateComponents(year: 2026, month: 7, day: 2)),
              let lastDay = calendar.date(from: DateComponents(year: 2026, month: 7, day: 3)),
              let firstDate = calendar.date(byAdding: .hour, value: 10, to: firstDay),
              let middleDate = calendar.date(byAdding: .hour, value: 14, to: middleDay),
              let lastDate = calendar.date(byAdding: .hour, value: 20, to: lastDay) else {
            throw CheckFailure("could not construct selection-summary dates")
        }
        let items = [
            makeItem(
                id: "A.JPG",
                captureDate: firstDate,
                camera: "Nikon Z8",
                lens: "NIKKOR Z 50mm",
                fileSize: 10
            ),
            makeItem(
                id: "B.NEF",
                captureDate: middleDate,
                camera: "Sony α1",
                lens: "FE 35mm F1.4 GM",
                fileSize: 20
            ),
            makeItem(
                id: "C.TIF",
                captureDate: lastDate,
                camera: "Canon EOS R5",
                lens: "RF 85mm F1.2 L",
                fileSize: 30
            ),
            makeItem(
                id: "D.NEF",
                pairedURL: URL(fileURLWithPath: "/tmp/D.JPG"),
                camera: "Fujifilm GFX100 II",
                lens: "GF55mmF1.7 R WR",
                fileSize: 40,
                pairedFileSize: 5
            ),
        ]

        let summary = PhotoSelectionSummary(items: items)
        try expect(summary.count == 4, "selection summary should retain the selected item count")
        try expect(
            Set(summary.cameras) == ["Nikon Z8", "Sony α1", "Canon EOS R5", "Fujifilm GFX100 II"],
            "selection summary should retain every distinct camera"
        )
        try expect(
            Set(summary.lenses) == ["NIKKOR Z 50mm", "FE 35mm F1.4 GM", "RF 85mm F1.2 L", "GF55mmF1.7 R WR"],
            "selection summary should retain every distinct lens"
        )
        try expect(summary.captureDayRange == firstDay...lastDay, "selection summary should retain only the capture-day span")
        try expect(summary.unknownDateCount == 1, "selection summary should count missing capture dates")
        try expect(summary.totalBytes == 105, "selection summary should include paired-file bytes")
        try expect(
            Set(summary.fileTypes) == ["JPEG", "RAW", "TIFF", "RAW + JPEG"],
            "selection summary should retain every selected file type"
        )

        guard let laterSameDay = calendar.date(byAdding: .hour, value: 8, to: firstDate) else {
            throw CheckFailure("could not construct same-day summary date")
        }
        let sameDay = PhotoSelectionSummary(items: [
            makeItem(id: "SAME-1.JPG", captureDate: firstDate),
            makeItem(id: "SAME-2.JPG", captureDate: laterSameDay),
        ])
        try expect(
            sameDay.captureDayRange == firstDay...firstDay,
            "same-day selections should collapse to one calendar date"
        )
    }

    private static func metadataSortKeepsMissingValuesLast() throws {
        let low = makeItem(id: "LOW.JPG", captureDate: Date(timeIntervalSince1970: 1), iso: 100)
        let high = makeItem(id: "HIGH.JPG", captureDate: Date(timeIntervalSince1970: 2), iso: 3200)
        let unknown = makeItem(id: "UNKNOWN.JPG", captureDate: Date(timeIntervalSince1970: 0))

        var sort = PhotoSort(key: .iso, ascending: true)
        try expect(
            [unknown, high, low].sorted(by: sort.areInOrder).map(\.id) == ["LOW.JPG", "HIGH.JPG", "UNKNOWN.JPG"],
            "ascending numeric metadata sort should order values and put missing data last"
        )
        sort.ascending = false
        try expect(
            [low, unknown, high].sorted(by: sort.areInOrder).map(\.id) == ["HIGH.JPG", "LOW.JPG", "UNKNOWN.JPG"],
            "descending numeric metadata sort should still put missing data last"
        )
    }

    private static func subfolderFacetFiltersAndSortsByRelativePath() throws {
        let root = makeItem(id: "ROOT.JPG")
        let nested = makeItem(id: "DCIM/100NIKON/NESTED.JPG")
        let flat = makeItem(id: "berlin/FLAT.JPG")
        try expect(root.subfolder == nil && root.subfolderLabel == "None",
                   "a root-level file should carry the explicit None label")
        try expect(nested.subfolder == "DCIM/100NIKON",
                   "the subfolder should be the id's full relative directory")

        var filter = PhotoFilter()
        filter.excludedSubfolders = ["None"]
        var prepared = PreparedPhotoFilter(filter)
        try expect(!prepared.matches(root) && prepared.matches(nested),
                   "unchecking None should hide only root-level files")
        filter.excludedSubfolders = ["DCIM/100NIKON"]
        prepared = PreparedPhotoFilter(filter)
        try expect(prepared.matches(root) && !prepared.matches(nested),
                   "unchecking a subfolder should hide exactly its files")

        var sort = PhotoSort(key: .subfolder, ascending: true)
        try expect(
            [root, nested, flat].sorted(by: sort.areInOrder).map(\.id)
                == ["berlin/FLAT.JPG", "DCIM/100NIKON/NESTED.JPG", "ROOT.JPG"],
            "ascending subfolder sort should order paths and put root files last"
        )
        sort.ascending = false
        try expect(
            [root, nested, flat].sorted(by: sort.areInOrder).map(\.id)
                == ["DCIM/100NIKON/NESTED.JPG", "berlin/FLAT.JPG", "ROOT.JPG"],
            "descending subfolder sort should still put root files last"
        )
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

    private static func cleanUpScopeResolvesExpectedCandidates() throws {
        let all = 0..<6
        let filtered = [1, 3, 5]
        let selected: Set<Int> = [4, 2]
        try expect(
            CleanUpScope.all.candidateIndices(all: all, filtered: filtered, selected: selected) == [0, 1, 2, 3, 4, 5],
            "all-photo Clean Up scope should consider the whole folder"
        )
        try expect(
            CleanUpScope.filtered.candidateIndices(all: all, filtered: filtered, selected: selected) == filtered,
            "filtered Clean Up scope should consider only visible photos"
        )
        try expect(
            CleanUpScope.selected.candidateIndices(all: all, filtered: filtered, selected: selected) == [2, 4],
            "selected Clean Up scope should consider only the effective selection"
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

    private static func folderScannerStopsAfterProgressCancellation() throws {
        let folder = try disposableFolder(named: "ScanProgressCancellation")
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<30 {
            let url = folder.appendingPathComponent("PHOTO_\(index).JPG")
            try Data("placeholder".utf8).write(to: url)
        }

        var shouldCancel = false
        var didCancel = false
        do {
            _ = try FolderScanner.scan(folder, isCancelled: { shouldCancel }) { found in
                if found >= 25 { shouldCancel = true }
            }
        } catch is CancellationError {
            didCancel = true
        }
        try expect(didCancel, "an in-progress folder scan should stop after cancellation")
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

    private static func exportCollisionSuffixSkipsTakenNames() throws {
        let folder = try disposableFolder(named: "ExportCollision")
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("a".utf8).write(to: folder.appendingPathComponent("PAIR.JPG"))
        try Data("b".utf8).write(to: folder.appendingPathComponent("PAIR (1).JPG"))

        try expect(
            ExportWorker.collisionFreeURL(for: "PAIR.JPG", in: folder).lastPathComponent == "PAIR (2).JPG",
            "collision naming should skip every taken name"
        )
        try expect(
            ExportWorker.collisionFreeURL(for: "FREE.JPG", in: folder).lastPathComponent == "FREE.JPG",
            "an untaken name should pass through unchanged"
        )
    }

    private static func exportCopyCopiesEveryFileAndKeepsSources() throws {
        let source = try disposableFolder(named: "ExportCopySource")
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = try disposableFolder(named: "ExportCopyDestination")
        defer { try? FileManager.default.removeItem(at: destination) }
        let raw = source.appendingPathComponent("PAIR.NEF")
        let jpeg = source.appendingPathComponent("PAIR.JPG")
        let single = source.appendingPathComponent("SINGLE.JPG")
        try Data("raw".utf8).write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)
        try Data("single".utf8).write(to: single)
        let items = [
            makeItem(id: "PAIR.NEF", primaryURL: raw, pairedURL: jpeg),
            makeItem(id: "SINGLE.JPG", primaryURL: single),
        ]

        let result = ExportWorker.copy(items, to: destination) { _, _ in }
        try expect(result.copiedFiles == 3 && result.failedFiles == 0, "copy should duplicate every file")
        for name in ["PAIR.NEF", "PAIR.JPG", "SINGLE.JPG"] {
            try expect(
                FileManager.default.fileExists(atPath: destination.appendingPathComponent(name).path),
                "\(name) should exist at the destination"
            )
            try expect(
                FileManager.default.fileExists(atPath: source.appendingPathComponent(name).path),
                "\(name) should stay in the source folder"
            )
        }
    }

    private static func exportMoveReportsFullyMovedPhotos() throws {
        let source = try disposableFolder(named: "ExportMoveSource")
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = try disposableFolder(named: "ExportMoveDestination")
        defer { try? FileManager.default.removeItem(at: destination) }
        let raw = source.appendingPathComponent("PAIR.NEF")
        let jpeg = source.appendingPathComponent("PAIR.JPG")
        let single = source.appendingPathComponent("SINGLE.JPG")
        try Data("raw".utf8).write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)
        try Data("single".utf8).write(to: single)
        let items = [
            makeItem(id: "PAIR.NEF", primaryURL: raw, pairedURL: jpeg),
            makeItem(id: "SINGLE.JPG", primaryURL: single),
        ]

        let result = ExportWorker.move(items, to: destination) { _, _ in }
        try expect(
            result.movedItemIDs == ["PAIR.NEF", "SINGLE.JPG"],
            "every fully transferred photo should be reported for session removal"
        )
        try expect(result.movedFiles == 3 && result.failedPhotos == 0 && result.inconsistentPhotos == 0,
                   "a clean move should report no failures")
        for name in ["PAIR.NEF", "PAIR.JPG", "SINGLE.JPG"] {
            try expect(
                FileManager.default.fileExists(atPath: destination.appendingPathComponent(name).path),
                "\(name) should land at the destination under its own name"
            )
            try expect(
                !FileManager.default.fileExists(atPath: source.appendingPathComponent(name).path),
                "\(name) should leave the source folder"
            )
        }
    }

    private static func exportMovePairRollsBackOnPartialFailure() throws {
        let source = try disposableFolder(named: "ExportMoveRollback")
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = try disposableFolder(named: "ExportMoveRollbackDestination")
        defer { try? FileManager.default.removeItem(at: destination) }
        let raw = source.appendingPathComponent("PAIR.NEF")
        let missingJPEG = source.appendingPathComponent("MISSING.JPG")
        try Data("raw".utf8).write(to: raw)
        let item = makeItem(id: "PAIR.NEF", primaryURL: raw, pairedURL: missingJPEG)

        let result = ExportWorker.move([item], to: destination) { _, _ in }
        try expect(result.movedItemIDs.isEmpty, "an incomplete pair must not count as moved")
        try expect(result.failedPhotos == 1, "an incomplete pair should report one failed photo")
        try expect(result.inconsistentPhotos == 0, "a successful rollback should remain consistent")
        try expect(FileManager.default.fileExists(atPath: raw.path), "the first file must roll back when its pair fails")
        try expect(
            !FileManager.default.fileExists(atPath: destination.appendingPathComponent("PAIR.NEF").path),
            "no file of a failed pair may stay at the destination"
        )
    }

    private static func exportMoveRefusesInPlaceDestination() throws {
        let folder = try disposableFolder(named: "ExportMoveInPlace")
        defer { try? FileManager.default.removeItem(at: folder) }
        let single = folder.appendingPathComponent("SINGLE.JPG")
        try Data("single".utf8).write(to: single)
        let item = makeItem(id: "SINGLE.JPG", primaryURL: single)

        let result = ExportWorker.move([item], to: folder) { _, _ in }
        try expect(result.movedItemIDs.isEmpty && result.failedPhotos == 1,
                   "moving a photo into its own folder should be refused")
        try expect(FileManager.default.fileExists(atPath: single.path), "the original file must stay untouched")
        try expect(
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent("SINGLE (1).JPG").path),
            "an in-place move must not rename the original with a collision suffix"
        )
    }

    /// Each element written through `@Published items` copies the whole array
    /// and fires objectWillChange, so a per-element clear-all loop is O(N²)
    /// with thousands of publishes — the publish storm left stale rating
    /// badges in the Browser and froze large folders. Batched clearing must
    /// stay at one array publish however many photos change.
    @MainActor
    private static func clearAllRatingsPublishesOnceForLargeSessions() throws {
        let store = SessionStore()
        store.items = (0..<3000).map { i in
            var item = makeItem(id: String(format: "IMG_%04d.JPG", i))
            item.rating = i.isMultiple(of: 2) ? .yes : .no
            item.ratedAt = Date(timeIntervalSince1970: TimeInterval(i))
            return item
        }
        var publishes = 0
        let subscription = store.objectWillChange.sink { _ in publishes += 1 }
        defer { subscription.cancel() }

        let start = Date()
        store.clearAllRatings()
        let elapsed = Date().timeIntervalSince(start)

        try expect(publishes <= 3, "clear-all should publish the batch once, not per element (got \(publishes))")
        try expect(
            store.items.allSatisfy { $0.rating == .undecided && $0.ratedAt == nil },
            "clear-all should reset every rating"
        )
        try expect(store.ratedCount == 0 && store.undecidedCount == 3000, "clear-all should reset the tally")
        try expect(elapsed < 2, "clearing 3000 ratings should be near-instant (took \(elapsed)s)")
    }

    @MainActor
    private static func batchRatingUndoRestoresEveryRating() throws {
        let store = SessionStore()
        store.items = (0..<200).map { makeItem(id: String(format: "IMG_%04d.JPG", $0)) }
        // Recompute visibleIndices through the sort observer — applyFilter
        // itself is deliberately private.
        store.sort.ascending = false
        try expect(store.visibleIndices.count == 200, "every photo should be visible before selection")
        store.selectAllVisible()

        var publishes = 0
        let subscription = store.objectWillChange.sink { _ in publishes += 1 }
        store.rate(.yes)
        subscription.cancel()

        try expect(publishes <= 6, "batch rating should not publish per element (got \(publishes))")
        try expect(store.items.allSatisfy { $0.rating == .yes }, "rating a full selection should rate every photo")
        try expect(store.yesCount == 200, "the tally should count the whole batch")

        store.undo()
        try expect(
            store.items.allSatisfy { $0.rating == .undecided && $0.ratedAt == nil },
            "one undo should restore every rating in the batch"
        )
        try expect(store.ratedCount == 0, "undo should restore the tally")
    }

    @MainActor
    private static func exportMoveRemovalUpdatesSessionState() throws {
        let store = SessionStore()
        store.items = (0..<10).map { i in
            var item = makeItem(id: String(format: "IMG_%04d.JPG", i))
            item.rating = i < 4 ? .yes : (i < 7 ? .no : .undecided)
            return item
        }
        // Recompute visibleIndices through the sort observer — applyFilter
        // itself is deliberately private.
        store.sort.ascending = false
        try expect(store.visibleIndices.count == 10, "every photo should be visible before the move")
        store.rate(.no)
        try expect(store.canUndo, "a rating step should be undoable before the move")

        let movedIDs = (0..<4).map { String(format: "IMG_%04d.JPG", $0) }
        store.exportMoveWillStart()
        try expect(store.isMovingExport, "the in-flight flag should be up during the move")
        store.finishExportMove(movedIDs: movedIDs)

        try expect(!store.isMovingExport, "the in-flight flag should clear when the move finishes")
        try expect(
            store.items.map(\.id) == (4..<10).map { String(format: "IMG_%04d.JPG", $0) },
            "exactly the moved photos should leave the session, in order"
        )
        try expect(store.yesCount == 0 && store.items.count == 6, "the tally should be rebuilt from the survivors")
        try expect(store.visibleIndices.count == 6, "visible indices should shrink with the session")
        try expect(
            store.items.indices.contains(store.currentIndex),
            "the current photo must stay in bounds after the removal"
        )
        try expect(!store.canUndo, "a move export is not undoable — the stale undo stack must be cleared")
    }

    private static func makeItem(
        id: String,
        primaryURL: URL? = nil,
        pairedURL: URL? = nil,
        captureDate: Date? = nil,
        camera: String? = nil,
        lens: String? = nil,
        aperture: Double? = nil,
        shutter: Double? = nil,
        iso: Double? = nil,
        modificationDate: Date? = nil,
        fileSize: Int64 = 1,
        pairedFileSize: Int64 = 0
    ) -> PhotoItem {
        PhotoItem(
            id: id,
            primaryURL: primaryURL ?? URL(fileURLWithPath: "/tmp/\(id)"),
            pairedURL: pairedURL,
            captureDate: captureDate,
            cameraModel: camera,
            lensModel: lens,
            aperture: aperture,
            shutterSpeed: shutter,
            iso: iso,
            primaryModificationDate: modificationDate,
            fileSize: fileSize,
            pairedFileSize: pairedFileSize
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
