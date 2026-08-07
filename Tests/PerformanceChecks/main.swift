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
        try await legacySidecarKeepsByteDistinctUnicodeEntries()
        try await persistenceReportsBackupAndTotalFailure()
        try exportCollisionSuffixSkipsTakenNames()
        try exportPairCollisionUsesSharedSuffix()
        try exportCopyCopiesEveryFileAndKeepsSources()
        try exportCopyPairRollsBackOnPartialFailure()
        try exportCopyCanCancelWithoutPartialPair()
        try exportMoveReportsFullyMovedPhotos()
        try exportMovePairRollsBackOnPartialFailure()
        try exportMoveRefusesInPlaceDestination()
        try exportMoveAtomicRenameNeverOverwritesRaceWinner()
        try exportDestinationRejectsSourceAndDescendant()
        try operationJournalPreservesInterruptedCopyIdempotently()
        try operationJournalPreservesCopyWhenSourceIsMissing()
        try operationJournalPreservesCopyWhenSourceIsReplaced()
        try operationJournalPreservesCopyWhenSourceIsRewrittenInPlace()
        try operationJournalRestoresInterruptedMove()
        try operationJournalPreservesMoveWhenSourceIsReplaced()
        try operationJournalRestoresMoveWithResolvedIdentity()
        try operationJournalCompletesRolledBackTransactions()
        try operationJournalPreservesCommittedExport()
        try operationJournalRefusesSameNamedReplacement()
        try operationJournalAcceptsInterruptedTrashCurrentState()
        try operationJournalLeavesTrashAndReplacementUntouched()
        try operationJournalCompletesInterruptedTrashUndo()
        try completedWorkerRemovesItsJournal()
        try scannerAndPreparedIndexShareDefaultOrder()
        try preparedSessionIndexKeepsStableGroupIdentity()
        try preparedSessionIndexScaleBaselines()
        try metadataFilterSortAndExportScaleBaseline()
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
            print("Performance checks passed (69/72; 3 real Trash checks explicitly skipped)")
        } else {
            try cleanUpPairRoundTripsThroughTrash()
            try cleanUpPairFailureRollsBackFirstFile()
            try cleanUpRollbackPreservesRacingSourceReplacement()
            print("Performance checks passed (72/72)")
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
            root.appendingPathComponent("JPEG/SHOT.JPG"),
            root.appendingPathComponent("UNPAIRED.DNG"),
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
        try expect(
            forward.contains {
                $0.primary.lastPathComponent == "SHOT.NEF"
                    && $0.paired?.lastPathComponent == "SHOT.JPG"
            },
            "one unambiguous RAW and JPEG should pair across subfolders"
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

        let otherFolder = folder
            .deletingLastPathComponent()
            .appendingPathComponent("Other-\(UUID().uuidString)")
        let sameRelativeIDElsewhere = makeItem(
            id: item.id,
            primaryURL: otherFolder.appendingPathComponent("CACHE.JPG"),
            modificationDate: modificationDate
        )
        try expect(
            ImagePipeline.cacheKey(for: sameRelativeIDElsewhere)
                != beforeRemoval,
            "equal relative names and timestamps in different folders must never share cached pixels"
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

        var missingEncodingContract = session(
            rating: Rating.yes.rawValue,
            folder: folder
        )
        missingEncodingContract.version =
            SessionConstants.currentSchemaVersion
        missingEncodingContract.fileIDEncoding = nil
        try writeSessionFixture(missingEncodingContract, to: sidecar)
        loaded = await persistence.read(for: folder)
        try expect(
            loaded.blockingMessage != nil,
            "schema 3 must require its byte-exact file-ID encoding contract"
        )

        var directUnicodeID = session(
            rating: Rating.yes.rawValue,
            folder: folder
        )
        directUnicodeID.version = SessionConstants.currentSchemaVersion
        directUnicodeID.fileIDEncoding = .percentEncodedFileSystemPath
        directUnicodeID.entries[0].filename = "café.NEF"
        try writeSessionFixture(directUnicodeID, to: sidecar)
        loaded = await persistence.read(for: folder)
        try expect(
            loaded.blockingMessage != nil,
            "schema 3 must reject non-ASCII IDs that bypass exact percent encoding"
        )

        var malformedEscape = directUnicodeID
        malformedEscape.entries[0].filename = "bad%GG.NEF"
        try writeSessionFixture(malformedEscape, to: sidecar)
        loaded = await persistence.read(for: folder)
        try expect(
            loaded.blockingMessage != nil,
            "schema 3 must reject malformed percent escapes"
        )

        var overlappingPhysicalIDs = directUnicodeID
        overlappingPhysicalIDs.entries = [
            SessionEntry(
                filename: "A.NEF",
                pairedFilename: "A.JPG",
                rating: Rating.yes.rawValue,
                ratedAt: nil
            ),
            SessionEntry(
                filename: "A.JPG",
                pairedFilename: nil,
                rating: Rating.no.rawValue,
                ratedAt: nil
            ),
        ]
        try writeSessionFixture(overlappingPhysicalIDs, to: sidecar)
        loaded = await persistence.read(for: folder)
        try expect(
            loaded.blockingMessage != nil,
            "one physical file must not receive conflicting primary and paired entries"
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

    private static func legacySidecarKeepsByteDistinctUnicodeEntries() async throws {
        let root = try disposableFolder(named: "PersistenceUnicodeIdentity")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Photos", isDirectory: true)
        let backup = root.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        let persistence = SessionPersistence(backupDirectory: backup)
        let composed = "caf\u{00E9}.NEF"
        let decomposed = "cafe\u{0301}.NEF"
        let fixture = SessionFile(
            version: 2,
            sourcePath: folder.path,
            scannedAt: Date(timeIntervalSince1970: 1_700_000_000),
            entries: [
                SessionEntry(
                    filename: composed,
                    pairedFilename: nil,
                    rating: Rating.yes.rawValue,
                    ratedAt: nil
                ),
                SessionEntry(
                    filename: decomposed,
                    pairedFilename: nil,
                    rating: Rating.no.rawValue,
                    ratedAt: nil
                ),
            ]
        )

        _ = await persistence.save(fixture, for: folder, sequence: 1)
        let loaded = await persistence.read(for: folder)
        guard let loadedSession = loaded.session else {
            throw CheckFailure(
                "a legacy sidecar with byte-distinct Unicode names should remain readable"
            )
        }
        let entries = loadedSession.entries
        var ratingsByUTF8: [Data: String] = [:]
        for entry in entries {
            ratingsByUTF8[Data(entry.filename.utf8)] = entry.rating
        }
        try expect(
            entries.count == 2 && ratingsByUTF8.count == 2,
            "legacy sidecar validation must not merge canonical-equivalent filenames"
        )
        try expect(
            ratingsByUTF8[Data(composed.utf8)] == Rating.yes.rawValue
                && ratingsByUTF8[Data(decomposed.utf8)] == Rating.no.rawValue,
            "byte-distinct legacy filenames must retain independent ratings"
        )

        let composedFile = PhotoFile(
            id: "caf%C3%A9.NEF",
            url: folder.appendingPathComponent("composed.NEF"),
            displayRelativePath: composed,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 1
        )
        let decomposedFile = PhotoFile(
            id: "cafe%CC%81.NEF",
            url: folder.appendingPathComponent("decomposed.NEF"),
            displayRelativePath: decomposed,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 1
        )
        let ratings = SessionRatingIndex(session: loadedSession)
        try expect(
            ratings.value(for: composedFile)?.rating == .yes
                && ratings.value(for: decomposedFile)?.rating == .no,
            "legacy rating application must preserve byte-distinct Unicode identities"
        )
    }

    private static func persistenceReportsBackupAndTotalFailure() async throws {
        let root = try disposableFolder(named: "PersistenceFailures")
        let sourceFolder = root.appendingPathComponent(
            "ReadOnlyPhotos",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sourceFolder,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: sourceFolder.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: sourceFolder.path
            )
            try? FileManager.default.removeItem(at: root)
        }

        let workingBackup = root.appendingPathComponent("Backup", isDirectory: true)
        let backupPersistence = SessionPersistence(backupDirectory: workingBackup)
        let backupResult = await backupPersistence.save(
            session(rating: Rating.yes.rawValue, folder: sourceFolder),
            for: sourceFolder,
            sequence: 1
        )
        guard case .savedToBackup = backupResult else {
            throw CheckFailure("a failed sidecar with a writable backup should report backup-only safety")
        }

        let blockedBackup = root.appendingPathComponent("BackupBlocker")
        try Data("file".utf8).write(to: blockedBackup)
        let failingPersistence = SessionPersistence(backupDirectory: blockedBackup)
        let failure = await failingPersistence.save(
            session(rating: Rating.no.rawValue, folder: sourceFolder),
            for: sourceFolder,
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
        // macOS attaches its provenance xattr shortly after these disposable
        // files are created. Let that system-only ctime change settle before
        // capturing the same scan-time identity a real folder scan would use.
        Thread.sleep(forTimeInterval: 0.25)
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
        let jpeg = folder.appendingPathComponent("PAIR.JPG")
        let displacedJPEG = folder.appendingPathComponent("PAIR.external.JPG")
        try Data("raw".utf8).write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)
        let item = makeItem(id: "PAIR.NEF", primaryURL: raw, pairedURL: jpeg)
        let journals = folder.appendingPathComponent("Journals", isDirectory: true)
        let displacer = ProgressFileDisplacer(
            from: jpeg,
            to: displacedJPEG
        )

        let result = CleanUpWorker.moveToTrash(
            [CleanUpPhotoSnapshot(index: 0, item: item)],
            journalDirectory: journals
        ) { done, _ in
            displacer.displaceAfterFirstProgress(done: done)
        }
        if let failure = displacer.failureDescription {
            throw CheckFailure(failure)
        }
        try expect(result.succeeded.isEmpty, "incomplete pair must not count as removed")
        try expect(result.failedPhotos == 1, "incomplete pair should report one failure")
        try expect(result.inconsistentPhotos == 0, "successful rollback should remain consistent")
        try expect(FileManager.default.fileExists(atPath: raw.path), "first file must roll back when its pair fails")
        try expect(
            FileManager.default.fileExists(atPath: displacedJPEG.path),
            "the injected second-file failure must occur after journal activation"
        )
    }

    private static func cleanUpRollbackPreservesRacingSourceReplacement() throws {
        let folder = try disposableFolder(named: "CleanUpRollbackReplacement")
        let raw = folder.appendingPathComponent("PAIR.NEF")
        let jpeg = folder.appendingPathComponent("PAIR.JPG")
        let later = folder.appendingPathComponent("LATER.JPG")
        let displacedJPEG = folder.appendingPathComponent("PAIR.external.JPG")
        let journals = folder.appendingPathComponent("Journals", isDirectory: true)
        let rawData = Data("original raw".utf8)
        let replacementData = Data("same-path replacement".utf8)
        try rawData.write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)
        try Data("later".utf8).write(to: later)
        let pair = makeItem(id: "PAIR.NEF", primaryURL: raw, pairedURL: jpeg)
        let laterItem = makeItem(id: "LATER.JPG", primaryURL: later)
        let race = CleanUpRollbackReplacementRace(
            pairedSource: jpeg,
            displacedPairedSource: displacedJPEG,
            replacementURL: raw,
            replacementData: replacementData
        )
        let resolvedRawTrashURL: () -> URL? = {
            let fm = FileManager.default
            guard let operation = try? fm.contentsOfDirectory(
                at: journals,
                includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension == "operation" }) else {
                return nil
            }
            let stateURL = operation
                .appendingPathComponent("steps", isDirectory: true)
                .appendingPathComponent("00000000.json")
            guard let data = try? Data(contentsOf: stateURL) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let state = try? decoder.decode(
                FileOperationJournal.StateRecord.self,
                from: data
            ),
            let path = state.resolvedDestinationPath else { return nil }
            return URL(fileURLWithPath: path)
        }
        defer {
            // Leave no test original behind in the real Trash even when an
            // assertion below throws before the explicit recovery step.
            if FileOperationJournal.hasPendingOperations(directory: journals) {
                if (try? Data(contentsOf: raw)) == replacementData {
                    try? FileManager.default.removeItem(at: raw)
                }
                if let trashedRaw = resolvedRawTrashURL(),
                   FileManager.default.fileExists(atPath: trashedRaw.path),
                   !FileManager.default.fileExists(atPath: raw.path) {
                    try? FileManager.default.moveItem(at: trashedRaw, to: raw)
                }
                if FileManager.default.fileExists(atPath: displacedJPEG.path),
                   !FileManager.default.fileExists(atPath: jpeg.path) {
                    try? FileManager.default.moveItem(
                        at: displacedJPEG,
                        to: jpeg
                    )
                }
                _ = FileOperationJournal.recoverPendingOperations(
                    directory: journals
                )
            }
            try? FileManager.default.removeItem(at: folder)
        }

        let result = CleanUpWorker.moveToTrash(
            [
                CleanUpPhotoSnapshot(index: 0, item: pair),
                CleanUpPhotoSnapshot(index: 1, item: laterItem),
            ],
            journalDirectory: journals
        ) { done, _ in
            race.injectAfterFirstProgress(done: done)
        }
        if let failure = race.failureDescription {
            throw CheckFailure(failure)
        }

        try expect(result.succeeded.isEmpty, "ambiguous rollback must not report a removed photo")
        try expect(result.failedPhotos == 2, "rollback ambiguity must stop before the later photo")
        try expect(result.inconsistentPhotos == 1, "same-path rollback collision must be explicit")
        try expect(result.requiresRecovery, "ambiguous rollback must keep its journal retryable")
        let survivingReplacement = try Data(contentsOf: raw)
        try expect(
            survivingReplacement == replacementData,
            "Clean Up rollback must leave a same-path replacement untouched"
        )
        try expect(
            FileManager.default.fileExists(atPath: later.path),
            "no later photo may be touched after rollback becomes ambiguous"
        )

        guard let trashedRaw = resolvedRawTrashURL() else {
            throw CheckFailure(
                "Clean Up journal did not retain the exact Trash location"
            )
        }
        // Restore the disposable fixture explicitly so the test never leaves a
        // file in the photographer's real Trash. Recovery itself now accepts
        // this current state without moving either file.
        try FileManager.default.removeItem(at: raw)
        try FileManager.default.moveItem(at: trashedRaw, to: raw)
        try FileManager.default.moveItem(at: displacedJPEG, to: jpeg)
        let recovery = FileOperationJournal.recoverPendingOperations(
            directory: journals
        )
        let recoveredOriginal = try Data(contentsOf: raw)
        try expect(
            recovery.unresolvedOperations == 1,
            "a paired Clean Up interrupted between files should retain an explicit decision"
        )
        try expect(
            recoveredOriginal == rawData,
            "Clean Up recovery must leave the explicitly restored original untouched"
        )
        let kept = FileOperationJournal
            .keepFilesAsTheyAreAndForgetPendingOperations(
                directory: journals
            )
        try expect(
            kept.unresolvedOperations == 0
                && !FileOperationJournal.hasPendingOperations(
                    directory: journals
                ),
            "Keep Files As They Are should retire only the paired Clean Up record"
        )
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
        let jpeg = source.appendingPathComponent("PAIR.JPG")
        let displacedJPEG = source.appendingPathComponent("PAIR.external.JPG")
        try Data("raw".utf8).write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)
        let item = makeItem(id: "PAIR.NEF", primaryURL: raw, pairedURL: jpeg)
        let displacer = ProgressFileDisplacer(
            from: jpeg,
            to: displacedJPEG
        )

        let result = ExportWorker.copy(
            [item],
            to: destination,
            journalDirectory: source.appendingPathComponent("Journals", isDirectory: true)
        ) { done, _ in
            displacer.displaceAfterFirstProgress(done: done)
        }
        if let failure = displacer.failureDescription {
            throw CheckFailure(failure)
        }
        try expect(result.copiedFiles == 0, "a failed pair must not count a partial copy")
        try expect(result.failedPhotos == 1, "a failed pair should report one failed photo")
        try expect(result.inconsistentPhotos == 0, "successful copy rollback should remain consistent")
        try expect(
            !FileManager.default.fileExists(atPath: destination.appendingPathComponent("PAIR.NEF").path),
            "the first copied member must be removed when its partner fails"
        )
        try expect(FileManager.default.fileExists(atPath: raw.path), "copy rollback must never touch the original")
        try expect(
            FileManager.default.fileExists(atPath: displacedJPEG.path),
            "the copy fixture must fail the second member after the first was copied"
        )
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
        let jpeg = source.appendingPathComponent("PAIR.JPG")
        let displacedJPEG = source.appendingPathComponent("PAIR.external.JPG")
        try Data("raw".utf8).write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)
        let item = makeItem(id: "PAIR.NEF", primaryURL: raw, pairedURL: jpeg)
        let displacer = ProgressFileDisplacer(
            from: jpeg,
            to: displacedJPEG
        )

        let result = ExportWorker.move(
            [item],
            to: destination,
            journalDirectory: source.appendingPathComponent("Journals", isDirectory: true)
        ) { done, _ in
            displacer.displaceAfterFirstProgress(done: done)
        }
        if let failure = displacer.failureDescription {
            throw CheckFailure(failure)
        }
        try expect(result.movedItemIDs.isEmpty, "an incomplete pair must not count as moved")
        try expect(result.failedPhotos == 1, "an incomplete pair should report one failed photo")
        try expect(result.inconsistentPhotos == 0, "a successful rollback should remain consistent")
        try expect(FileManager.default.fileExists(atPath: raw.path), "the first file must roll back when its pair fails")
        try expect(
            !FileManager.default.fileExists(atPath: destination.appendingPathComponent("PAIR.NEF").path),
            "no file of a failed pair may stay at the destination"
        )
        try expect(
            FileManager.default.fileExists(atPath: displacedJPEG.path),
            "the Move fixture must fail the second member after the first was moved"
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

    private static func exportMoveAtomicRenameNeverOverwritesRaceWinner() throws {
        let root = try disposableFolder(named: "ExportMoveRenameRace")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SOURCE.JPG")
        let destination = root.appendingPathComponent("DESTINATION.JPG")
        try Data("planned original".utf8).write(to: source)
        try Data("race winner".utf8).write(to: destination)

        do {
            try ExportWorker.atomicExclusiveRename(
                from: source,
                to: destination
            )
            throw CheckFailure(
                "exclusive Move rename must reject a late destination collision"
            )
        } catch let error as POSIXError {
            try expect(
                error.code == .EEXIST,
                "a late destination collision should fail with EEXIST"
            )
        }
        let sourceContents = try Data(contentsOf: source)
        let destinationContents = try Data(contentsOf: destination)
        try expect(
            sourceContents == Data("planned original".utf8),
            "the source must remain intact after a collision race"
        )
        try expect(
            destinationContents == Data("race winner".utf8),
            "Move must never overwrite a late destination"
        )
        try expect(
            !ExportWorker.restoreMovedFile(
                from: root.appendingPathComponent("MISSING.partial"),
                to: root.appendingPathComponent("ROLLBACK.JPG")
            ),
            "a touched Move file missing from its expected path must retain recovery state"
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

    private static func operationJournalPreservesInterruptedCopyIdempotently() throws {
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

        let blockedReport = FileOperationJournal.recoverPendingOperations(
            directory: journals
        )
        try expect(
            blockedReport.operationLockUnavailable,
            "a second process must not inspect an operation whose owner still holds the lock"
        )
        try expect(
            FileManager.default.fileExists(atPath: destination.path),
            "lock contention must leave the active operation's files untouched"
        )

        writer.relinquishOperationLockForCrashSimulation()
        do {
            _ = try FileOperationJournal.start(
                kind: .exportCopy,
                seeds: [
                    .init(
                        itemID: "SOURCE.JPG",
                        source: source,
                        destination: root.appendingPathComponent("SECOND.JPG")
                    ),
                ],
                directory: journals
            )
            throw CheckFailure(
                "a new operation must not start before stale-journal recovery"
            )
        } catch FileOperationJournal.JournalError.recoveryRequired {
            // Expected: the lock holder released on simulated process death,
            // but the durable transaction still owns the operation root.
        }
        let report = FileOperationJournal.recoverPendingOperations(directory: journals)
        try expect(report.restoredOperations == 1, "interrupted copy should recover as one operation")
        try expect(report.preservedCopies == 1, "recovery should preserve the completed destination copy")
        try expect(FileManager.default.fileExists(atPath: source.path), "copy recovery must preserve the original")
        try expect(FileManager.default.fileExists(atPath: destination.path), "copy recovery should keep its completed copy")
        try expect(!FileOperationJournal.hasPendingOperations(directory: journals), "resolved copy journal should be removed")

        let secondReport = FileOperationJournal.recoverPendingOperations(directory: journals)
        try expect(secondReport.foundOperations == 0, "repeating recovery should be a no-op")

        let inspectionBlocker = root.appendingPathComponent(
            "NotAnOperationDirectory"
        )
        try Data("not a directory".utf8).write(to: inspectionBlocker)
        try expect(
            FileOperationJournal.hasPendingOperations(
                directory: inspectionBlocker
            ),
            "an unreadable operation root must fail closed"
        )
        let blockedInspection =
            FileOperationJournal.recoverPendingOperations(
                directory: inspectionBlocker
            )
        try expect(
            blockedInspection.hasUnresolvedFiles,
            "operation-root inspection failure must require visible attention"
        )
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

        writer.relinquishOperationLockForCrashSimulation()
        let report = FileOperationJournal.recoverPendingOperations(directory: journals)
        try expect(report.restoredFiles == 1, "interrupted move should restore one source file")
        try expect(FileManager.default.fileExists(atPath: source.path), "move recovery should restore the original path")
        try expect(!FileManager.default.fileExists(atPath: destination.path), "move recovery should empty its destination")
    }

    private static func operationJournalPreservesCopyWhenSourceIsMissing() throws {
        let root = try disposableFolder(named: "JournalCopyMissingSource")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SOURCE.JPG")
        let destination = root.appendingPathComponent("COPIED.JPG")
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try Data("only surviving copy".utf8).write(to: source)

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
        try FileManager.default.removeItem(at: source)

        writer.relinquishOperationLockForCrashSimulation()
        let report = FileOperationJournal.recoverPendingOperations(directory: journals)
        let destinationContents = try Data(contentsOf: destination)
        try expect(report.unresolvedFiles == 0, "a completed Copy should not require its source during recovery")
        try expect(report.preservedCopies == 1, "the completed Copy should be preserved")
        try expect(
            destinationContents == Data("only surviving copy".utf8),
            "Copy recovery must preserve its destination when the original is missing"
        )
        try expect(
            !FileOperationJournal.hasPendingOperations(directory: journals),
            "a completed Copy should retire its journal even when the source is offline"
        )
    }

    private static func operationJournalPreservesCopyWhenSourceIsReplaced() throws {
        let root = try disposableFolder(named: "JournalCopyReplacedSource")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SOURCE.JPG")
        let destination = root.appendingPathComponent("COPIED.JPG")
        let replacement = root.appendingPathComponent("REPLACEMENT.JPG")
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try Data("original".utf8).write(to: source)
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
        try FileManager.default.removeItem(at: source)
        try FileManager.default.moveItem(at: replacement, to: source)

        writer.relinquishOperationLockForCrashSimulation()
        let report = FileOperationJournal.recoverPendingOperations(directory: journals)
        let sourceContents = try Data(contentsOf: source)
        let destinationContents = try Data(contentsOf: destination)
        try expect(report.unresolvedFiles == 0, "a completed Copy should not inspect a later source replacement")
        try expect(report.preservedCopies == 1, "the completed Copy should be preserved")
        try expect(
            sourceContents == Data("replacement".utf8),
            "Copy recovery must leave the replacement source untouched"
        )
        try expect(
            destinationContents == Data("original".utf8),
            "Copy recovery must preserve its copy when source identity changed"
        )
        try expect(
            !FileOperationJournal.hasPendingOperations(directory: journals),
            "a completed Copy should retire its journal without touching a replacement source"
        )
    }

    private static func operationJournalPreservesCopyWhenSourceIsRewrittenInPlace() throws {
        let root = try disposableFolder(named: "JournalCopyRewrittenSource")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SOURCE.JPG")
        let destination = root.appendingPathComponent("COPIED.JPG")
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try Data("original".utf8).write(to: source)

        let writer = try FileOperationJournal.start(
            kind: .exportCopy,
            seeds: [
                .init(
                    itemID: "SOURCE.JPG",
                    source: source,
                    destination: destination
                ),
            ],
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

        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 0)
        // Same byte count as "original": recovery must not rely on size.
        try handle.write(contentsOf: Data("mutation".utf8))
        try handle.close()

        writer.relinquishOperationLockForCrashSimulation()
        let report = FileOperationJournal.recoverPendingOperations(
            directory: journals
        )
        let rewrittenSourceContents = try Data(contentsOf: source)
        let intactCopyContents = try Data(contentsOf: destination)
        try expect(
            report.unresolvedFiles == 0,
            "a completed Copy should not inspect a later in-place source rewrite"
        )
        try expect(report.preservedCopies == 1, "the completed Copy should be preserved")
        try expect(
            rewrittenSourceContents == Data("mutation".utf8),
            "Copy recovery must preserve the rewritten source"
        )
        try expect(
            intactCopyContents == Data("original".utf8),
            "Copy recovery must preserve its intact copy after a source rewrite"
        )
        try expect(
            !FileOperationJournal.hasPendingOperations(directory: journals),
            "a completed Copy should retire its journal without touching a rewritten source"
        )
    }

    private static func operationJournalPreservesMoveWhenSourceIsReplaced() throws {
        let root = try disposableFolder(named: "JournalMoveReplacedSource")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SOURCE.NEF")
        let destination = root.appendingPathComponent("MOVED.NEF")
        let replacement = root.appendingPathComponent("REPLACEMENT.NEF")
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try Data("original raw".utf8).write(to: source)
        try Data("replacement raw".utf8).write(to: replacement)

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
        try FileManager.default.moveItem(at: temporary, to: destination)
        try writer.mark(.completed, fileAt: 0, identityAt: destination)
        try FileManager.default.moveItem(at: replacement, to: source)

        writer.relinquishOperationLockForCrashSimulation()
        let report = FileOperationJournal.recoverPendingOperations(directory: journals)
        let sourceContents = try Data(contentsOf: source)
        let destinationContents = try Data(contentsOf: destination)
        try expect(report.unresolvedFiles == 1, "a replaced Move source should remain unresolved")
        try expect(
            sourceContents == Data("replacement raw".utf8),
            "Move recovery must leave the replacement source untouched"
        )
        try expect(
            destinationContents == Data("original raw".utf8),
            "Move recovery must never delete the actual original after a source replacement"
        )
        try expect(
            FileOperationJournal.hasPendingOperations(directory: journals),
            "a replaced Move source must preserve its retryable journal"
        )
    }

    private static func operationJournalRestoresMoveWithResolvedIdentity() throws {
        let root = try disposableFolder(named: "JournalMoveResolvedIdentity")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SOURCE.NEF")
        let destination = root.appendingPathComponent("MOVED.NEF")
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try Data("cross-volume raw".utf8).write(to: source)

        let writer = try FileOperationJournal.start(
            kind: .exportMove,
            seeds: [.init(itemID: "SOURCE.NEF", source: source, destination: destination)],
            directory: journals
        )
        guard let temporary = writer.temporaryURL(at: 0) else {
            throw CheckFailure("move journal should reserve a temporary path")
        }
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
        try writer.mark(.started, fileAt: 0)
        // A copy plus source removal deterministically simulates the new inode
        // produced by FileManager's cross-volume move implementation.
        try FileManager.default.copyItem(at: source, to: temporary)
        let stagedAttributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        try expect(
            (originalAttributes[.systemFileNumber] as? NSNumber)
                != (stagedAttributes[.systemFileNumber] as? NSNumber),
            "the cross-volume fixture must produce a distinct file identity"
        )
        try writer.mark(.staged, fileAt: 0, identityAt: temporary)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.moveItem(at: temporary, to: destination)

        writer.relinquishOperationLockForCrashSimulation()
        let report = FileOperationJournal.recoverPendingOperations(directory: journals)
        let restoredContents = try Data(contentsOf: source)
        try expect(report.restoredFiles == 1, "resolved Move identity should restore one source")
        try expect(
            restoredContents == Data("cross-volume raw".utf8),
            "Move recovery should restore the checkpointed cross-volume file"
        )
        try expect(
            !FileManager.default.fileExists(atPath: destination.path),
            "resolved Move recovery should empty its destination"
        )
        try expect(
            !FileOperationJournal.hasPendingOperations(directory: journals),
            "a restored cross-volume Move journal should be removed"
        )
    }

    private static func operationJournalCompletesRolledBackTransactions() throws {
        let root = try disposableFolder(named: "JournalRolledBack")
        defer { try? FileManager.default.removeItem(at: root) }
        let journals = root.appendingPathComponent("Journals", isDirectory: true)

        let movedSource = root.appendingPathComponent("MOVE.NEF")
        let movedDestination = root.appendingPathComponent("MOVED.NEF")
        try Data("move contents".utf8).write(to: movedSource)
        let moveWriter = try FileOperationJournal.start(
            kind: .exportMove,
            seeds: [
                .init(
                    itemID: "MOVE.NEF",
                    source: movedSource,
                    destination: movedDestination
                ),
            ],
            directory: journals
        )
        guard let temporary = moveWriter.temporaryURL(at: 0) else {
            throw CheckFailure("Move rollback journal should reserve a temporary path")
        }
        try moveWriter.mark(.started, fileAt: 0)
        try FileManager.default.moveItem(at: movedSource, to: temporary)
        try moveWriter.mark(.staged, fileAt: 0, identityAt: temporary)
        try FileManager.default.moveItem(at: temporary, to: movedSource)
        try moveWriter.mark(.rolledBack, fileAt: 0)
        moveWriter.relinquishOperationLockForCrashSimulation()

        var report = FileOperationJournal.recoverPendingOperations(
            directory: journals
        )
        try expect(
            report.restoredOperations == 1 && report.unresolvedFiles == 0,
            "a completed Move rollback must not become a false unresolved recovery"
        )
        try expect(
            FileManager.default.fileExists(atPath: movedSource.path)
                && !FileManager.default.fileExists(atPath: movedDestination.path),
            "Move rollback recovery must preserve the restored original"
        )

        let preCheckpointMoveSource = root.appendingPathComponent(
            "MOVE-PRE-CHECKPOINT.NEF"
        )
        let preCheckpointMoveDestination = root.appendingPathComponent(
            "MOVED-PRE-CHECKPOINT.NEF"
        )
        try Data("pre-checkpoint move".utf8).write(
            to: preCheckpointMoveSource
        )
        let preCheckpointMoveWriter = try FileOperationJournal.start(
            kind: .exportMove,
            seeds: [
                .init(
                    itemID: "MOVE-PRE-CHECKPOINT.NEF",
                    source: preCheckpointMoveSource,
                    destination: preCheckpointMoveDestination
                ),
            ],
            directory: journals
        )
        guard let preCheckpointTemporary =
                preCheckpointMoveWriter.temporaryURL(at: 0) else {
            throw CheckFailure(
                "pre-checkpoint Move journal should reserve a temporary path"
            )
        }
        try preCheckpointMoveWriter.mark(.started, fileAt: 0)
        try FileManager.default.moveItem(
            at: preCheckpointMoveSource,
            to: preCheckpointTemporary
        )
        try preCheckpointMoveWriter.mark(
            .staged,
            fileAt: 0,
            identityAt: preCheckpointTemporary
        )
        try FileManager.default.moveItem(
            at: preCheckpointTemporary,
            to: preCheckpointMoveSource
        )
        // Simulate process death after the rollback itself but before the
        // `.rolledBack` checkpoint can be written.
        preCheckpointMoveWriter.relinquishOperationLockForCrashSimulation()

        report = FileOperationJournal.recoverPendingOperations(
            directory: journals
        )
        try expect(
            report.restoredOperations == 1 && report.unresolvedFiles == 0,
            "Move recovery must recognize a rollback completed before its checkpoint"
        )
        let preCheckpointMoveContents = try Data(
            contentsOf: preCheckpointMoveSource
        )
        try expect(
            preCheckpointMoveContents == Data("pre-checkpoint move".utf8),
            "pre-checkpoint Move rollback must preserve the original"
        )

        let trashedSource = root.appendingPathComponent("TRASH.JPG")
        let simulatedTrash = root.appendingPathComponent("TRASHED.JPG")
        try Data("trash contents".utf8).write(to: trashedSource)
        let trashWriter = try FileOperationJournal.start(
            kind: .moveToTrash,
            seeds: [
                .init(
                    itemID: "TRASH.JPG",
                    source: trashedSource,
                    destination: nil
                ),
            ],
            directory: journals
        )
        try trashWriter.mark(.started, fileAt: 0)
        try FileManager.default.moveItem(at: trashedSource, to: simulatedTrash)
        try trashWriter.mark(
            .completed,
            fileAt: 0,
            resolvedDestination: simulatedTrash,
            identityAt: simulatedTrash
        )
        try FileManager.default.moveItem(at: simulatedTrash, to: trashedSource)
        try trashWriter.mark(.rolledBack, fileAt: 0)
        trashWriter.relinquishOperationLockForCrashSimulation()

        report = FileOperationJournal.recoverPendingOperations(
            directory: journals
        )
        try expect(
            report.restoredOperations == 1 && report.unresolvedFiles == 0,
            "a completed Trash rollback must not become a false unresolved recovery"
        )
        try expect(
            FileManager.default.fileExists(atPath: trashedSource.path)
                && !FileManager.default.fileExists(atPath: simulatedTrash.path),
            "Trash rollback recovery must preserve the restored original"
        )

        let preCheckpointTrashSource = root.appendingPathComponent(
            "TRASH-PRE-CHECKPOINT.JPG"
        )
        let preCheckpointTrashDestination = root.appendingPathComponent(
            "TRASHED-PRE-CHECKPOINT.JPG"
        )
        try Data("pre-checkpoint trash".utf8).write(
            to: preCheckpointTrashSource
        )
        let preCheckpointTrashWriter = try FileOperationJournal.start(
            kind: .moveToTrash,
            seeds: [
                .init(
                    itemID: "TRASH-PRE-CHECKPOINT.JPG",
                    source: preCheckpointTrashSource,
                    destination: nil
                ),
            ],
            directory: journals
        )
        try preCheckpointTrashWriter.mark(.started, fileAt: 0)
        try FileManager.default.moveItem(
            at: preCheckpointTrashSource,
            to: preCheckpointTrashDestination
        )
        try preCheckpointTrashWriter.mark(
            .completed,
            fileAt: 0,
            resolvedDestination: preCheckpointTrashDestination,
            identityAt: preCheckpointTrashDestination
        )
        try FileManager.default.moveItem(
            at: preCheckpointTrashDestination,
            to: preCheckpointTrashSource
        )
        // Same crash window as Move: filesystem rollback succeeded, checkpoint
        // did not.
        preCheckpointTrashWriter
            .relinquishOperationLockForCrashSimulation()

        report = FileOperationJournal.recoverPendingOperations(
            directory: journals
        )
        try expect(
            report.restoredOperations == 1 && report.unresolvedFiles == 0,
            "Trash recovery must recognize a rollback completed before its checkpoint"
        )
        let preCheckpointTrashContents = try Data(
            contentsOf: preCheckpointTrashSource
        )
        try expect(
            preCheckpointTrashContents == Data("pre-checkpoint trash".utf8),
            "pre-checkpoint Trash rollback must preserve the original"
        )
        try expect(
            !FileOperationJournal.hasPendingOperations(directory: journals),
            "successfully rolled-back transactions should leave no recovery journal"
        )
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

        writer.relinquishOperationLockForCrashSimulation()
        let report = FileOperationJournal.recoverPendingOperations(directory: journals)
        try expect(report.committedOperations == 1, "committed operation should only clear its stale journal")
        try expect(FileManager.default.fileExists(atPath: destination.path), "committed destination must be preserved")
        try expect(FileManager.default.fileExists(atPath: source.path), "committed copy must preserve its source")

        let secondSource = root.appendingPathComponent("SECOND.JPG")
        let secondDestination = root.appendingPathComponent("SECOND-COPY.JPG")
        try Data("second source".utf8).write(to: secondSource)
        let tamperedWriter = try FileOperationJournal.start(
            kind: .exportCopy,
            seeds: [
                .init(
                    itemID: "SECOND.JPG",
                    source: secondSource,
                    destination: secondDestination
                ),
            ],
            directory: journals
        )
        guard let secondTemporary = tamperedWriter.temporaryURL(at: 0) else {
            throw CheckFailure("second copy journal should reserve a temporary path")
        }
        try tamperedWriter.mark(.started, fileAt: 0)
        try FileManager.default.copyItem(
            at: secondSource,
            to: secondTemporary
        )
        try tamperedWriter.mark(
            .staged,
            fileAt: 0,
            identityAt: secondTemporary
        )
        try FileManager.default.moveItem(
            at: secondTemporary,
            to: secondDestination
        )
        try tamperedWriter.mark(
            .completed,
            fileAt: 0,
            identityAt: secondDestination
        )
        try tamperedWriter.markCommitted()
        try Data("tampered".utf8).write(
            to: tamperedWriter.token.directory
                .appendingPathComponent("committed"),
            options: .atomic
        )
        tamperedWriter.relinquishOperationLockForCrashSimulation()

        let tamperedReport =
            FileOperationJournal.recoverPendingOperations(
                directory: journals
            )
        try expect(
            tamperedReport.hasUnresolvedFiles,
            "a malformed commit marker must never authorize journal removal"
        )
        try expect(
            FileManager.default.fileExists(atPath: secondSource.path)
                && FileManager.default.fileExists(
                    atPath: secondDestination.path
                ),
            "invalid commit metadata must leave both source and copy untouched"
        )
        try expect(
            FileOperationJournal.hasPendingOperations(directory: journals),
            "a malformed commit marker must remain retryable"
        )

        let legacyRoot = try disposableFolder(named: "JournalLegacyCommit")
        defer { try? FileManager.default.removeItem(at: legacyRoot) }
        let legacySource = legacyRoot.appendingPathComponent("SOURCE.JPG")
        let legacyDestination = legacyRoot.appendingPathComponent("COPY.JPG")
        let legacyJournals = legacyRoot.appendingPathComponent(
            "Journals",
            isDirectory: true
        )
        try Data("legacy committed source".utf8).write(to: legacySource)
        let legacyWriter = try FileOperationJournal.start(
            kind: .exportCopy,
            seeds: [
                .init(
                    itemID: "SOURCE.JPG",
                    source: legacySource,
                    destination: legacyDestination
                ),
            ],
            directory: legacyJournals
        )
        guard let legacyTemporary = legacyWriter.temporaryURL(at: 0) else {
            throw CheckFailure(
                "legacy commit journal should reserve a temporary path"
            )
        }
        try legacyWriter.mark(.started, fileAt: 0)
        try FileManager.default.copyItem(
            at: legacySource,
            to: legacyTemporary
        )
        try legacyWriter.mark(
            .staged,
            fileAt: 0,
            identityAt: legacyTemporary
        )
        try FileManager.default.moveItem(
            at: legacyTemporary,
            to: legacyDestination
        )
        try legacyWriter.mark(
            .completed,
            fileAt: 0,
            identityAt: legacyDestination
        )
        let legacyPlan = FileOperationJournal.Plan(
            version: 1,
            operationID: legacyWriter.plan.operationID,
            kind: legacyWriter.plan.kind,
            createdAt: legacyWriter.plan.createdAt,
            files: legacyWriter.plan.files
        )
        let legacyPlanEncoder = JSONEncoder()
        legacyPlanEncoder.dateEncodingStrategy = .iso8601
        legacyPlanEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encodedLegacyPlan = try legacyPlanEncoder.encode(legacyPlan)
        guard var legacyObject = try JSONSerialization.jsonObject(
            with: encodedLegacyPlan
        ) as? [String: Any],
        var legacyFiles = legacyObject["files"] as? [[String: Any]],
        var legacyIdentity = legacyFiles.first?["identity"]
            as? [String: Any] else {
            throw CheckFailure("could not construct authentic legacy plan JSON")
        }
        // These keys did not exist in the original version-1 journal schema.
        legacyIdentity.removeValue(forKey: "logicalSize")
        legacyIdentity.removeValue(forKey: "modificationTime")
        legacyIdentity.removeValue(forKey: "statusChangeTime")
        legacyIdentity.removeValue(forKey: "birthTime")
        legacyFiles[0]["identity"] = legacyIdentity
        legacyObject["files"] = legacyFiles
        let authenticLegacyPlanData = try JSONSerialization.data(
            withJSONObject: legacyObject,
            options: [.sortedKeys]
        )
        try authenticLegacyPlanData.write(
            to: legacyWriter.token.directory.appendingPathComponent(
                "plan.json"
            ),
            options: .atomic
        )
        try Data("committed\n".utf8).write(
            to: legacyWriter.token.directory.appendingPathComponent(
                "committed"
            ),
            options: .atomic
        )
        legacyWriter.relinquishOperationLockForCrashSimulation()

        let legacyReport =
            FileOperationJournal.recoverPendingOperations(
                directory: legacyJournals
            )
        try expect(
            legacyReport.committedOperations == 1
                && !legacyReport.hasUnresolvedFiles,
            "an exact version-1 commit marker must remain recoverable after update"
        )
        let legacySourceContents = try Data(contentsOf: legacySource)
        let legacyDestinationContents = try Data(
            contentsOf: legacyDestination
        )
        try expect(
            legacySourceContents == Data("legacy committed source".utf8)
                && legacyDestinationContents
                    == Data("legacy committed source".utf8),
            "legacy committed recovery must preserve both the source and completed copy"
        )
        try expect(
            !FileOperationJournal.hasPendingOperations(
                directory: legacyJournals
            ),
            "a valid legacy committed journal should be cleared"
        )

        let emptyLegacyID = UUID().uuidString.lowercased()
        let emptyLegacyDirectory = legacyJournals.appendingPathComponent(
            "\(emptyLegacyID).operation",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: emptyLegacyDirectory.appendingPathComponent(
                "steps",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        let emptyLegacyPlan = FileOperationJournal.Plan(
            version: 1,
            operationID: emptyLegacyID,
            kind: .exportCopy,
            createdAt: Date(timeIntervalSince1970: 1),
            files: []
        )
        try legacyPlanEncoder.encode(emptyLegacyPlan).write(
            to: emptyLegacyDirectory.appendingPathComponent("plan.json"),
            options: .atomic
        )
        try Data("committed\n".utf8).write(
            to: emptyLegacyDirectory.appendingPathComponent("committed"),
            options: .atomic
        )
        let emptyLegacyReport =
            FileOperationJournal.recoverPendingOperations(
                directory: legacyJournals
            )
        try expect(
            emptyLegacyReport.committedOperations == 1
                && !emptyLegacyReport.hasUnresolvedFiles,
            "an old committed empty operation must not block the upgraded app"
        )

        let collisionRoot = try disposableFolder(named: "JournalPathCollision")
        defer { try? FileManager.default.removeItem(at: collisionRoot) }
        let collisionSource = collisionRoot.appendingPathComponent("SOURCE.JPG")
        let collisionJournals = collisionRoot.appendingPathComponent(
            "Journals",
            isDirectory: true
        )
        try Data("irreplaceable original".utf8).write(to: collisionSource)
        let hardLinkedSource = collisionRoot.appendingPathComponent(
            "HARD-LINKED-SOURCE.JPG"
        )
        try FileManager.default.linkItem(
            at: collisionSource,
            to: hardLinkedSource
        )

        do {
            _ = try FileOperationJournal.start(
                kind: .exportCopy,
                seeds: [
                    .init(
                        itemID: "SOURCE.JPG",
                        source: collisionSource,
                        destination: hardLinkedSource
                    ),
                ],
                directory: collisionJournals
            )
            throw CheckFailure(
                "an owned path hard-linked to its source must be rejected"
            )
        } catch FileOperationJournal.JournalError.unsafePlan {
            // Expected.
        }

        let hardLinkWriter = try FileOperationJournal.start(
            kind: .exportCopy,
            seeds: [
                .init(
                    itemID: "SOURCE.JPG",
                    source: collisionSource,
                    destination: collisionRoot.appendingPathComponent(
                        "SOURCE-COPY.JPG"
                    )
                ),
                .init(
                    itemID: "HARD-LINKED-SOURCE.JPG",
                    source: hardLinkedSource,
                    destination: collisionRoot.appendingPathComponent(
                        "HARD-LINK-COPY.JPG"
                    )
                ),
            ],
            directory: collisionJournals
        )
        hardLinkWriter.relinquishOperationLockForCrashSimulation()
        let hardLinkReport =
            FileOperationJournal.recoverPendingOperations(
                directory: collisionJournals
            )
        try expect(
            hardLinkReport.restoredOperations == 1
                && !hardLinkReport.hasUnresolvedFiles,
            "distinct hard-linked source paths must remain valid operation inputs"
        )
        try expect(
            FileManager.default.fileExists(atPath: collisionSource.path)
                && FileManager.default.fileExists(
                    atPath: hardLinkedSource.path
                ),
            "valid hard-linked sources must remain untouched during no-op recovery"
        )

        let hardLinkedPair = makeItem(
            id: "SOURCE.JPG",
            primaryURL: collisionSource,
            pairedURL: hardLinkedSource,
            pairedFileSize: 1
        )
        let hardLinkCopyDestination = collisionRoot.appendingPathComponent(
            "HardLinkCopies",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: hardLinkCopyDestination,
            withIntermediateDirectories: true
        )
        let hardLinkCopyResult = ExportWorker.copy(
            [hardLinkedPair],
            to: hardLinkCopyDestination,
            journalDirectory: collisionJournals
        ) { _, _ in }
        try expect(
            hardLinkCopyResult.copiedFiles == 2
                && hardLinkCopyResult.failedPhotos == 0
                && !hardLinkCopyResult.journalFailure,
            "Copy must support distinct hard-linked source names"
        )
        try expect(
            FileManager.default.fileExists(
                atPath: hardLinkCopyDestination
                    .appendingPathComponent(collisionSource.lastPathComponent)
                    .path
            )
                && FileManager.default.fileExists(
                    atPath: hardLinkCopyDestination
                        .appendingPathComponent(
                            hardLinkedSource.lastPathComponent
                        )
                        .path
                ),
            "Copy must create both requested hard-link-name outputs"
        )

        let hardLinkMoveDestination = collisionRoot.appendingPathComponent(
            "HardLinkMoves",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: hardLinkMoveDestination,
            withIntermediateDirectories: true
        )
        let hardLinkMoveResult = ExportWorker.move(
            [hardLinkedPair],
            to: hardLinkMoveDestination,
            journalDirectory: collisionJournals
        ) { _, _ in }
        try expect(
            hardLinkMoveResult.movedFiles == 0
                && hardLinkMoveResult.failedPhotos == 1
                && hardLinkMoveResult.journalFailure
                && !hardLinkMoveResult.requiresRecovery,
            "Move must reject hard-linked source names before touching either"
        )
        try expect(
            FileManager.default.fileExists(atPath: collisionSource.path)
                && FileManager.default.fileExists(
                    atPath: hardLinkedSource.path
                ),
            "rejected hard-linked Move must preserve both source names"
        )

        let hardLinkTrashResult = CleanUpWorker.moveToTrash(
            [CleanUpPhotoSnapshot(index: 0, item: hardLinkedPair)],
            journalDirectory: collisionJournals
        ) { _, _ in }
        try expect(
            hardLinkTrashResult.succeeded.isEmpty
                && hardLinkTrashResult.failedPhotos == 1
                && hardLinkTrashResult.journalFailure
                && !hardLinkTrashResult.requiresRecovery,
            "Clean Up must reject hard-linked source names before Trash"
        )
        try expect(
            FileManager.default.fileExists(atPath: collisionSource.path)
                && FileManager.default.fileExists(
                    atPath: hardLinkedSource.path
                ),
            "rejected hard-linked Clean Up must preserve both source names"
        )

        let simulatedTrash = collisionRoot.appendingPathComponent(
            "SimulatedTrash",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: simulatedTrash,
            withIntermediateDirectories: true
        )
        let trashedPrimary = simulatedTrash.appendingPathComponent(
            "RESTORE-A.JPG"
        )
        let trashedPartner = simulatedTrash.appendingPathComponent(
            "RESTORE-B.JPG"
        )
        try Data("trashed hard link".utf8).write(to: trashedPrimary)
        try FileManager.default.linkItem(
            at: trashedPrimary,
            to: trashedPartner
        )
        let restorePrimary = collisionRoot.appendingPathComponent(
            "RESTORE-A.JPG"
        )
        let restorePartner = collisionRoot.appendingPathComponent(
            "RESTORE-B.JPG"
        )
        let restorePair = makeItem(
            id: "RESTORE-A.JPG",
            primaryURL: restorePrimary,
            pairedURL: restorePartner,
            pairedFileSize: 1
        )
        let hardLinkRestoreResult = CleanUpWorker.restore(
            [
                TrashedPhotoSnapshot(
                    index: 0,
                    item: restorePair,
                    files: [
                        TrashedFile(
                            original: restorePrimary,
                            trash: trashedPrimary
                        ),
                        TrashedFile(
                            original: restorePartner,
                            trash: trashedPartner
                        ),
                    ]
                ),
            ],
            journalDirectory: collisionJournals
        ) { _, _ in }
        try expect(
            hardLinkRestoreResult.restored.isEmpty
                && hardLinkRestoreResult.lostPhotos == 1
                && hardLinkRestoreResult.journalFailure
                && !hardLinkRestoreResult.requiresRecovery,
            "Trash undo must reject hard-linked entries before moving either"
        )
        try expect(
            FileManager.default.fileExists(atPath: trashedPrimary.path)
                && FileManager.default.fileExists(atPath: trashedPartner.path)
                && !FileManager.default.fileExists(atPath: restorePrimary.path)
                && !FileManager.default.fileExists(atPath: restorePartner.path),
            "rejected hard-linked Trash undo must preserve both Trash names"
        )

        let aliasedParent = collisionRoot.appendingPathComponent(
            "ALIASED-PARENT",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: aliasedParent,
            withDestinationURL: collisionRoot
        )
        do {
            _ = try FileOperationJournal.start(
                kind: .exportCopy,
                seeds: [
                    .init(
                        itemID: "SOURCE.JPG",
                        source: collisionSource,
                        destination: aliasedParent.appendingPathComponent(
                            collisionSource.lastPathComponent
                        )
                    ),
                ],
                directory: collisionJournals
            )
            throw CheckFailure(
                "a symlink-resolved destination alias must be rejected"
            )
        } catch FileOperationJournal.JournalError.unsafePlan {
            // Expected.
        }

        let secondCollisionSource = collisionRoot.appendingPathComponent(
            "SECOND-SOURCE.JPG"
        )
        try Data("second original".utf8).write(to: secondCollisionSource)
        do {
            _ = try FileOperationJournal.start(
                kind: .exportCopy,
                seeds: [
                    .init(
                        itemID: "SOURCE.JPG",
                        source: collisionSource,
                        destination: collisionRoot.appendingPathComponent(
                            "FIRST-COPY.JPG"
                        )
                    ),
                    .init(
                        itemID: "SECOND-SOURCE.JPG",
                        source: secondCollisionSource,
                        destination: collisionSource
                    ),
                ],
                directory: collisionJournals
            )
            throw CheckFailure(
                "one file's owned path must not alias another file's source"
            )
        } catch FileOperationJournal.JournalError.unsafePlan {
            // Expected.
        }

        do {
            _ = try FileOperationJournal.start(
                kind: .exportCopy,
                seeds: [
                    .init(
                        itemID: "SOURCE.JPG",
                        source: collisionSource,
                        destination: collisionSource
                    ),
                ],
                directory: collisionJournals
            )
            throw CheckFailure(
                "journal activation must reject a destination aliasing its source"
            )
        } catch FileOperationJournal.JournalError.unsafePlan {
            // Expected.
        }
        do {
            _ = try FileOperationJournal.start(
                kind: .exportCopy,
                seeds: [
                    .init(
                        itemID: "SOURCE.JPG",
                        source: collisionSource,
                        destination: collisionJournals
                            .appendingPathComponent("OWNED.JPG")
                    ),
                ],
                directory: collisionJournals
            )
            throw CheckFailure(
                "journal activation must reject paths inside journal storage"
            )
        } catch FileOperationJournal.JournalError.unsafePlan {
            // Expected.
        }

        let safeDestination = collisionRoot.appendingPathComponent("SAFE.JPG")
        let collisionWriter = try FileOperationJournal.start(
            kind: .exportCopy,
            seeds: [
                .init(
                    itemID: "SOURCE.JPG",
                    source: collisionSource,
                    destination: safeDestination
                ),
            ],
            directory: collisionJournals
        )
        try collisionWriter.mark(
            .completed,
            fileAt: 0,
            identityAt: collisionSource
        )
        let originalFile = collisionWriter.plan.files[0]
        let collidingTemporary = collisionSource
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".louppe-\(collisionWriter.plan.operationID)-0.partial"
            )
            .standardizedFileURL.path
        let collidingPlan = FileOperationJournal.Plan(
            version: collisionWriter.plan.version,
            operationID: collisionWriter.plan.operationID,
            kind: collisionWriter.plan.kind,
            createdAt: collisionWriter.plan.createdAt,
            files: [
                FileOperationJournal.PlannedFile(
                    itemID: originalFile.itemID,
                    sourcePath: originalFile.sourcePath,
                    destinationPath: originalFile.sourcePath,
                    temporaryPath: collidingTemporary,
                    identity: originalFile.identity
                )
            ]
        )
        let collisionEncoder = JSONEncoder()
        collisionEncoder.dateEncodingStrategy = .iso8601
        collisionEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try collisionEncoder.encode(collidingPlan).write(
            to: collisionWriter.token.directory.appendingPathComponent(
                "plan.json"
            ),
            options: .atomic
        )
        collisionWriter.relinquishOperationLockForCrashSimulation()

        let collisionReport =
            FileOperationJournal.recoverPendingOperations(
                directory: collisionJournals
            )
        try expect(
            collisionReport.hasUnresolvedFiles,
            "a source/owned-path collision must fail closed during recovery"
        )
        let collisionSourceContents = try Data(contentsOf: collisionSource)
        try expect(
            collisionSourceContents == Data("irreplaceable original".utf8),
            "malformed Copy recovery must never remove the planned original"
        )
        try expect(
            FileOperationJournal.hasPendingOperations(
                directory: collisionJournals
            ),
            "a malformed colliding plan must remain available for diagnosis"
        )
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

        writer.relinquishOperationLockForCrashSimulation()
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

    private static func operationJournalAcceptsInterruptedTrashCurrentState() throws {
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

        writer.relinquishOperationLockForCrashSimulation()
        let report = FileOperationJournal.recoverPendingOperations(directory: journals)
        try expect(
            report.restoredOperations == 1
                && report.restoredFiles == 0
                && report.unresolvedFiles == 0,
            "interrupted Clean Up should accept its current filesystem state"
        )
        try expect(
            !FileManager.default.fileExists(atPath: source.path),
            "Clean Up recovery must not restore the original path"
        )
        try expect(
            FileManager.default.fileExists(atPath: simulatedTrash.path),
            "Clean Up recovery must leave the trashed file untouched"
        )
        try expect(
            !FileOperationJournal.hasPendingOperations(directory: journals),
            "accepted Clean Up recovery should retire its journal"
        )
    }

    private static func operationJournalLeavesTrashAndReplacementUntouched() throws {
        let root = try disposableFolder(named: "JournalTrashReplacedSource")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SOURCE.JPG")
        let simulatedTrash = root.appendingPathComponent("TRASHED.JPG")
        let replacement = root.appendingPathComponent("REPLACEMENT.JPG")
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try Data("original".utf8).write(to: source)
        try Data("replacement".utf8).write(to: replacement)

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
        try FileManager.default.moveItem(at: replacement, to: source)

        writer.relinquishOperationLockForCrashSimulation()
        let report = FileOperationJournal.recoverPendingOperations(directory: journals)
        let sourceContents = try Data(contentsOf: source)
        let trashContents = try Data(contentsOf: simulatedTrash)
        try expect(
            report.restoredOperations == 1
                && report.restoredFiles == 0
                && report.unresolvedFiles == 0,
            "Clean Up recovery should accept replacement and Trash locations without mutation"
        )
        try expect(
            sourceContents == Data("replacement".utf8),
            "Trash recovery must leave the replacement source untouched"
        )
        try expect(
            trashContents == Data("original".utf8),
            "Trash recovery must preserve the actual original at its resolved location"
        )
        try expect(
            !FileOperationJournal.hasPendingOperations(directory: journals),
            "accepted Clean Up recovery should retire its journal"
        )
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

        writer.relinquishOperationLockForCrashSimulation()
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

    private static func metadataFilterSortAndExportScaleBaseline() throws {
        let itemCount = 100_000
        let stars = StarRating.allCases
        let colors = PhotoColorLabel.allCases
        let items = (0..<itemCount).map { index in
            makeItem(
                id: String(format: "METADATA_%06d.JPG", index),
                rating: index.isMultiple(of: 3) ? .yes
                    : (index % 3 == 1 ? .no : .undecided),
                stars: index.isMultiple(of: 6) ? nil : stars[index % stars.count],
                color: index.isMultiple(of: 6) ? nil : colors[index % colors.count]
            )
        }
        let clock = ContinuousClock()

        var filter = PhotoFilter()
        filter.excludedDecisionStates = [.no]
        filter.excludedStarStates = [.unrated]
        filter.excludedColorStates = [.none]
        let preparedFilter = PreparedPhotoFilter(filter)
        let filterDuration = clock.measure {
            _ = items.count(where: preparedFilter.matches)
        }

        let sort = PhotoSort(key: .starRating, ascending: false)
        var preparedIndex = PreparedSessionIndex()
        let sortDuration = clock.measure {
            preparedIndex.rebuildItems(items, sort: sort)
        }
        let sortedStates = preparedIndex.sortedIndices.map {
            items[$0].starRatingState
        }
        let firstSpecial = sortedStates.firstIndex {
            $0 == .unrated || $0 == .mixed
        } ?? sortedStates.endIndex
        try expect(
            !sortedStates[..<firstSpecial].contains(.unrated),
            "metadata sort should keep Unrated after every rated value"
        )

        let predicate = ExportSelectionPredicate(
            decisions: [.yes],
            starStates: [.stars(.three)],
            colorStates: [.label(.green)]
        )
        var snapshot = ExportSelectionSnapshot.empty
        let exportDuration = clock.measure {
            snapshot = ExportSelectionSnapshot(items: items, predicate: predicate)
        }
        try expect(
            snapshot.itemIndices.allSatisfy { predicate.matches(items[$0]) },
            "prepared Export snapshot should contain only the AND intersection"
        )
        try expect(
            snapshot.physicalFileCount == snapshot.itemCount,
            "single-file scale fixtures should retain exact physical counts"
        )
        print(
            "Metadata index \(itemCount) items: "
                + "filter \(milliseconds(filterDuration)) ms, "
                + "sort \(milliseconds(sortDuration)) ms, "
                + "export selection \(milliseconds(exportDuration)) ms"
        )
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
            !store.isLegacySessionMigrationConfirmationPresented,
            "an all-present filename-only session should migrate without an unnecessary prompt"
        )
        try expect(
            store.items[0].ratingSnapshots.allSatisfy { $0.rating == .yes },
            "schema 1 paired ratings should survive automatic migration"
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
            loaded.session?.version == SessionConstants.currentSchemaVersion
                && loaded.session?.fileIDEncoding
                    == .percentEncodedFileSystemPath,
            "file-level ratings should use the current exact-ID and physical-identity contract"
        )
        try expect(
            savedRatings["SHOT.NEF"] == .yes && savedRatings["SHOT.JPG"] == .no,
            "the current schema should persist both conflicting ratings independently"
        )

        let reopened = SessionStore()
        reopened.openFolder(folder)
        try await waitForReadySession(reopened, expectedItems: 1)
        try expect(
            reopened.items[0].hasMixedRatings,
            "reopening the current schema should restore a Mixed pair without losing either rating"
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

        let moveAllStore = SessionStore()
        moveAllStore.items = [
            makeItem(id: "ONLY.JPG"),
        ]
        moveAllStore.sort.ascending = false
        try expect(
            moveAllStore.exportWillStart(mode: .move),
            "move-all should raise the shared operation state"
        )
        moveAllStore.finishExport(
            mode: .move,
            movedIDs: ["ONLY.JPG"],
            requiresRecovery: false
        )
        try expect(
            moveAllStore.items.isEmpty
                && moveAllStore.emptySessionReason == .movedOut
                && !moveAllStore.canUndo,
            "an empty session after Move must not claim the files are in Trash or undoable"
        )
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

    /// Introduces a deterministic second-member failure only after a worker's
    /// first progress checkpoint. Unlike a missing source at setup time, this
    /// proves the journal activated and the first pair member reached the
    /// filesystem before rollback was exercised.
    private final class ProgressFileDisplacer: @unchecked Sendable {
        private let lock = NSLock()
        private let source: URL
        private let destination: URL
        private var attempted = false
        private var storedFailureDescription: String?

        init(from source: URL, to destination: URL) {
            self.source = source
            self.destination = destination
        }

        func displaceAfterFirstProgress(done: Int) {
            guard done == 1 else { return }
            lock.lock()
            defer { lock.unlock() }
            guard !attempted else { return }
            attempted = true
            do {
                try FileManager.default.moveItem(
                    at: source,
                    to: destination
                )
            } catch {
                storedFailureDescription =
                    "could not inject the second-file failure: "
                    + error.localizedDescription
            }
        }

        var failureDescription: String? {
            lock.lock()
            defer { lock.unlock() }
            return storedFailureDescription
        }
    }

    /// Creates the exact rollback race Clean Up must treat conservatively:
    /// after the first pair member reaches Trash, another file occupies its
    /// original path while the second member disappears from its scanned path.
    private final class CleanUpRollbackReplacementRace: @unchecked Sendable {
        private let lock = NSLock()
        private let pairedSource: URL
        private let displacedPairedSource: URL
        private let replacementURL: URL
        private let replacementData: Data
        private var attempted = false
        private var storedFailureDescription: String?

        init(
            pairedSource: URL,
            displacedPairedSource: URL,
            replacementURL: URL,
            replacementData: Data
        ) {
            self.pairedSource = pairedSource
            self.displacedPairedSource = displacedPairedSource
            self.replacementURL = replacementURL
            self.replacementData = replacementData
        }

        func injectAfterFirstProgress(done: Int) {
            guard done == 1 else { return }
            lock.lock()
            defer { lock.unlock() }
            guard !attempted else { return }
            attempted = true
            do {
                try FileManager.default.moveItem(
                    at: pairedSource,
                    to: displacedPairedSource
                )
                try replacementData.write(
                    to: replacementURL,
                    options: .withoutOverwriting
                )
            } catch {
                storedFailureDescription =
                    "could not inject Clean Up rollback replacement: "
                    + error.localizedDescription
            }
        }

        var failureDescription: String? {
            lock.lock()
            defer { lock.unlock() }
            return storedFailureDescription
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
        pairedFileSize: Int64 = 0,
        rating: Rating = .undecided,
        stars: StarRating? = nil,
        color: PhotoColorLabel? = nil
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
            pairedFileSize: pairedFileSize,
            rating: rating,
            starRating: stars,
            colorLabel: color
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
