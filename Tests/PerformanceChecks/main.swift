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
        try mediaKindFilterSeparatesPhotosAndVideos()
        try durationFilterAndSortHandleImagesAsMissingValues()
        try durationFormattingCoversShortAndLongMovies()
        try selectionSummaryKeepsEveryDistinctMetadataValue()
        try pairedMetadataReportsEveryFileSize()
        try metadataSortKeepsMissingValuesLast()
        try subfolderFacetFiltersAndSortsByRelativePath()
        try folderScannerHonorsCancellation()
        try folderScannerStopsAfterProgressCancellation()
        try folderScannerFindsDeepMediaWithoutFollowingSymlinkLoop()
        try rawJPEGPairingIsDeterministic()
        try caseSensitivePairingKeepsDistinctBasenames()
        try videoNeverBecomesThePairForSameNamedRaw()
        try rawAndTiffStayIndependent()
        try rawJPEGPairingCanBeDisabled()
        try rawJPEGProjectionCachesMetadataAndPreservesRatings()
        try imageCacheKeyDoesNotTouchFilesystemAfterScan()
        try cleanUpScopeResolvesExpectedCandidates()
        try linearRestoreMergePreservesOrderAndOmitsLostPhoto()
        try await olderSidecarSaveCannotOverwriteNewerSnapshot()
        try await emptySidecarSnapshotIsPersisted()
        try await newerBackupWinsOverStaleSidecar()
        try await corruptSidecarRecoversFromBackup()
        try await invalidSessionSchemasAreRejected()
        try await persistenceReportsBackupAndTotalFailure()
        try exportCollisionSuffixSkipsTakenNames()
        try exportPairCollisionUsesSharedSuffix()
        try exportCopyCopiesEveryFileAndKeepsSources()
        try exportCopyPairRollsBackOnPartialFailure()
        try exportCopyCanCancelWithoutPartialPair()
        try exportMoveReportsFullyMovedPhotos()
        try exportMovePairRollsBackOnPartialFailure()
        try exportMoveRefusesInPlaceDestination()
        try exportDestinationRejectsSourceAndDescendant()
        try operationJournalRemovesInterruptedCopyIdempotently()
        try operationJournalRestoresInterruptedMove()
        try operationJournalPreservesCommittedExport()
        try operationJournalRefusesSameNamedReplacement()
        try operationJournalRestoresInterruptedTrash()
        try operationJournalCompletesInterruptedTrashUndo()
        try completedWorkerRemovesItsJournal()
        try scannerAndPreparedIndexShareDefaultOrder()
        try preparedSessionIndexKeepsStableGroupIdentity()
        try preparedSessionIndexScaleBaselines()
        try ratingMutationScaleBaseline()
        try selectionStatePreservesImplicitCurrentAndToggleRules()
        try selectionStateRangesFiltersAndRemapsByID()
        try visibleLocationMapTracksDerivedState()
        try ratingUndoFollowsStableIdentityAfterReorder()
        try await rescanPreservesCurrentPhotoAndSelectionByID()
        try await pairingToggleStaysReadyAndPersistsIndividualRatings()
        try clearAllRatingsPublishesOnceForLargeSessions()
        try batchRatingUndoRestoresEveryRating()
        try exportMoveRemovalUpdatesSessionState()
        if ProcessInfo.processInfo.environment["LOUPPE_SKIP_REAL_TRASH"] == "1" {
            print("Performance checks passed (59/61; 2 real Trash checks explicitly skipped)")
        } else {
            try cleanUpPairRoundTripsThroughTrash()
            try cleanUpPairFailureRollsBackFirstFile()
            print("Performance checks passed (61/61)")
        }
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

    private static func mediaKindFilterSeparatesPhotosAndVideos() throws {
        let photo = makeItem(id: "PHOTO.JPG")
        let video = makeItem(id: "VIDEO.MOV", mediaKind: .video, duration: 12, videoIsPlayable: true)
        var filter = PhotoFilter()
        filter.excludedMediaKinds = [.photo]
        let prepared = PreparedPhotoFilter(filter)
        try expect(!prepared.matches(photo), "media filter should exclude switched-off photos")
        try expect(prepared.matches(video), "media filter should keep enabled videos")
    }

    private static func durationFilterAndSortHandleImagesAsMissingValues() throws {
        let photo = makeItem(id: "PHOTO.JPG")
        let short = makeItem(id: "SHORT.MOV", mediaKind: .video, duration: 12, videoIsPlayable: true)
        let long = makeItem(id: "LONG.MP4", mediaKind: .video, duration: 95, videoIsPlayable: true)
        var filter = PhotoFilter()
        filter.durationEnabled = true
        filter.durationFrom = 10
        filter.durationTo = 20
        let prepared = PreparedPhotoFilter(filter)
        try expect(prepared.matches(short), "duration range should include a video inside its bounds")
        try expect(!prepared.matches(long), "duration range should exclude a longer video")
        try expect(!prepared.matches(photo), "an active duration range should exclude images without duration")

        let ascending = PhotoSort(key: .duration, ascending: true)
        let ordered = [photo, long, short].sorted(by: ascending.areInOrder)
        try expect(ordered.map(\.id) == ["SHORT.MOV", "LONG.MP4", "PHOTO.JPG"], "duration sort should keep missing values last")
    }

    private static func durationFormattingCoversShortAndLongMovies() throws {
        try expect(MediaDurationFormat.display(0) == "0:00", "zero duration should stay visible")
        try expect(MediaDurationFormat.display(65) == "1:05", "minute duration should be zero padded")
        try expect(MediaDurationFormat.display(3_661) == "1:01:01", "hour duration should include hours")
        try expect(MediaDurationFormat.display(nil) == "--:--", "missing duration should keep a visible placeholder")
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
        try expect(summary.fileCount == 5, "selection summary should count both members of a paired photo")
        try expect(summary.photoCount == 4 && summary.videoCount == 0,
                   "selection summary should retain the selected media kinds")
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

        let mixed = PhotoSelectionSummary(items: [
            makeItem(id: "PHOTO.JPG"),
            makeItem(id: "VIDEO.MOV", mediaKind: .video, videoIsPlayable: true),
        ])
        try expect(
            mixed.fileCount == 2 && mixed.photoCount == 1 && mixed.videoCount == 1,
            "mixed selections should report both media kinds and filesystem entries"
        )
    }

    private static func pairedMetadataReportsEveryFileSize() throws {
        let item = makeItem(
            id: "PAIR.NEF",
            pairedURL: URL(fileURLWithPath: "/tmp/PAIR.JPG"),
            fileSize: 40,
            pairedFileSize: 5
        )
        let fields = MetadataExtractor.fields(for: item)
        let labels = Set(fields.map(\.label))
        try expect(
            labels.isSuperset(of: ["Primary size", "Paired size", "Total size"]),
            "paired metadata should identify each file's size and their total"
        )
        try expect(!labels.contains("File size"), "paired metadata should not imply that the primary size is the whole pair")
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

        let cancelFlag = FolderScanner.CancelFlag()
        var didCancel = false
        do {
            _ = try FolderScanner.scan(folder, isCancelled: { cancelFlag.isSet }) { found in
                if found >= 25 { cancelFlag.set() }
            }
        } catch is CancellationError {
            didCancel = true
        }
        try expect(didCancel, "an in-progress folder scan should stop after cancellation")
    }

    private static func folderScannerFindsDeepMediaWithoutFollowingSymlinkLoop() throws {
        let folder = try disposableFolder(named: "DeepScan")
        defer { try? FileManager.default.removeItem(at: folder) }
        var deep = folder
        for level in 1...8 {
            deep.appendPathComponent("Level\(level)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data("placeholder".utf8).write(to: deep.appendingPathComponent("DEEP.JPG"))
        try FileManager.default.createSymbolicLink(
            at: deep.appendingPathComponent("LoopToRoot", isDirectory: true),
            withDestinationURL: folder
        )

        let items = try FolderScanner.scan(folder) { _ in }
        try expect(items.count == 1, "deep scan should find one real photo and never follow the loop")
        try expect(
            items[0].id.hasSuffix("Level8/DEEP.JPG"),
            "media below the former depth cutoff should appear in the session"
        )
    }

    private static func rawJPEGPairingIsDeterministic() throws {
        let root = URL(fileURLWithPath: "/tmp/DeterministicPairing")
        let files = [
            root.appendingPathComponent("SHOT.NEF"),
            root.appendingPathComponent("SHOT.JPG"),
            root.appendingPathComponent("SHOT.DNG"),
            root.appendingPathComponent("OTHER.JPG"),
        ]
        let forward = FolderScanner.pairFiles(
            files,
            pairingMode: .together,
            caseSensitiveNames: false
        )
        let reversed = FolderScanner.pairFiles(
            Array(files.reversed()),
            pairingMode: .together,
            caseSensitiveNames: false
        )
        let describe: ([(primary: URL, paired: URL?)]) -> [String] = {
            $0.map {
                "\($0.primary.lastPathComponent)|\($0.paired?.lastPathComponent ?? "-")"
            }
        }
        try expect(
            describe(forward) == describe(reversed),
            "pair choice and leftover order must not depend on enumerator input order"
        )
    }

    private static func caseSensitivePairingKeepsDistinctBasenames() throws {
        let root = URL(fileURLWithPath: "/tmp/CaseSensitivePairing")
        let files = [
            root.appendingPathComponent("SHOT.NEF"),
            root.appendingPathComponent("shot.JPG"),
        ]
        let sensitive = FolderScanner.pairFiles(
            files,
            pairingMode: .together,
            caseSensitiveNames: true
        )
        let insensitive = FolderScanner.pairFiles(
            files,
            pairingMode: .together,
            caseSensitiveNames: false
        )
        try expect(
            sensitive.count == 2 && sensitive.allSatisfy { $0.paired == nil },
            "case-sensitive volumes must keep case-distinct basenames independent"
        )
        try expect(
            insensitive.count == 1 && insensitive[0].paired != nil,
            "case-insensitive volumes should still pair case-only filename variants"
        )
    }

    private static func videoNeverBecomesThePairForSameNamedRaw() throws {
        let folder = try disposableFolder(named: "VideoPairing")
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("CLIP.NEF")
        let jpeg = folder.appendingPathComponent("CLIP.JPG")
        let video = folder.appendingPathComponent("CLIP.MOV")
        try Data().write(to: raw)
        try Data().write(to: jpeg)
        try Data().write(to: video)

        let items = try FolderScanner.scan(folder) { _ in }
        try expect(items.count == 2, "RAW+JPEG and same-named video should produce two review items")
        guard let rawItem = items.first(where: { $0.primaryURL == raw }),
              let videoItem = items.first(where: { $0.primaryURL == video }) else {
            throw CheckFailure("scanner dropped RAW or same-named video")
        }
        try expect(rawItem.pairedURL == jpeg, "RAW should pair only with its JPEG")
        try expect(videoItem.pairedURL == nil && videoItem.isVideo, "video should remain an independent item")
    }

    private static func rawAndTiffStayIndependent() throws {
        let folder = try disposableFolder(named: "RawTiffPairing")
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("SHOT.NEF")
        let tiff = folder.appendingPathComponent("SHOT.TIFF")
        try Data().write(to: raw)
        try Data().write(to: tiff)

        let items = try FolderScanner.scan(folder) { _ in }
        try expect(items.count == 2, "same-named RAW and TIFF should produce two review items")
        try expect(items.allSatisfy { $0.pairedURL == nil }, "TIFF should never become a RAW pair")
        try expect(
            Set(items.map(\.fileTypeLabel)) == ["RAW", "TIFF"],
            "same-named RAW and TIFF should retain their individual file types"
        )
    }

    private static func rawJPEGPairingCanBeDisabled() throws {
        let folder = try disposableFolder(named: "RawJPEGPairingMode")
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("SHOT.NEF")
        let jpeg = folder.appendingPathComponent("SHOT.JPG")
        try Data().write(to: raw)
        try Data().write(to: jpeg)

        let paired = try FolderScanner.scan(folder) { _ in }
        try expect(paired.count == 1, "RAW+JPEG should stay one item by default")
        try expect(paired[0].fileTypeLabel == "RAW + JPEG", "default pairing should use the combined type")

        let separate = try FolderScanner.scan(folder, pairingMode: .separate) { _ in }
        try expect(separate.count == 2, "separate pairing mode should expose both files")
        try expect(separate.allSatisfy { $0.pairedURL == nil }, "separate pairing mode should remove the partner link")
        try expect(
            Set(separate.map(\.fileTypeLabel)) == ["RAW", "JPEG"],
            "separate pairing mode should expose independent file types"
        )
    }

    private static func rawJPEGProjectionCachesMetadataAndPreservesRatings() throws {
        let root = URL(fileURLWithPath: "/tmp/LouppePairingProjection", isDirectory: true)
        let rawURL = root.appendingPathComponent("SHOT.NEF")
        let jpegURL = root.appendingPathComponent("SHOT.JPG")

        let raw = makeItem(id: "SHOT.NEF", primaryURL: rawURL)
        let rawValueCopy = raw
        raw.rating = .yes
        try expect(
            rawValueCopy.rating == .yes,
            "PhotoItem value copies should share only their physical-file rating storage"
        )
        let jpeg = makeItem(id: "SHOT.JPG", primaryURL: jpegURL)
        jpeg.rating = .no
        let grouped = try FolderScanner.projectPairingMode(
            .together,
            from: [raw, jpeg],
            root: root
        )
        try expect(grouped.items.count == 1, "in-memory projection should form one RAW+JPEG item")
        try expect(
            grouped.items[0].hasMixedRatings && grouped.items[0].rating == .undecided,
            "conflicting file ratings should become Mixed rather than choosing one"
        )
        let groupedRatings = Dictionary(
            uniqueKeysWithValues: grouped.items[0].ratingSnapshots.map {
                ($0.fileID, $0.rating)
            }
        )
        try expect(
            groupedRatings == ["SHOT.NEF": .yes, "SHOT.JPG": .no],
            "grouping must retain both physical-file ratings"
        )

        let separated = try FolderScanner.projectPairingMode(
            .separate,
            from: grouped.items,
            root: root
        )
        let separatedRatings = Dictionary(
            uniqueKeysWithValues: separated.items.map { ($0.id, $0.rating) }
        )
        try expect(
            separatedRatings == ["SHOT.NEF": .yes, "SHOT.JPG": .no],
            "separating a Mixed pair should restore its exact individual ratings"
        )

        let lightweightPair = PhotoItem(
            id: "SHOT.NEF",
            primaryURL: rawURL,
            pairedURL: jpegURL,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 10,
            pairedFileSize: 5
        )
        let firstSplit = try FolderScanner.projectPairingMode(
            .separate,
            from: [lightweightPair],
            root: root
        )
        try expect(
            firstSplit.enrichedFileCount == 1,
            "the first split should enrich only the lightweight JPEG partner"
        )
        let regrouped = try FolderScanner.projectPairingMode(
            .together,
            from: firstSplit.items,
            root: root
        )
        let secondSplit = try FolderScanner.projectPairingMode(
            .separate,
            from: regrouped.items,
            root: root
        )
        try expect(
            secondSplit.enrichedFileCount == 0,
            "later toggles should reuse cached JPEG metadata"
        )
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
        _ = await persistence.save(
            session(rating: Rating.yes.rawValue, folder: folder),
            for: folder,
            sequence: 2
        )
        _ = await persistence.save(
            session(rating: Rating.no.rawValue, folder: folder),
            for: folder,
            sequence: 1
        )
        let loaded = await persistence.read(for: folder)
        try expect(
            loaded.session?.entries.first?.rating == Rating.yes.rawValue,
            "older save should not replace newer sidecar"
        )
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
        _ = await persistence.save(empty, for: folder, sequence: 1)
        let loaded = await persistence.read(for: folder)
        try expect(
            loaded.session?.entries.isEmpty == true,
            "empty ready session should replace a stale sidecar"
        )
    }

    private static func newerBackupWinsOverStaleSidecar() async throws {
        let root = try disposableFolder(named: "PersistenceNewest")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Photos", isDirectory: true)
        let backup = root.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let persistence = SessionPersistence(backupDirectory: backup)
        let old = session(
            rating: Rating.no.rawValue,
            folder: folder,
            scannedAt: Date(timeIntervalSince1970: 1)
        )
        let new = session(
            rating: Rating.yes.rawValue,
            folder: folder,
            scannedAt: Date(timeIntervalSince1970: 2)
        )
        _ = await persistence.save(old, for: folder, sequence: 1)
        let sidecar = folder.appendingPathComponent(SessionConstants.sidecarName)
        let oldSidecar = try Data(contentsOf: sidecar)
        _ = await persistence.save(new, for: folder, sequence: 2)
        try oldSidecar.write(to: sidecar, options: .atomic)

        let loaded = await persistence.read(for: folder)
        try expect(loaded.origin == .backup, "the newest valid snapshot should win even when it is the backup")
        try expect(
            loaded.session?.entries.first?.rating == Rating.yes.rawValue,
            "a stale sidecar must not resurrect an older rating"
        )
    }

    private static func corruptSidecarRecoversFromBackup() async throws {
        let root = try disposableFolder(named: "PersistenceRecovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Photos", isDirectory: true)
        let backup = root.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let persistence = SessionPersistence(backupDirectory: backup)
        _ = await persistence.save(
            session(rating: Rating.yes.rawValue, folder: folder),
            for: folder,
            sequence: 1
        )
        try Data("not-json".utf8).write(
            to: folder.appendingPathComponent(SessionConstants.sidecarName),
            options: .atomic
        )

        let loaded = await persistence.read(for: folder)
        try expect(loaded.origin == .backup, "a corrupt sidecar should recover from the last-known-good backup")
        try expect(loaded.recoveryMessage != nil, "backup recovery should be visible to the photographer")
        try expect(
            loaded.session?.entries.first?.rating == Rating.yes.rawValue,
            "backup recovery should preserve the saved rating"
        )
    }

    private static func invalidSessionSchemasAreRejected() async throws {
        let root = try disposableFolder(named: "PersistenceSchema")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Photos", isDirectory: true)
        let backup = root.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let persistence = SessionPersistence(backupDirectory: backup)
        let sidecar = folder.appendingPathComponent(SessionConstants.sidecarName)
        _ = await persistence.save(
            session(rating: Rating.yes.rawValue, folder: folder),
            for: folder,
            sequence: 1
        )

        var invalidVersion = session(rating: Rating.yes.rawValue, folder: folder)
        invalidVersion.version = 99
        try writeSessionFixture(invalidVersion, to: sidecar)
        var loaded = await persistence.read(for: folder)
        try expect(
            loaded.blockingMessage != nil,
            "an unsupported sidecar must be left untouched even when an older backup is valid"
        )

        let wrongFolder = session(
            rating: Rating.yes.rawValue,
            folder: root.appendingPathComponent("Different")
        )
        try writeSessionFixture(wrongFolder, to: sidecar)
        loaded = await persistence.read(for: folder)
        try expect(
            loaded.blockingMessage != nil,
            "ratings from a different folder must never be applied"
        )

        try FileManager.default.removeItem(at: backup)
        var invalidRating = session(rating: "maybe", folder: folder)
        invalidRating.entries[0].filename = "../OUTSIDE.JPG"
        try writeSessionFixture(invalidRating, to: sidecar)
        loaded = await persistence.read(for: folder)
        try expect(
            loaded.session == nil && loaded.blockingMessage != nil,
            "invalid ratings and unsafe relative paths must be rejected"
        )
    }

    private static func persistenceReportsBackupAndTotalFailure() async throws {
        let root = try disposableFolder(named: "PersistenceFailures")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourcePlaceholder = root.appendingPathComponent("NotAFolder")
        try Data("file".utf8).write(to: sourcePlaceholder)

        let workingBackup = root.appendingPathComponent("Backup", isDirectory: true)
        let backupPersistence = SessionPersistence(backupDirectory: workingBackup)
        let backupResult = await backupPersistence.save(
            session(rating: Rating.yes.rawValue, folder: sourcePlaceholder),
            for: sourcePlaceholder,
            sequence: 1
        )
        guard case .savedToBackup = backupResult else {
            throw CheckFailure("a failed sidecar with a writable backup should report backup-only safety")
        }

        let blockedBackup = root.appendingPathComponent("BackupBlocker")
        try Data("file".utf8).write(to: blockedBackup)
        let failingPersistence = SessionPersistence(backupDirectory: blockedBackup)
        let failure = await failingPersistence.save(
            session(rating: Rating.no.rawValue, folder: sourcePlaceholder),
            for: sourcePlaceholder,
            sequence: 1
        )
        guard case .failed = failure else {
            throw CheckFailure("failure of both destinations must be reported explicitly")
        }
    }

    private static func cleanUpPairRoundTripsThroughTrash() throws {
        let folder = try disposableFolder(named: "CleanUpRoundTrip")
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("PAIR.NEF")
        let jpeg = folder.appendingPathComponent("PAIR.JPG")
        try Data("raw".utf8).write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)
        let item = makeItem(id: "PAIR.NEF", primaryURL: raw, pairedURL: jpeg)
        let journals = folder.appendingPathComponent("Journals", isDirectory: true)

        let trashed = CleanUpWorker.moveToTrash(
            [CleanUpPhotoSnapshot(index: 0, item: item)],
            journalDirectory: journals
        ) { _, _ in }
        try expect(
            trashed.succeeded.count == 1,
            "paired photo should move to Trash "
                + "(failed=\(trashed.failedPhotos), journal=\(trashed.journalFailure), recovery=\(trashed.requiresRecovery))"
        )
        try expect(trashed.inconsistentPhotos == 0, "successful Trash move should be consistent")
        try expect(!FileManager.default.fileExists(atPath: raw.path), "RAW should leave its folder")
        try expect(!FileManager.default.fileExists(atPath: jpeg.path), "JPEG should leave its folder")

        let restored = CleanUpWorker.restore(
            trashed.succeeded,
            journalDirectory: journals
        ) { _, _ in }
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
        let journals = folder.appendingPathComponent("Journals", isDirectory: true)

        let result = CleanUpWorker.moveToTrash(
            [CleanUpPhotoSnapshot(index: 0, item: item)],
            journalDirectory: journals
        ) { _, _ in }
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

        let result = ExportWorker.copy(
            items,
            to: destination,
            journalDirectory: source.appendingPathComponent("Journals", isDirectory: true)
        ) { _, _ in }
        try expect(
            result.copiedFiles == 3 && result.failedPhotos == 0
                && result.inconsistentPhotos == 0 && !result.cancelled,
            "copy should duplicate every file"
        )
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

    private static func exportPairCollisionUsesSharedSuffix() throws {
        let source = try disposableFolder(named: "ExportPairCollisionSource")
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = try disposableFolder(named: "ExportPairCollisionDestination")
        defer { try? FileManager.default.removeItem(at: destination) }
        let raw = source.appendingPathComponent("PAIR.NEF")
        let jpeg = source.appendingPathComponent("PAIR.JPG")
        try Data("new raw".utf8).write(to: raw)
        try Data("new jpeg".utf8).write(to: jpeg)
        try Data("existing raw".utf8).write(to: destination.appendingPathComponent("PAIR.NEF"))

        let item = makeItem(id: "PAIR.NEF", primaryURL: raw, pairedURL: jpeg)
        let result = ExportWorker.copy(
            [item],
            to: destination,
            journalDirectory: source.appendingPathComponent("Journals", isDirectory: true)
        ) { _, _ in }

        try expect(result.copiedFiles == 2 && result.failedPhotos == 0,
                   "a colliding pair should still copy completely")
        try expect(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("PAIR (1).NEF").path),
            "the colliding RAW should receive suffix 1"
        )
        try expect(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("PAIR (1).JPG").path),
            "the JPEG should receive the RAW's same suffix even when its unsuffixed name was free"
        )
        try expect(
            !FileManager.default.fileExists(atPath: destination.appendingPathComponent("PAIR.JPG").path),
            "a pair member must not keep an unmatched unsuffixed basename"
        )
    }

    private static func exportCopyPairRollsBackOnPartialFailure() throws {
        let source = try disposableFolder(named: "ExportCopyRollbackSource")
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = try disposableFolder(named: "ExportCopyRollbackDestination")
        defer { try? FileManager.default.removeItem(at: destination) }
        let raw = source.appendingPathComponent("PAIR.NEF")
        let missingJPEG = source.appendingPathComponent("PAIR.JPG")
        try Data("raw".utf8).write(to: raw)
        let item = makeItem(id: "PAIR.NEF", primaryURL: raw, pairedURL: missingJPEG)

        let result = ExportWorker.copy(
            [item],
            to: destination,
            journalDirectory: source.appendingPathComponent("Journals", isDirectory: true)
        ) { _, _ in }
        try expect(result.copiedFiles == 0, "a failed pair must not count a partial copy")
        try expect(result.failedPhotos == 1, "a failed pair should report one failed photo")
        try expect(result.inconsistentPhotos == 0, "successful copy rollback should remain consistent")
        try expect(
            !FileManager.default.fileExists(atPath: destination.appendingPathComponent("PAIR.NEF").path),
            "the first copied member must be removed when its partner fails"
        )
        try expect(FileManager.default.fileExists(atPath: raw.path), "copy rollback must never touch the original")
    }

    private static func exportCopyCanCancelWithoutPartialPair() throws {
        let source = try disposableFolder(named: "ExportCopyCancelSource")
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = try disposableFolder(named: "ExportCopyCancelDestination")
        defer { try? FileManager.default.removeItem(at: destination) }
        let raw = source.appendingPathComponent("PAIR.NEF")
        let jpeg = source.appendingPathComponent("PAIR.JPG")
        try Data("raw".utf8).write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)
        let item = makeItem(id: "PAIR.NEF", primaryURL: raw, pairedURL: jpeg)
        let cancellation = CancellationAfterChecks(3)

        let result = ExportWorker.copy(
            [item],
            to: destination,
            journalDirectory: source.appendingPathComponent("Journals", isDirectory: true),
            isCancelled: { cancellation.shouldCancel() }
        ) { _, _ in }

        try expect(result.cancelled, "copy should report photographer cancellation")
        try expect(result.copiedFiles == 0, "the in-progress pair must not count as completed")
        try expect(result.failedPhotos == 0, "cancellation is not a copy failure")
        try expect(
            !FileManager.default.fileExists(atPath: destination.appendingPathComponent("PAIR.NEF").path),
            "cancelling between pair members must remove the first destination file"
        )
        try expect(
            !FileManager.default.fileExists(atPath: destination.appendingPathComponent("PAIR.JPG").path),
            "cancellation must not leave the second destination file either"
        )
        try expect(
            FileManager.default.fileExists(atPath: raw.path)
                && FileManager.default.fileExists(atPath: jpeg.path),
            "cancelling Copy must leave both originals untouched"
        )
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

        let result = ExportWorker.move(
            items,
            to: destination,
            journalDirectory: source.appendingPathComponent("Journals", isDirectory: true)
        ) { _, _ in }
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

        let result = ExportWorker.move(
            [item],
            to: destination,
            journalDirectory: source.appendingPathComponent("Journals", isDirectory: true)
        ) { _, _ in }
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

        let result = ExportWorker.move(
            [item],
            to: folder,
            journalDirectory: folder.appendingPathComponent("Journals", isDirectory: true)
        ) { _, _ in }
        try expect(result.movedItemIDs.isEmpty && result.failedPhotos == 1,
                   "moving a photo into its own folder should be refused")
        try expect(FileManager.default.fileExists(atPath: single.path), "the original file must stay untouched")
        try expect(
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent("SINGLE (1).JPG").path),
            "an in-place move must not rename the original with a collision suffix"
        )
    }

    private static func exportDestinationRejectsSourceAndDescendant() throws {
        let source = try disposableFolder(named: "ExportDestinationSource")
        defer { try? FileManager.default.removeItem(at: source) }
        let child = source.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let outside = try disposableFolder(named: "ExportDestinationOutside")
        defer { try? FileManager.default.removeItem(at: outside) }
        let alias = outside.appendingPathComponent("AliasIntoSource", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)
        // This check targets path safety only. Some restricted test runners
        // report zero available capacity for their disposable volume.
        let item = makeItem(id: "PHOTO.JPG", fileSize: 0)

        try expectValidationError(
            .sourceFolder,
            source: source,
            destination: source,
            item: item
        )
        try expectValidationError(
            .insideSourceFolder,
            source: source,
            destination: child,
            item: item
        )
        try expectValidationError(
            .insideSourceFolder,
            source: source,
            destination: alias,
            item: item
        )
        try ExportDestinationValidator.validate(
            sourceFolder: source,
            destination: outside,
            items: [item],
            mode: .copy
        )
    }

    private static func operationJournalRemovesInterruptedCopyIdempotently() throws {
        let root = try disposableFolder(named: "JournalCopyRecovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SOURCE.JPG")
        let destination = root.appendingPathComponent("COPIED.JPG")
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try Data("source".utf8).write(to: source)

        let writer = try FileOperationJournal.start(
            kind: .exportCopy,
            seeds: [.init(itemID: "SOURCE.JPG", source: source, destination: destination)],
            directory: journals
        )
        guard let temporary = writer.temporaryURL(at: 0) else {
            throw CheckFailure("copy journal should reserve a temporary path")
        }
        try writer.mark(.started, fileAt: 0)
        try FileManager.default.copyItem(at: source, to: temporary)
        try writer.mark(.staged, fileAt: 0, identityAt: temporary)
        try FileManager.default.moveItem(at: temporary, to: destination)
        try writer.mark(.completed, fileAt: 0, identityAt: destination)

        let report = FileOperationJournal.recoverPendingOperations(directory: journals)
        try expect(report.restoredOperations == 1, "interrupted copy should recover as one operation")
        try expect(report.removedPartialCopies == 1, "recovery should remove the partial destination copy")
        try expect(FileManager.default.fileExists(atPath: source.path), "copy recovery must preserve the original")
        try expect(!FileManager.default.fileExists(atPath: destination.path), "copy recovery should remove its own copy")
        try expect(!FileOperationJournal.hasPendingOperations(directory: journals), "resolved copy journal should be removed")

        let secondReport = FileOperationJournal.recoverPendingOperations(directory: journals)
        try expect(secondReport.foundOperations == 0, "repeating recovery should be a no-op")
    }

    private static func operationJournalRestoresInterruptedMove() throws {
        let root = try disposableFolder(named: "JournalMoveRecovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SOURCE.NEF")
        let destination = root.appendingPathComponent("MOVED.NEF")
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try Data("raw".utf8).write(to: source)

        let writer = try FileOperationJournal.start(
            kind: .exportMove,
            seeds: [.init(itemID: "SOURCE.NEF", source: source, destination: destination)],
            directory: journals
        )
        guard let temporary = writer.temporaryURL(at: 0) else {
            throw CheckFailure("move journal should reserve a temporary path")
        }
        try writer.mark(.started, fileAt: 0)
        try FileManager.default.moveItem(at: source, to: temporary)
        try writer.mark(.staged, fileAt: 0, identityAt: temporary)
        // Simulate termination after the final rename but before `.completed`.
        try FileManager.default.moveItem(at: temporary, to: destination)

        let report = FileOperationJournal.recoverPendingOperations(directory: journals)
        try expect(report.restoredFiles == 1, "interrupted move should restore one source file")
        try expect(FileManager.default.fileExists(atPath: source.path), "move recovery should restore the original path")
        try expect(!FileManager.default.fileExists(atPath: destination.path), "move recovery should empty its destination")
    }

    private static func operationJournalPreservesCommittedExport() throws {
        let root = try disposableFolder(named: "JournalCommitted")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SOURCE.JPG")
        let destination = root.appendingPathComponent("COPIED.JPG")
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try Data("source".utf8).write(to: source)

        let writer = try FileOperationJournal.start(
            kind: .exportCopy,
            seeds: [.init(itemID: "SOURCE.JPG", source: source, destination: destination)],
            directory: journals
        )
        guard let temporary = writer.temporaryURL(at: 0) else {
            throw CheckFailure("copy journal should reserve a temporary path")
        }
        try writer.mark(.started, fileAt: 0)
        try FileManager.default.copyItem(at: source, to: temporary)
        try writer.mark(.staged, fileAt: 0, identityAt: temporary)
        try FileManager.default.moveItem(at: temporary, to: destination)
        try writer.mark(.completed, fileAt: 0, identityAt: destination)
        try writer.markCommitted()

        let report = FileOperationJournal.recoverPendingOperations(directory: journals)
        try expect(report.committedOperations == 1, "committed operation should only clear its stale journal")
        try expect(FileManager.default.fileExists(atPath: destination.path), "committed destination must be preserved")
        try expect(FileManager.default.fileExists(atPath: source.path), "committed copy must preserve its source")
    }

    private static func operationJournalRefusesSameNamedReplacement() throws {
        let root = try disposableFolder(named: "JournalIdentity")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SOURCE.JPG")
        let destination = root.appendingPathComponent("COPIED.JPG")
        let replacement = root.appendingPathComponent("REPLACEMENT.JPG")
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try Data("source".utf8).write(to: source)
        try Data("replacement".utf8).write(to: replacement)

        let writer = try FileOperationJournal.start(
            kind: .exportCopy,
            seeds: [.init(itemID: "SOURCE.JPG", source: source, destination: destination)],
            directory: journals
        )
        guard let temporary = writer.temporaryURL(at: 0) else {
            throw CheckFailure("copy journal should reserve a temporary path")
        }
        try writer.mark(.started, fileAt: 0)
        try FileManager.default.copyItem(at: source, to: temporary)
        try writer.mark(.staged, fileAt: 0, identityAt: temporary)
        try FileManager.default.moveItem(at: temporary, to: destination)
        try writer.mark(.completed, fileAt: 0, identityAt: destination)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: replacement, to: destination)

        let report = FileOperationJournal.recoverPendingOperations(directory: journals)
        try expect(report.unresolvedFiles == 1, "replacement identity should keep recovery unresolved")
        let replacementContents = String(
            data: try Data(contentsOf: destination),
            encoding: .utf8
        )
        try expect(
            replacementContents == "replacement",
            "recovery must leave a same-named replacement untouched"
        )
        try expect(FileOperationJournal.hasPendingOperations(directory: journals), "unresolved journal should remain retryable")
    }

    private static func operationJournalRestoresInterruptedTrash() throws {
        let root = try disposableFolder(named: "JournalTrash")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SOURCE.JPG")
        let simulatedTrash = root.appendingPathComponent("TRASHED.JPG")
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try Data("source".utf8).write(to: source)

        let writer = try FileOperationJournal.start(
            kind: .moveToTrash,
            seeds: [.init(itemID: "SOURCE.JPG", source: source, destination: nil)],
            directory: journals
        )
        try writer.mark(.started, fileAt: 0)
        try FileManager.default.moveItem(at: source, to: simulatedTrash)
        try writer.mark(
            .completed,
            fileAt: 0,
            resolvedDestination: simulatedTrash,
            identityAt: simulatedTrash
        )

        let report = FileOperationJournal.recoverPendingOperations(directory: journals)
        try expect(report.restoredFiles == 1, "interrupted Trash should restore the source")
        try expect(FileManager.default.fileExists(atPath: source.path), "Trash recovery should restore the original path")
        try expect(!FileManager.default.fileExists(atPath: simulatedTrash.path), "recovered Trash location should be empty")
    }

    private static func operationJournalCompletesInterruptedTrashUndo() throws {
        let root = try disposableFolder(named: "JournalTrashUndo")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SOURCE.JPG")
        let simulatedTrash = root.appendingPathComponent("TRASHED.JPG")
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try Data("trashed".utf8).write(to: simulatedTrash)

        let writer = try FileOperationJournal.start(
            kind: .restoreFromTrash,
            seeds: [.init(
                itemID: "SOURCE.JPG",
                source: source,
                destination: simulatedTrash,
                identityURL: simulatedTrash
            )],
            directory: journals
        )
        try writer.mark(.started, fileAt: 0)
        try FileManager.default.moveItem(at: simulatedTrash, to: source)

        let report = FileOperationJournal.recoverPendingOperations(directory: journals)
        try expect(report.restoredOperations == 1, "interrupted Trash undo should finish cleanly")
        try expect(FileManager.default.fileExists(atPath: source.path), "Trash undo recovery should keep the restored source")
        try expect(!FileManager.default.fileExists(atPath: simulatedTrash.path), "Trash undo should not duplicate the file")
    }

    private static func completedWorkerRemovesItsJournal() throws {
        let root = try disposableFolder(named: "WorkerJournalCleanup")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFolder = root.appendingPathComponent("Source", isDirectory: true)
        let destinationFolder = root.appendingPathComponent("Destination", isDirectory: true)
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let source = sourceFolder.appendingPathComponent("SOURCE.JPG")
        try Data("source".utf8).write(to: source)

        let result = ExportWorker.copy(
            [makeItem(id: "SOURCE.JPG", primaryURL: source)],
            to: destinationFolder,
            journalDirectory: journals
        ) { _, _ in }
        try expect(result.copiedFiles == 1 && !result.requiresRecovery, "normal worker copy should complete")
        try expect(!FileOperationJournal.hasPendingOperations(directory: journals), "completed worker should remove its journal")
    }

    private static func scannerAndPreparedIndexShareDefaultOrder() throws {
        let sameTime = Date(timeIntervalSince1970: 1_700_000_000)
        let unsorted = [
            makeItem(id: "A/Z.JPG", captureDate: sameTime),
            makeItem(id: "B/A.JPG", captureDate: sameTime),
            makeItem(
                id: "OLDER.JPG",
                captureDate: sameTime.addingTimeInterval(-1)
            ),
            makeItem(id: "UNKNOWN.JPG", captureDate: nil),
        ]
        let scannerOrder = FolderScanner.sortItems(unsorted)
        let expected = unsorted.sorted(by: PhotoSort().areInOrder)
        try expect(
            scannerOrder.map(\.id) == expected.map(\.id),
            "scanner order should exactly match the default UI comparator"
        )

        var index = PreparedSessionIndex()
        index.rebuildItems(scannerOrder, sort: PhotoSort())
        try expect(
            index.sortedIndices == Array(scannerOrder.indices),
            "default prepared order should reuse the scanner's physical order"
        )
    }

    private static func preparedSessionIndexKeepsStableGroupIdentity() throws {
        let items = [
            makeItem(id: "ALPHA_FIRST.JPG", camera: "Alpha"),
            makeItem(id: "ALPHA_SECOND.PNG", camera: "Alpha"),
            makeItem(id: "BETA.JPG", camera: "Beta"),
        ]
        let sort = PhotoSort(key: .camera, ascending: true)
        var index = PreparedSessionIndex()
        index.rebuildItems(items, sort: sort)
        index.applyFilter(
            PhotoFilter(),
            to: items,
            sort: sort,
            isGroupingEnabled: true
        )

        try expect(index.visibleGroups.count == 2, "camera sort should create two stable groups")
        let alphaID = index.visibleGroups[0].id
        try expect(
            index.itemIndex(forID: "ALPHA_SECOND.PNG") == 1,
            "prepared index should expose stable id lookup"
        )
        try expect(
            index.location(forItemIndex: 1)?.position == 1,
            "prepared index should expose global navigation position"
        )

        var filter = PhotoFilter()
        filter.excludedTypes = ["JPEG"]
        index.applyFilter(
            filter,
            to: items,
            sort: sort,
            isGroupingEnabled: true
        )
        try expect(
            index.visibleGroups.first?.id == alphaID,
            "a group id should survive filtering out its former first member"
        )
        try expect(
            index.visibleGroups.first?.indices == [1],
            "filtered camera group should retain only its visible member"
        )
        try expect(
            index.visibleEntries == [
                .init(id: "ALPHA_SECOND.PNG", index: 1),
            ],
            "Browser identities should be cached with the visible generation"
        )
        try expect(
            index.location(forItemIndex: 1)
                == .init(position: 0, groupIndex: 0, positionInGroup: 0),
            "group rebuild should refresh global and within-group positions"
        )

        index.rebuildGroups(
            for: items,
            sort: sort,
            isGroupingEnabled: false
        )
        try expect(
            index.visibleGroups.map(\.id) == [.ungrouped],
            "disabled grouping should use one stable ungrouped section"
        )

        let unusualDurations = [
            makeItem(id: "NAN.MOV", mediaKind: .video, duration: .nan),
            makeItem(id: "INFINITE.MOV", mediaKind: .video, duration: .infinity),
        ]
        let durationSort = PhotoSort(key: .duration, ascending: true)
        index.rebuildItems(unusualDurations, sort: durationSort)
        index.applyFilter(
            PhotoFilter(),
            to: unusualDurations,
            sort: durationSort,
            isGroupingEnabled: true
        )
        try expect(
            index.visibleGroups.count == 1,
            "non-finite durations should share one safe unknown group"
        )
    }

    private static func preparedSessionIndexScaleBaselines() throws {
        let clock = ContinuousClock()
        for itemCount in [1_000, 10_000, 100_000] {
            let items = (0..<itemCount).map { index in
                let ext = index.isMultiple(of: 2) ? "JPG" : "PNG"
                return makeItem(
                    id: String(format: "day-%02d/IMG_%06d.%@", index % 25, index, ext),
                    camera: "Camera \(index % 25)"
                )
            }
            let sort = PhotoSort(key: .camera, ascending: true)
            var filter = PhotoFilter()
            filter.excludedTypes = ["PNG"]
            var index = PreparedSessionIndex()
            var defaultIndex = PreparedSessionIndex()

            let rebuildDuration = clock.measure {
                index.rebuildItems(items, sort: sort)
            }
            let defaultRebuildDuration = clock.measure {
                defaultIndex.rebuildItems(items, sort: PhotoSort())
            }
            let filterDuration = clock.measure {
                index.applyFilter(
                    filter,
                    to: items,
                    sort: sort,
                    isGroupingEnabled: true
                )
            }

            try expect(
                index.visibleIndices.count == itemCount / 2,
                "\(itemCount)-item baseline should retain every JPEG"
            )
            try expect(
                index.visibleGroups.count == 25,
                "\(itemCount)-item baseline should create each camera group"
            )
            try expect(
                index.visibleLocations.count == itemCount / 2,
                "\(itemCount)-item baseline should map every visible item"
            )
            try expect(
                defaultIndex.sortedIndices == Array(items.indices),
                "\(itemCount)-item default order should reuse scanner order"
            )
            print(
                "Prepared index \(itemCount) items: "
                    + "rebuild \(milliseconds(rebuildDuration)) ms, "
                    + "default reuse \(milliseconds(defaultRebuildDuration)) ms, "
                    + "filter/group \(milliseconds(filterDuration)) ms"
            )
        }
    }

    /// Rating one photo is the culling hot path. Keep this separate from
    /// session preparation so a regression cannot hide behind scan/sort time.
    @MainActor
    private static func ratingMutationScaleBaseline() throws {
        let itemCount = 100_000
        let store = SessionStore()
        store.items = (0..<itemCount).map {
            makeItem(id: String(format: "RATING_%06d.JPG", $0))
        }

        let clock = ContinuousClock()
        var publishes = 0
        let subscription = store.objectWillChange.sink { _ in publishes += 1 }
        let duration = clock.measure {
            store.toggleRating(at: 0)
        }
        subscription.cancel()

        try expect(
            store.items[0].rating == .yes,
            "large-session rating should update the requested photo"
        )
        try expect(
            publishes <= 3,
            "one rating should publish once, not once per session item"
        )
        try expect(
            duration < .milliseconds(10),
            "rating one photo in a 100,000-item session should stay within 10 ms"
        )
        print(
            "Rating one of \(itemCount) items: "
                + "\(milliseconds(duration)) ms"
        )
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let components = duration.components
        let value = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return String(format: "%.1f", value)
    }

    private static func selectionStatePreservesImplicitCurrentAndToggleRules() throws {
        let items = [
            makeItem(id: "A.JPG"),
            makeItem(id: "B.JPG"),
            makeItem(id: "C.JPG"),
            makeItem(id: "D.JPG"),
        ]
        let visible = Array(items.indices)
        var selection = SelectionState()

        try expect(
            selection.effectiveSelection(
                currentIndex: 1,
                visibleIndices: visible,
                itemCount: items.count
            ) == [1],
            "empty explicit selection should mean the visible current item"
        )
        let firstReplacement = selection.toggle(
            3,
            currentIndex: 1,
            visibleIndices: visible,
            items: items
        )
        try expect(
            selection.indices == [1, 3] && firstReplacement == nil,
            "command-toggle should add a second item while keeping current"
        )
        try expect(
            selection.itemIDs == ["B.JPG", "D.JPG"],
            "selection should retain stable IDs beside render indices"
        )

        let replacement = selection.toggle(
            1,
            currentIndex: 1,
            visibleIndices: visible,
            items: items
        )
        try expect(
            selection.indices == [3] && replacement == 3,
            "removing current should move the anchor to the surviving item"
        )
        _ = selection.clear(items: items)
        try expect(
            selection.indices.isEmpty && selection.itemIDs.isEmpty,
            "clearing selection should clear both projections"
        )
        try expect(
            selection.effectiveSelection(
                currentIndex: 1,
                visibleIndices: [],
                itemCount: items.count
            ).isEmpty,
            "zero visible matches must not expose a hidden implicit selection"
        )
    }

    private static func selectionStateRangesFiltersAndRemapsByID() throws {
        let original = [
            makeItem(id: "A.JPG"),
            makeItem(id: "B.PNG"),
            makeItem(id: "C.JPG"),
            makeItem(id: "D.PNG"),
        ]
        let sort = PhotoSort(key: .name, ascending: true)
        var prepared = PreparedSessionIndex()
        prepared.rebuildItems(original, sort: sort)
        prepared.applyFilter(
            PhotoFilter(),
            to: original,
            sort: sort,
            isGroupingEnabled: true
        )
        var selection = SelectionState()
        _ = selection.selectRange(
            from: 1,
            to: 3,
            visibleIndices: prepared.visibleIndices,
            items: original,
            preparedIndex: prepared
        )
        try expect(
            selection.indices == [1, 2, 3],
            "range selection should follow prepared visible order"
        )

        var jpegOnly = PhotoFilter()
        jpegOnly.excludedTypes = ["PNG"]
        prepared.applyFilter(
            jpegOnly,
            to: original,
            sort: sort,
            isGroupingEnabled: true
        )
        _ = selection.retainVisible(
            items: original,
            preparedIndex: prepared
        )
        try expect(
            selection.indices == [2] && selection.itemIDs == ["C.JPG"],
            "filtering should remove hidden members from both projections"
        )

        let reordered = [
            makeItem(id: "D.PNG"),
            makeItem(id: "C.JPG"),
            makeItem(id: "B.PNG"),
            makeItem(id: "E.JPG"),
        ]
        prepared.rebuildItems(reordered, sort: sort)
        prepared.applyFilter(
            PhotoFilter(),
            to: reordered,
            sort: sort,
            isGroupingEnabled: true
        )
        let replacement = selection.restore(
            itemIDs: ["B.PNG", "C.JPG", "MISSING.JPG"],
            items: reordered,
            preparedIndex: prepared,
            visibleOnly: true,
            currentIndex: 3
        )
        try expect(
            selection.indices == [1, 2]
                && selection.itemIDs == ["B.PNG", "C.JPG"],
            "restore should remap surviving IDs into the new generation"
        )
        try expect(
            replacement == 2,
            "restore should choose the first selected item in visible order"
        )

        _ = selection.selectToEdge(
            from: 1,
            forward: true,
            visibleIndices: prepared.visibleIndices,
            items: reordered,
            preparedIndex: prepared
        )
        try expect(
            selection.itemIDs == ["C.JPG", "D.PNG", "E.JPG"],
            "edge selection should follow visible sort order, not array order"
        )
        _ = selection.updateRubberBand([0, 99], items: reordered)
        try expect(
            selection.indices == [0] && selection.itemIDs == ["D.PNG"],
            "rubber-band projection should discard stale item indices"
        )
        try expect(
            selection.committedAnchor(currentIndex: 3) == 0,
            "rubber-band completion should return a selected anchor"
        )
    }

    @MainActor
    private static func visibleLocationMapTracksDerivedState() throws {
        let store = SessionStore()
        store.items = (0..<5_000).map { index in
            let ext = index.isMultiple(of: 2) ? "JPG" : "PNG"
            return makeItem(id: String(format: "IMG_%05d.%@", index, ext))
        }
        store.sort = PhotoSort(key: .name, ascending: false)
        try expect(store.visibleIndices.count == 5_000, "navigation fixture should expose every item")

        let anchor = store.visibleIndices[3_210]
        store.setIndex(anchor)
        try expect(
            store.currentVisiblePosition == 3_210,
            "cached visible position should match reverse name order"
        )
        store.selectRange(to: store.visibleIndices[3_220])
        try expect(store.selectedIndices.count == 11, "range selection should use the cached endpoints")
        store.clearSelection()

        store.filter.excludedTypes = ["PNG"]
        let filteredPosition = store.visibleIndices.firstIndex(of: store.currentIndex)
        try expect(
            store.currentVisiblePosition == filteredPosition,
            "filter rebuild should refresh the cached position"
        )

        store.sort = PhotoSort(key: .fileType, ascending: true)
        let sortedPosition = store.visibleIndices.firstIndex(of: store.currentIndex)
        try expect(
            store.currentVisiblePosition == sortedPosition,
            "sort/group rebuild should refresh the cached position"
        )
        store.isGroupingEnabled = false
        try expect(
            store.currentVisiblePosition == sortedPosition,
            "turning group division off should preserve the global position"
        )
    }

    @MainActor
    private static func ratingUndoFollowsStableIdentityAfterReorder() throws {
        let store = SessionStore()
        store.items = [
            makeItem(id: "A.JPG"),
            makeItem(id: "B.JPG"),
            makeItem(id: "C.JPG"),
        ]
        store.sort = PhotoSort(key: .name, ascending: true)
        store.toggleRating(at: 1)
        try expect(
            store.items.first(where: { $0.id == "B.JPG" })?.rating == .yes,
            "fixture should rate B before reordering"
        )

        store.items = [store.items[2], store.items[0], store.items[1]]
        store.sort.ascending.toggle()
        store.undo()

        try expect(
            store.items.first(where: { $0.id == "B.JPG" })?.rating == .undecided,
            "rating undo should follow B's stable id after its array index changes"
        )
        try expect(
            store.items[store.currentIndex].id == "B.JPG",
            "rating undo should restore the former current photo by id"
        )
    }

    @MainActor
    private static func rescanPreservesCurrentPhotoAndSelectionByID() async throws {
        let folder = try disposableFolder(named: "StableRescanIdentity")
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixtureURL = URL(fileURLWithPath: "AppIcon/AppIcon.iconset/icon_16x16.png")
        let fixture = try Data(contentsOf: fixtureURL)
        let fm = FileManager.default
        let names = ["A.png", "B.png", "C.png"]
        for (offset, name) in names.enumerated() {
            let url = folder.appendingPathComponent(name)
            try fixture.write(to: url)
            try fm.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(100 + offset))],
                ofItemAtPath: url.path
            )
        }

        let store = SessionStore()
        store.openFolder(folder)
        try await waitForReadySession(store, expectedItems: 3)
        guard let a = store.items.firstIndex(where: { $0.id == "A.png" }),
              let b = store.items.firstIndex(where: { $0.id == "B.png" }) else {
            throw CheckFailure("initial scan should contain A and B")
        }
        store.setIndex(b)
        store.toggleSelection(of: a)
        let currentID = store.items[store.currentIndex].id
        let selectedIDs = Set(store.selectedIndices.map { store.items[$0].id })
        let previousIndex = store.currentIndex

        let newURL = folder.appendingPathComponent("D.png")
        try fixture.write(to: newURL)
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 50)],
            ofItemAtPath: newURL.path
        )
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 500)],
            ofItemAtPath: folder.appendingPathComponent("B.png").path
        )

        store.rescan()
        try await waitForReadySession(store, expectedItems: 4)
        let rescannedSelection = Set(
            store.selectedIndices.map { store.items[$0].id }
        )
        try expect(
            store.items[store.currentIndex].id == currentID,
            "rescan should preserve the current photo by stable id"
        )
        try expect(
            rescannedSelection == selectedIDs,
            "rescan should preserve the same selected photos by stable id"
        )
        try expect(
            store.currentIndex != previousIndex,
            "fixture should actually move the current photo to a new array index"
        )
        _ = await store.saveSessionForTermination()
    }

    @MainActor
    private static func pairingToggleStaysReadyAndPersistsIndividualRatings() async throws {
        let folder = try disposableFolder(named: "PairingRatings")
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixtureURL = URL(fileURLWithPath: "AppIcon/AppIcon.iconset/icon_16x16.png")
        let fixture = try Data(contentsOf: fixtureURL)
        try fixture.write(to: folder.appendingPathComponent("SHOT.NEF"))
        try fixture.write(to: folder.appendingPathComponent("SHOT.JPG"))
        let legacySession = SessionFile(
            version: 1,
            sourcePath: folder.path,
            scannedAt: Date(timeIntervalSince1970: 1),
            entries: [
                SessionEntry(
                    filename: "SHOT.NEF",
                    pairedFilename: "SHOT.JPG",
                    rating: Rating.yes.rawValue,
                    ratedAt: Date(timeIntervalSince1970: 1)
                )
            ]
        )
        try writeSessionFixture(
            legacySession,
            to: folder.appendingPathComponent(SessionConstants.sidecarName)
        )

        let store = SessionStore()
        store.openFolder(folder)
        try await waitForReadySession(store, expectedItems: 1)
        try expect(
            store.items[0].ratingSnapshots.allSatisfy { $0.rating == .yes },
            "schema 1 paired ratings should migrate onto both physical files"
        )

        store.setRawJPEGPairingMode(.separate)
        if case .ready = store.phase {
            // Expected: the existing session stays visible during enrichment.
        } else {
            throw CheckFailure("pairing toggle must not return to the scanning screen")
        }
        try expect(
            store.isChangingRawJPEGPairingMode,
            "first split should expose a non-blocking preparation state"
        )
        try await waitForPairingModeChange(store, expectedItems: 2)
        try expect(
            store.items.allSatisfy { $0.rating == .yes },
            "splitting a consistently rated pair should copy the decision to both files"
        )

        guard let jpegIndex = store.items.firstIndex(where: { $0.id == "SHOT.JPG" }) else {
            throw CheckFailure("separate projection should contain the JPEG")
        }
        store.toggleRating(at: jpegIndex)
        try expect(
            store.items[jpegIndex].rating == .no,
            "fixture should create a conflicting JPEG rating"
        )

        store.setRawJPEGPairingMode(.together)
        try await waitForPairingModeChange(store, expectedItems: 1)
        try expect(
            store.items[0].hasMixedRatings,
            "different RAW/JPEG decisions should display as Mixed"
        )
        store.cleanUpScope = .all
        try expect(
            !store.hasCleanUpTargets(for: .trashNo)
                && !store.hasCleanUpTargets(for: .keepOnlyYes),
            "rating-based Clean Up should protect an unresolved Mixed pair"
        )

        store.toggleRating(at: 0)
        try expect(
            store.items[0].ratingSnapshots.allSatisfy { $0.rating == .yes },
            "rating a Mixed pair should apply the new decision to both files"
        )
        store.undo()
        try expect(
            store.items[0].hasMixedRatings,
            "undo should restore both sides of the previous Mixed rating"
        )

        _ = await store.saveSessionForTermination()
        let loaded = await SessionPersistence().read(for: folder)
        let savedRatings = Dictionary(
            uniqueKeysWithValues: (loaded.session?.entries ?? []).map {
                ($0.filename, Rating(rawValue: $0.rating) ?? .undecided)
            }
        )
        try expect(
            loaded.session?.version == SessionConstants.currentSchemaVersion,
            "file-level ratings should be saved with sidecar schema 2"
        )
        try expect(
            savedRatings["SHOT.NEF"] == .yes && savedRatings["SHOT.JPG"] == .no,
            "schema 2 should persist both conflicting ratings independently"
        )

        let reopened = SessionStore()
        reopened.openFolder(folder)
        try await waitForReadySession(reopened, expectedItems: 1)
        try expect(
            reopened.items[0].hasMixedRatings,
            "reopening schema 2 should restore a Mixed pair without losing either rating"
        )
        reopened.setRawJPEGPairingMode(.separate)
        try await waitForPairingModeChange(reopened, expectedItems: 2)
        let restoredRatings = Dictionary(
            uniqueKeysWithValues: reopened.items.map { ($0.id, $0.rating) }
        )
        try expect(
            restoredRatings == ["SHOT.NEF": .yes, "SHOT.JPG": .no],
            "unpairing should restore the exact pre-grouping ratings"
        )
        _ = await reopened.saveSessionForTermination()
    }

    @MainActor
    private static func waitForReadySession(
        _ store: SessionStore,
        expectedItems: Int
    ) async throws {
        for _ in 0..<200 {
            if case .ready = store.phase, store.items.count == expectedItems {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw CheckFailure(
            "session did not finish scanning \(expectedItems) items"
        )
    }

    @MainActor
    private static func waitForPairingModeChange(
        _ store: SessionStore,
        expectedItems: Int
    ) async throws {
        for _ in 0..<200 {
            if !store.isChangingRawJPEGPairingMode,
               case .ready = store.phase,
               store.items.count == expectedItems {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw CheckFailure(
            "pairing mode did not finish projecting \(expectedItems) items"
        )
    }

    private static func expectValidationError(
        _ expected: ExportDestinationValidator.ValidationError,
        source: URL,
        destination: URL,
        item: PhotoItem
    ) throws {
        do {
            try ExportDestinationValidator.validate(
                sourceFolder: source,
                destination: destination,
                items: [item],
                mode: .copy
            )
            throw CheckFailure("unsafe export destination should have been rejected")
        } catch let error as ExportDestinationValidator.ValidationError {
            try expect(error == expected, "destination should fail with \(expected), got \(error)")
        }
    }

    /// Ratings use shared per-file storage rather than copying `items`, but a
    /// per-element publication storm would still freeze visible Browser rows.
    /// Clear All must publish once however many physical ratings it resets.
    @MainActor
    private static func clearAllRatingsPublishesOnceForLargeSessions() throws {
        let store = SessionStore()
        store.items = (0..<3000).map { i in
            let item = makeItem(id: String(format: "IMG_%04d.JPG", i))
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
            let item = makeItem(id: String(format: "IMG_%04d.JPG", i))
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
        try expect(store.exportWillStart(mode: .copy), "copy should raise the shared operation state")
        try expect(
            store.isCopyingExport && store.isFileOperationRunning,
            "copy should block Quit, updater installation, and session mutations"
        )
        try expect(
            !store.exportWillStart(mode: .move),
            "a second export must not overlap an active copy"
        )
        store.finishExport(mode: .copy, movedIDs: [], requiresRecovery: false)
        try expect(!store.isFileOperationRunning, "finishing copy should clear the shared operation state")

        try expect(store.exportWillStart(mode: .move), "move should raise the shared operation state")
        try expect(store.isMovingExport, "the in-flight flag should be up during the move")
        store.finishExport(
            mode: .move,
            movedIDs: movedIDs,
            requiresRecovery: false
        )

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

    private final class CancellationAfterChecks: @unchecked Sendable {
        private let lock = NSLock()
        private let threshold: Int
        private var checks = 0

        init(_ threshold: Int) {
            self.threshold = threshold
        }

        func shouldCancel() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            checks += 1
            return checks >= threshold
        }
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
        mediaKind: MediaKind = .photo,
        duration: TimeInterval? = nil,
        videoIsPlayable: Bool = false,
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
            mediaKind: mediaKind,
            duration: duration,
            videoIsPlayable: videoIsPlayable,
            primaryModificationDate: modificationDate,
            fileSize: fileSize,
            pairedFileSize: pairedFileSize
        )
    }

    private static func session(
        rating: String,
        folder: URL,
        scannedAt: Date = Date(timeIntervalSince1970: 0)
    ) -> SessionFile {
        SessionFile(
            version: 1,
            sourcePath: folder.path,
            scannedAt: scannedAt,
            entries: [SessionEntry(filename: "IMG.JPG", pairedFilename: nil, rating: rating, ratedAt: nil)]
        )
    }

    private static func writeSessionFixture(_ session: SessionFile, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: url, options: .atomic)
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
