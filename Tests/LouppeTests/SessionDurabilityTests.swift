import Foundation
import XCTest
@testable import Louppe

@MainActor
final class SessionDurabilityTests: XCTestCase {
    func testContinuousRatingsReachMaximumAgeCheckpoint() async throws {
        let fixture = try makeFixture(named: "MaximumDirtyAge")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let store = SessionStore(
            persistence: SessionPersistence(
                backupDirectory: fixture.backup
            ),
            // Keep the trailing save far outside the test window so only the
            // fixed maximum-age checkpoint can make this assertion pass.
            saveTrailingDelay: 5,
            saveMaximumDelay: 0.15
        )
        store.openFolder(fixture.photos)
        try await waitForReadySession(store)
        _ = try await waitForSidecar(in: fixture.photos) {
            $0.entries.first?.rating == Rating.undecided.rawValue
        }

        // Every mutation lands well inside the five-second trailing debounce.
        // Alternate decisions so every iteration is a real state change.
        var checkpointReachedDuringContinuousInput = false
        for iteration in 0..<30 {
            store.rate(iteration.isMultiple(of: 2) ? .yes : .no, at: 0)
            try await Task.sleep(nanoseconds: 25_000_000)
            do {
                if let session = try readSidecar(in: fixture.photos),
                   session.entries.first?.rating != Rating.undecided.rawValue {
                    checkpointReachedDuringContinuousInput = true
                }
            } catch {
                // The sidecar is atomically replaced. A retry on the next
                // iteration keeps the timing assertion independent of a
                // transient read racing that replacement.
            }
        }

        XCTAssertTrue(
            checkpointReachedDuringContinuousInput,
            "continuous culling must not postpone persistence indefinitely"
        )
        _ = await store.saveSessionForTermination()
    }

    func testSameFolderOpenPersistsPendingRatingBeforeRescan() async throws {
        let fixture = try makeFixture(named: "SameFolderOpen")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // Long delays make this specifically exercise the folder-transition
        // barrier rather than the normal scheduled save.
        let store = SessionStore(
            persistence: SessionPersistence(
                backupDirectory: fixture.backup
            ),
            saveTrailingDelay: 10,
            saveMaximumDelay: 20
        )
        store.openFolder(fixture.photos)
        try await waitForReadySession(store)
        _ = try await waitForSidecar(in: fixture.photos) {
            $0.entries.first?.rating == Rating.undecided.rawValue
        }

        store.rate(.yes, at: 0)
        try Data(
            contentsOf: fixture.photos.appendingPathComponent("A.png")
        ).write(to: fixture.photos.appendingPathComponent("B.png"))
        store.openFolder(fixture.photos)

        try await waitForReadySession(
            store,
            expectedItems: 2,
            requiresTransitionToFinish: true
        )
        XCTAssertEqual(
            store.items.first(where: { $0.id == "A.png" })?.rating,
            .yes,
            "reopening the current folder must not reload an older sidecar"
        )
        _ = try await waitForSidecar(in: fixture.photos) { session in
            session.entries.contains {
                $0.filename == "A.png"
                    && $0.rating == Rating.yes.rawValue
            }
        }
        _ = await store.saveSessionForTermination()
    }

    func testTerminationPreparationBlocksLateRatingMutations() async throws {
        let fixture = try makeFixture(named: "TerminationBarrier")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let store = SessionStore(
            persistence: SessionPersistence(
                backupDirectory: fixture.backup
            )
        )
        store.openFolder(fixture.photos)
        try await waitForReadySession(store)

        store.beginTerminationPreparation()
        store.rate(.yes, at: 0)
        XCTAssertEqual(
            store.items.first?.rating,
            .undecided,
            "the final-save window must reject ratings arriving after its snapshot boundary"
        )

        store.cancelTerminationPreparation()
        store.rate(.yes, at: 0)
        XCTAssertEqual(store.items.first?.rating, .yes)
        _ = await store.saveSessionForTermination()
    }

    func testFinalSaveConsumesDeferredCheckpointWithoutStartingAThirdWrite() async throws {
        let fixture = try makeFixture(named: "SaveCoalescing")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let persistence = GatedSessionPersistence()
        let store = SessionStore(
            persistence: persistence,
            saveTrailingDelay: 5,
            saveMaximumDelay: 0.05
        )
        store.openFolder(fixture.photos)
        try await waitForReadySession(store)
        try await waitForSaveCalls(1, in: persistence)

        // The scan's first snapshot is deliberately held in flight. The
        // maximum-age timer must coalesce the rating behind it.
        store.rate(.yes, at: 0)
        try await waitForDeferredSave(in: store)

        store.beginTerminationPreparation()
        let finalSave = Task { @MainActor in
            await store.saveSessionForTermination()
        }
        try await waitForSaveCalls(2, in: persistence)

        await persistence.releaseAllSaves()
        let result = await finalSave.value
        XCTAssertEqual(result, .savedToSidecar)

        // Completion observers run separately from the awaiting Quit task.
        // Wait on the store's exact bookkeeping instead of guessing how many
        // scheduler turns they need.
        let reachedIdle = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(
            reachedIdle,
            "the explicit final save must leave persistence bookkeeping idle"
        )
        let saveCallCount = await persistence.saveCallCount()
        XCTAssertEqual(
            saveCallCount,
            2,
            "the explicit final snapshot must consume the already-satisfied deferred save"
        )
    }

    func testDeferredCheckpointAutomaticallyFlushesLatestSnapshot() async throws {
        let fixture = try makeFixture(named: "AutomaticSaveCoalescing")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let persistence = GatedSessionPersistence()
        let store = SessionStore(
            persistence: persistence,
            saveTrailingDelay: 5,
            saveMaximumDelay: 0.05
        )
        store.openFolder(fixture.photos)
        try await waitForReadySession(store)
        try await waitForSaveCalls(1, in: persistence)

        store.rate(.yes, at: 0)
        try await waitForDeferredSave(in: store)
        await persistence.releaseNextSave()

        try await waitForSaveCalls(2, in: persistence)
        let deferredRating = await persistence.capturedRating(forCall: 1)
        XCTAssertEqual(
            deferredRating,
            Rating.yes.rawValue,
            "finishing slow storage must automatically capture the newest live rating"
        )

        await persistence.releaseAllSaves()
        let reachedIdle = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(
            reachedIdle,
            "the automatically coalesced save must finish within the test timeout"
        )
        let finalSaveCallCount = await persistence.saveCallCount()
        XCTAssertEqual(
            finalSaveCallCount,
            2,
            "one deferred marker must coalesce to exactly one fresh snapshot"
        )
    }

    func testInvalidCurrentSnapshotCannotReplaceValidSidecar() async throws {
        let fixture = try makeFixture(named: "InvalidWriteContract")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let persistence = SessionPersistence(backupDirectory: fixture.backup)
        let valid = SessionFile(
            version: SessionConstants.currentSchemaVersion,
            sourcePath: fixture.photos.path,
            scannedAt: Date(timeIntervalSince1970: 1),
            entries: [
                SessionEntry(
                    filename: "A.png",
                    pairedFilename: nil,
                    rating: Rating.yes.rawValue,
                    ratedAt: nil,
                    fileIdentity: try FileOperationJournal.captureIdentity(
                        at: fixture.photos.appendingPathComponent("A.png")
                    )
                )
            ],
            fileIDEncoding: .percentEncodedFileSystemPath
        )
        let validSaveResult = await persistence.save(
            valid,
            for: fixture.photos,
            sequence: 1
        )
        XCTAssertEqual(
            validSaveResult,
            .savedToSidecar
        )

        let sidecar = fixture.photos.appendingPathComponent(
            SessionConstants.sidecarName
        )
        let lastKnownGood = try Data(contentsOf: sidecar)
        let backupFiles = try FileManager.default.contentsOfDirectory(
            at: fixture.backup,
            includingPropertiesForKeys: nil
        )
        let backupFile = try XCTUnwrap(backupFiles.first)
        XCTAssertEqual(backupFiles.count, 1)
        let lastKnownGoodBackup = try Data(contentsOf: backupFile)
        var invalid = valid
        invalid.scannedAt = Date(timeIntervalSince1970: 2)
        invalid.entries[0].rating = Rating.no.rawValue
        invalid.fileIDEncoding = nil

        let invalidSaveResult = await persistence.save(
            invalid,
            for: fixture.photos,
            sequence: 2
        )
        XCTAssertEqual(
            invalidSaveResult,
            .rejectedInvalidSnapshot
        )
        XCTAssertEqual(
            try Data(contentsOf: sidecar),
            lastKnownGood,
            "a rejected snapshot must not touch the existing sidecar"
        )
        XCTAssertEqual(
            try Data(contentsOf: backupFile),
            lastKnownGoodBackup,
            "a rejected snapshot must not touch the last-known-good backup"
        )

        let loaded = await persistence.read(for: fixture.photos)
        XCTAssertEqual(loaded.session?.entries.first?.rating, Rating.yes.rawValue)
        XCTAssertNil(loaded.blockingMessage)
    }

    func testSchemaFourPairedEntryCannotReplaceValidSidecar() async throws {
        let fixture = try makeFixture(named: "InvalidPairedWriteContract")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let persistence = SessionPersistence(backupDirectory: fixture.backup)
        let identity = try FileOperationJournal.captureIdentity(
            at: fixture.photos.appendingPathComponent("A.png")
        )
        let valid = SessionFile(
            version: SessionConstants.currentSchemaVersion,
            sourcePath: fixture.photos.path,
            scannedAt: Date(timeIntervalSince1970: 1),
            entries: [
                SessionEntry(
                    filename: "A.png",
                    pairedFilename: nil,
                    rating: Rating.yes.rawValue,
                    ratedAt: nil,
                    fileIdentity: identity
                )
            ],
            fileIDEncoding: .percentEncodedFileSystemPath
        )
        let validResult = await persistence.save(
            valid,
            for: fixture.photos,
            sequence: 1
        )
        XCTAssertEqual(validResult, .savedToSidecar)
        let sidecar = fixture.photos.appendingPathComponent(
            SessionConstants.sidecarName
        )
        let lastKnownGood = try Data(contentsOf: sidecar)

        var invalid = valid
        invalid.scannedAt = Date(timeIntervalSince1970: 2)
        invalid.entries[0].pairedFilename = "A.JPG"
        let invalidResult = await persistence.save(
            invalid,
            for: fixture.photos,
            sequence: 2
        )
        XCTAssertEqual(invalidResult, .rejectedInvalidSnapshot)
        XCTAssertEqual(try Data(contentsOf: sidecar), lastKnownGood)
    }

    func testSamePathReplacementBlocksScanWithoutRewritingSavedRatings() async throws {
        let fixture = try makeFixture(named: "ReplacementConflict")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let persistence = SessionPersistence(backupDirectory: fixture.backup)
        let source = fixture.photos.appendingPathComponent("A.png")
        let saved = SessionFile(
            version: SessionConstants.currentSchemaVersion,
            sourcePath: fixture.photos.path,
            scannedAt: Date(timeIntervalSince1970: 1),
            entries: [
                SessionEntry(
                    filename: "A.png",
                    pairedFilename: nil,
                    rating: Rating.yes.rawValue,
                    ratedAt: Date(timeIntervalSince1970: 1),
                    fileIdentity: try FileOperationJournal.captureIdentity(
                        at: source
                    )
                )
            ],
            fileIDEncoding: .percentEncodedFileSystemPath
        )
        let savedResult = await persistence.save(
            saved,
            for: fixture.photos,
            sequence: 1
        )
        XCTAssertEqual(savedResult, .savedToSidecar)
        let sidecar = fixture.photos.appendingPathComponent(
            SessionConstants.sidecarName
        )
        let savedSidecar = try Data(contentsOf: sidecar)
        let backupFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.backup,
                includingPropertiesForKeys: nil
            ).first
        )
        let savedBackup = try Data(contentsOf: backupFile)

        try FileManager.default.moveItem(
            at: source,
            to: fixture.root.appendingPathComponent("Original.png")
        )
        let replacementFixture = URL(
            fileURLWithPath: "AppIcon/AppIcon.iconset/icon_32x32.png"
        )
        try Data(contentsOf: replacementFixture).write(to: source)

        let store = SessionStore(persistence: persistence)
        store.openFolder(fixture.photos)
        try await waitForIdentityConflict(in: store)

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(
            store.scanError?.contains("not the same physical file") == true
        )
        XCTAssertEqual(try Data(contentsOf: sidecar), savedSidecar)
        XCTAssertEqual(try Data(contentsOf: backupFile), savedBackup)
    }

    func testMissingPhysicalFileRatingSurvivesAutosaveAndReturns() async throws {
        let fixture = try makeFixture(named: "MissingFileRetention")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let persistence = SessionPersistence(backupDirectory: fixture.backup)
        let a = fixture.photos.appendingPathComponent("A.png")
        let b = fixture.photos.appendingPathComponent("B.png")
        try Data(contentsOf: a).write(to: b)
        let saved = SessionFile(
            version: SessionConstants.currentSchemaVersion,
            sourcePath: fixture.photos.path,
            scannedAt: Date(timeIntervalSince1970: 1),
            entries: [
                SessionEntry(
                    filename: "A.png",
                    pairedFilename: nil,
                    rating: Rating.undecided.rawValue,
                    ratedAt: nil,
                    fileIdentity: try FileOperationJournal.captureIdentity(at: a)
                ),
                SessionEntry(
                    filename: "B.png",
                    pairedFilename: nil,
                    rating: Rating.yes.rawValue,
                    ratedAt: Date(timeIntervalSince1970: 1),
                    fileIdentity: try FileOperationJournal.captureIdentity(at: b)
                ),
            ],
            fileIDEncoding: .percentEncodedFileSystemPath
        )
        let initialSave = await persistence.save(
            saved,
            for: fixture.photos,
            sequence: 1
        )
        XCTAssertEqual(initialSave, .savedToSidecar)
        let temporarilyAway = fixture.root.appendingPathComponent("B-away.png")
        try FileManager.default.moveItem(at: b, to: temporarilyAway)

        let store = SessionStore(persistence: persistence)
        store.openFolder(fixture.photos)
        try await waitForReadySession(store, expectedItems: 1)
        _ = await store.saveSessionForTermination()
        let retained = try await waitForSidecar(in: fixture.photos) { session in
            session.entries.contains {
                $0.filename == "B.png"
                    && $0.rating == Rating.yes.rawValue
                    && $0.fileIdentity != nil
            }
        }
        XCTAssertEqual(retained.entries.count, 2)

        try FileManager.default.moveItem(at: temporarilyAway, to: b)
        store.rescan()
        try await waitForReadySession(
            store,
            expectedItems: 2,
            requiresTransitionToFinish: true
        )
        XCTAssertEqual(
            store.items.first(where: { $0.id == "B.png" })?.rating,
            .yes,
            "the exact returning physical file must recover its retained decision"
        )
        _ = await store.saveSessionForTermination()
    }

    func testVerifiedPhysicalRenameCarriesRatingToNewFileID() async throws {
        let fixture = try makeFixture(named: "PhysicalRename")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let persistence = SessionPersistence(backupDirectory: fixture.backup)
        let original = fixture.photos.appendingPathComponent("A.png")
        let saved = SessionFile(
            version: SessionConstants.currentSchemaVersion,
            sourcePath: fixture.photos.path,
            scannedAt: Date(timeIntervalSince1970: 1),
            entries: [
                SessionEntry(
                    filename: "A.png",
                    pairedFilename: nil,
                    rating: Rating.yes.rawValue,
                    ratedAt: Date(timeIntervalSince1970: 1),
                    fileIdentity: try FileOperationJournal.captureIdentity(
                        at: original
                    )
                ),
            ],
            fileIDEncoding: .percentEncodedFileSystemPath
        )
        let initialSave = await persistence.save(
            saved,
            for: fixture.photos,
            sequence: 1
        )
        XCTAssertEqual(initialSave, .savedToSidecar)
        let renamed = fixture.photos.appendingPathComponent("Renamed.png")
        try FileManager.default.moveItem(at: original, to: renamed)

        let store = SessionStore(persistence: persistence)
        store.openFolder(fixture.photos)
        try await waitForReadySession(store)
        XCTAssertNil(store.scanError)
        XCTAssertEqual(store.items.first?.id, "Renamed.png")
        XCTAssertEqual(store.items.first?.rating, .yes)
        _ = await store.saveSessionForTermination()

        let migrated = try await waitForSidecar(in: fixture.photos) { session in
            session.entries.count == 1
                && session.entries.first?.filename == "Renamed.png"
                && session.entries.first?.rating == Rating.yes.rawValue
        }
        XCTAssertFalse(migrated.entries.contains { $0.filename == "A.png" })
    }

    func testVerifiedFolderRenameKeepsRatingsAndUpdatesSourcePath() async throws {
        let fixture = try makeFixture(named: "FolderRename")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let persistence = SessionPersistence(backupDirectory: fixture.backup)
        let source = fixture.photos.appendingPathComponent("A.png")
        let saved = SessionFile(
            version: SessionConstants.currentSchemaVersion,
            sourcePath: fixture.photos.path,
            scannedAt: Date(timeIntervalSince1970: 1),
            entries: [
                SessionEntry(
                    filename: "A.png",
                    pairedFilename: nil,
                    rating: Rating.yes.rawValue,
                    ratedAt: Date(timeIntervalSince1970: 1),
                    fileIdentity: try FileOperationJournal.captureIdentity(
                        at: source
                    )
                ),
            ],
            fileIDEncoding: .percentEncodedFileSystemPath
        )
        let initialSave = await persistence.save(
            saved,
            for: fixture.photos,
            sequence: 1
        )
        XCTAssertEqual(initialSave, .savedToSidecar)
        let renamedFolder = fixture.root.appendingPathComponent(
            "Renamed Photos",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: fixture.photos,
            to: renamedFolder
        )

        let store = SessionStore(persistence: persistence)
        store.openFolder(renamedFolder)
        try await waitForReadySession(store)
        XCTAssertEqual(store.items.first?.rating, .yes)
        XCTAssertNil(store.scanError)
        _ = await store.saveSessionForTermination()

        let migrated = try await waitForSidecar(in: renamedFolder) {
            $0.sourcePath == renamedFolder.path
                && $0.entries.first?.rating == Rating.yes.rawValue
        }
        XCTAssertEqual(migrated.entries.count, 1)
    }

    func testRelocatedSidecarWithoutPhysicalMatchStaysBlocked() async throws {
        let fixture = try makeFixture(named: "UnverifiedRelocation")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let persistence = SessionPersistence(backupDirectory: fixture.backup)
        let source = fixture.photos.appendingPathComponent("A.png")
        let saved = SessionFile(
            version: SessionConstants.currentSchemaVersion,
            sourcePath: fixture.photos.path,
            scannedAt: Date(timeIntervalSince1970: 1),
            entries: [
                SessionEntry(
                    filename: "A.png",
                    pairedFilename: nil,
                    rating: Rating.yes.rawValue,
                    ratedAt: nil,
                    fileIdentity: try FileOperationJournal.captureIdentity(
                        at: source
                    )
                ),
            ],
            fileIDEncoding: .percentEncodedFileSystemPath
        )
        let initialSave = await persistence.save(
            saved,
            for: fixture.photos,
            sequence: 1
        )
        XCTAssertEqual(initialSave, .savedToSidecar)
        let originalSidecar = fixture.photos.appendingPathComponent(
            SessionConstants.sidecarName
        )
        let unrelated = fixture.root.appendingPathComponent(
            "Unrelated",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: unrelated,
            withIntermediateDirectories: true
        )
        try Data(contentsOf: source).write(
            to: unrelated.appendingPathComponent("B.png")
        )
        let copiedSidecar = unrelated.appendingPathComponent(
            SessionConstants.sidecarName
        )
        let preservedData = try Data(contentsOf: originalSidecar)
        try preservedData.write(to: copiedSidecar)

        let store = SessionStore(persistence: persistence)
        store.openFolder(unrelated)
        for _ in 0..<240 {
            if case .welcome = store.phase,
               store.scanError?.contains("another location") == true {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        guard case .welcome = store.phase else {
            return XCTFail("unverified relocated sidecar should block opening")
        }
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.scanError?.contains("another location") == true)
        XCTAssertEqual(try Data(contentsOf: copiedSidecar), preservedData)
    }

    func testRenamedOriginalLetsSamePathReplacementStartUndecided() async throws {
        let fixture = try makeFixture(named: "RenameAndReplacement")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let persistence = SessionPersistence(backupDirectory: fixture.backup)
        let original = fixture.photos.appendingPathComponent("A.png")
        let saved = SessionFile(
            version: SessionConstants.currentSchemaVersion,
            sourcePath: fixture.photos.path,
            scannedAt: Date(timeIntervalSince1970: 1),
            entries: [
                SessionEntry(
                    filename: "A.png",
                    pairedFilename: nil,
                    rating: Rating.yes.rawValue,
                    ratedAt: Date(timeIntervalSince1970: 1),
                    fileIdentity: try FileOperationJournal.captureIdentity(
                        at: original
                    )
                ),
            ],
            fileIDEncoding: .percentEncodedFileSystemPath
        )
        let initialSave = await persistence.save(
            saved,
            for: fixture.photos,
            sequence: 1
        )
        XCTAssertEqual(initialSave, .savedToSidecar)
        let renamed = fixture.photos.appendingPathComponent("Original-Renamed.png")
        try FileManager.default.moveItem(at: original, to: renamed)
        try Data(
            contentsOf: URL(
                fileURLWithPath: "AppIcon/AppIcon.iconset/icon_32x32.png"
            )
        ).write(to: original)

        let store = SessionStore(persistence: persistence)
        store.openFolder(fixture.photos)
        try await waitForReadySession(store, expectedItems: 2)
        XCTAssertNil(store.scanError)
        XCTAssertEqual(
            store.items.first(where: { $0.id == "Original-Renamed.png" })?.rating,
            .yes
        )
        XCTAssertEqual(
            store.items.first(where: { $0.id == "A.png" })?.rating,
            .undecided
        )
        _ = await store.saveSessionForTermination()
        let migrated = try await waitForSidecar(in: fixture.photos) { session in
            session.entries.count == 2
                && session.entries.contains {
                    $0.filename == "Original-Renamed.png"
                        && $0.rating == Rating.yes.rawValue
                }
                && session.entries.contains {
                    $0.filename == "A.png"
                        && $0.rating == Rating.undecided.rawValue
                }
        }
        XCTAssertEqual(migrated.entries.count, 2)
    }

    func testFolderPathSwapCannotTouchNewFolderOrOriginalBackup() async throws {
        let fixture = try makeFixture(named: "FolderPathSwap")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let persistence = SessionPersistence(backupDirectory: fixture.backup)
        let source = fixture.photos.appendingPathComponent("A.png")
        let folderIdentity = try SessionPersistence.SourceFolderIdentity
            .capture(at: fixture.photos)
        let read = await persistence.read(
            for: fixture.photos,
            folderIdentity: folderIdentity
        )
        let access = try XCTUnwrap(read.access)
        var session = currentSession(
            folder: fixture.photos,
            file: source,
            rating: .yes
        )
        let first = await persistence.save(
            session,
            for: fixture.photos,
            sequence: 1,
            access: access
        )
        XCTAssertEqual(first, .savedToSidecar)
        let backupFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.backup,
                includingPropertiesForKeys: nil
            ).first
        )
        let originalBackup = try Data(contentsOf: backupFile)

        let originalFolder = fixture.root.appendingPathComponent(
            "Original Photos",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: fixture.photos, to: originalFolder)
        try FileManager.default.createDirectory(
            at: fixture.photos,
            withIntermediateDirectories: true
        )
        let replacementSidecar = fixture.photos.appendingPathComponent(
            SessionConstants.sidecarName
        )
        let sentinel = Data("new card session".utf8)
        try sentinel.write(to: replacementSidecar)
        session.entries[0].rating = Rating.no.rawValue

        let swapped = await persistence.save(
            session,
            for: fixture.photos,
            sequence: 2,
            access: access
        )
        XCTAssertEqual(swapped, .sourceFolderChanged)
        XCTAssertEqual(try Data(contentsOf: replacementSidecar), sentinel)
        XCTAssertEqual(try Data(contentsOf: backupFile), originalBackup)
    }

    func testSidecarCASProtectsExternalCreationAndEdit() async throws {
        let fixture = try makeFixture(named: "SidecarCAS")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let persistence = SessionPersistence(backupDirectory: fixture.backup)
        let source = fixture.photos.appendingPathComponent("A.png")
        let folderIdentity = try SessionPersistence.SourceFolderIdentity
            .capture(at: fixture.photos)
        var read = await persistence.read(
            for: fixture.photos,
            folderIdentity: folderIdentity
        )
        var access = try XCTUnwrap(read.access)
        let sidecar = fixture.photos.appendingPathComponent(
            SessionConstants.sidecarName
        )
        let externalCreation = Data("external creation".utf8)
        try externalCreation.write(to: sidecar)
        let session = currentSession(
            folder: fixture.photos,
            file: source,
            rating: .yes
        )
        let creationConflict = await persistence.save(
            session,
            for: fixture.photos,
            sequence: 1,
            access: access
        )
        XCTAssertEqual(creationConflict, .sidecarChanged)
        XCTAssertEqual(try Data(contentsOf: sidecar), externalCreation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))

        try FileManager.default.removeItem(at: sidecar)
        read = await persistence.read(
            for: fixture.photos,
            folderIdentity: folderIdentity
        )
        access = try XCTUnwrap(read.access)
        var second = session
        let firstOwnSave = await persistence.save(
            session,
            for: fixture.photos,
            sequence: 2,
            access: access
        )
        XCTAssertEqual(firstOwnSave, .savedToSidecar)
        second.entries[0].rating = Rating.no.rawValue
        let secondOwnSave = await persistence.save(
            second,
            for: fixture.photos,
            sequence: 3,
            access: access
        )
        XCTAssertEqual(secondOwnSave, .savedToSidecar)
        XCTAssertEqual(try readSidecar(in: fixture.photos)?.entries.first?.rating, Rating.no.rawValue)
        let backupFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.backup,
                includingPropertiesForKeys: nil
            ).first
        )
        let ownBackup = try Data(contentsOf: backupFile)

        let externalEdit = Data("external edit".utf8)
        try externalEdit.write(to: sidecar, options: .atomic)
        let editConflict = await persistence.save(
            session,
            for: fixture.photos,
            sequence: 4,
            access: access
        )
        XCTAssertEqual(editConflict, .sidecarChanged)
        XCTAssertEqual(try Data(contentsOf: sidecar), externalEdit)
        XCTAssertEqual(try Data(contentsOf: backupFile), ownBackup)
    }

    func testTwoPersistenceInstancesSerializeBackupOnlySaveLineage() async throws {
        let fixture = try makeFixture(named: "ContendedPersistenceLock")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fixture.photos.path
            )
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let source = fixture.photos.appendingPathComponent("A.png")
        let identity = try SessionPersistence.SourceFolderIdentity.capture(
            at: fixture.photos
        )
        let firstHasLock = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondReachedLockWait = DispatchSemaphore(value: 0)
        let first = SessionPersistence(
            backupDirectory: fixture.backup,
            afterSaveLockAcquiredForTesting: {
                firstHasLock.signal()
                _ = releaseFirst.wait(timeout: .now() + 10)
            }
        )
        let second = SessionPersistence(
            backupDirectory: fixture.backup,
            beforeSaveLockForTesting: {
                secondReachedLockWait.signal()
            }
        )
        let firstRead = await first.read(
            for: fixture.photos,
            folderIdentity: identity
        )
        let firstAccess = try XCTUnwrap(firstRead.access)
        let secondRead = await second.read(
            for: fixture.photos,
            folderIdentity: identity
        )
        let secondAccess = try XCTUnwrap(secondRead.access)
        let firstSession = currentSession(
            folder: fixture.photos,
            file: source,
            rating: .yes
        )
        let secondSession = currentSession(
            folder: fixture.photos,
            file: source,
            rating: .no
        )

        // Force the authoritative folder write to fail so this also proves
        // that the identity-keyed fallback participates in the locked CAS.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: fixture.photos.path
        )
        let firstSave = Task {
            await first.save(
                firstSession,
                for: fixture.photos,
                sequence: 1,
                access: firstAccess
            )
        }
        let firstWait = await waitForSemaphore(firstHasLock)
        XCTAssertEqual(firstWait, .success)
        let secondSave = Task {
            await second.save(
                secondSession,
                for: fixture.photos,
                sequence: 1,
                access: secondAccess
            )
        }
        let secondWait = await waitForSemaphore(secondReachedLockWait)
        XCTAssertEqual(secondWait, .success)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: SessionPersistence.sidecarURL(
                    for: fixture.photos
                ).path
            )
        )
        releaseFirst.signal()

        let firstResult = await firstSave.value
        let secondResult = await secondSave.value
        guard case .savedToBackup = firstResult else {
            return XCTFail("first writer should own the backup lineage, got \(firstResult)")
        }
        XCTAssertEqual(secondResult, .sidecarChanged)
        let backup = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.backup,
                includingPropertiesForKeys: nil
            ).first
        )
        XCTAssertEqual(
            try readSession(at: backup).entries.first?.rating,
            Rating.yes.rawValue
        )
    }

    func testUnavailableBackupLineageCannotSupersedeContendedBackupSave() async throws {
        let fixture = try makeFixture(named: "UnavailableBackupContention")
        let newerHasLock = DispatchSemaphore(value: 0)
        let releaseNewer = DispatchSemaphore(value: 0)
        let staleReachedLockWait = DispatchSemaphore(value: 0)
        let staleHasLock = DispatchSemaphore(value: 0)
        let releaseStale = DispatchSemaphore(value: 0)
        defer {
            releaseNewer.signal()
            releaseStale.signal()
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fixture.photos.path
            )
            if let backup = try? FileManager.default.contentsOfDirectory(
                at: fixture.backup,
                includingPropertiesForKeys: nil
            ).first {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: backup.path
                )
            }
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let source = fixture.photos.appendingPathComponent("A.png")
        let baseline = currentSession(
            folder: fixture.photos,
            file: source,
            rating: .yes
        )
        let initial = SessionPersistence(backupDirectory: fixture.backup)
        let initialResult = await initial.save(
            baseline,
            for: fixture.photos,
            sequence: 1
        )
        XCTAssertEqual(initialResult, .savedToSidecar)
        let backup = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.backup,
                includingPropertiesForKeys: nil
            ).first
        )

        // The stale access can authenticate only the sidecar. Its unknown
        // fallback must not be treated as a wildcard after the lock is taken.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: backup.path
        )
        let stale = SessionPersistence(
            backupDirectory: fixture.backup,
            beforeSaveLockForTesting: {
                staleReachedLockWait.signal()
            },
            afterSaveLockAcquiredForTesting: {
                staleHasLock.signal()
                _ = releaseStale.wait(timeout: .now() + 10)
            }
        )
        let staleRead = await stale.read(for: fixture.photos)
        let staleAccess = try XCTUnwrap(staleRead.access)
        XCTAssertEqual(staleAccess.backupRevision, .unavailable)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: backup.path
        )
        let newer = SessionPersistence(
            backupDirectory: fixture.backup,
            afterSaveLockAcquiredForTesting: {
                newerHasLock.signal()
                _ = releaseNewer.wait(timeout: .now() + 10)
            }
        )
        let newerRead = await newer.read(for: fixture.photos)
        let newerAccess = try XCTUnwrap(newerRead.access)
        guard case .content = newerAccess.backupRevision else {
            return XCTFail("newer writer should observe the readable backup")
        }
        var newerSession = baseline
        newerSession.entries[0].rating = Rating.no.rawValue
        var staleSession = baseline
        staleSession.entries[0].rating = Rating.undecided.rawValue

        // The newer writer must fall back to the backup while the stale writer
        // queues on the same physical-folder lock.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: fixture.photos.path
        )
        let newerSave = Task {
            await newer.save(
                newerSession,
                for: fixture.photos,
                sequence: 1,
                access: newerAccess
            )
        }
        let newerWait = await waitForSemaphore(newerHasLock)
        XCTAssertEqual(newerWait, .success)
        let staleSave = Task {
            await stale.save(
                staleSession,
                for: fixture.photos,
                sequence: 1,
                access: staleAccess
            )
        }
        let staleQueueWait = await waitForSemaphore(staleReachedLockWait)
        XCTAssertEqual(staleQueueWait, .success)
        releaseNewer.signal()
        let staleAcquisitionWait = await waitForSemaphore(staleHasLock)
        XCTAssertEqual(staleAcquisitionWait, .success)

        // Make the stale sidecar write viable only after the newer backup is
        // committed. A correct CAS rejects it before filesystem permissions
        // can influence the result.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fixture.photos.path
        )
        releaseStale.signal()
        let newerResult = await newerSave.value
        let staleResult = await staleSave.value
        guard case .savedToBackup = newerResult else {
            return XCTFail("newer writer should save to backup, got \(newerResult)")
        }
        XCTAssertEqual(staleResult, .sidecarChanged)
        XCTAssertEqual(
            try readSidecar(in: fixture.photos)?.entries.first?.rating,
            Rating.yes.rawValue
        )
        XCTAssertEqual(
            try readSession(at: backup).entries.first?.rating,
            Rating.no.rawValue
        )
        let loaded = await SessionPersistence(
            backupDirectory: fixture.backup
        ).read(for: fixture.photos)
        XCTAssertEqual(loaded.origin, .backup)
        XCTAssertEqual(
            loaded.session?.entries.first?.rating,
            Rating.no.rawValue
        )
    }

    func testPersistenceKeepsExactComposedFolderURLForSidecar() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Louppe-ExactFolder-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = rawChildURL(
            in: root,
            nameBytes: Array("caf".utf8) + [0xC3, 0xA9],
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: false
        )
        let source = folder.appendingPathComponent("A.png")
        try Data(contentsOf: URL(
            fileURLWithPath: "AppIcon/AppIcon.iconset/icon_16x16.png"
        )).write(to: source)
        let backup = root.appendingPathComponent("Backup", isDirectory: true)
        let persistence = SessionPersistence(backupDirectory: backup)
        let identity = try SessionPersistence.SourceFolderIdentity.capture(
            at: folder
        )
        let read = await persistence.read(
            for: folder,
            folderIdentity: identity
        )
        let access = try XCTUnwrap(read.access)

        let result = await persistence.save(
            currentSession(folder: folder, file: source, rating: .yes),
            for: folder,
            sequence: 1,
            access: access
        )

        XCTAssertEqual(result, .savedToSidecar)
        let sidecar = SessionPersistence.sidecarURL(for: folder)
        XCTAssertEqual(
            sidecar.path(percentEncoded: true),
            folder.path(percentEncoded: true)
                + SessionConstants.sidecarName
        )
        XCTAssertTrue(sidecar.path(percentEncoded: true).contains("caf%C3%A9"))
        XCTAssertFalse(sidecar.path(percentEncoded: true).contains("cafe%CC%81"))
        XCTAssertEqual(
            try readSession(at: sidecar).entries.first?.rating,
            Rating.yes.rawValue
        )
    }

    func testUnreadableBackupDoesNotBlockExactSidecarSaveOrGetReplaced() async throws {
        let fixture = try makeFixture(named: "UnreadableBackupLineage")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.photos.appendingPathComponent("A.png")
        let initial = SessionPersistence(backupDirectory: fixture.backup)
        var session = currentSession(
            folder: fixture.photos,
            file: source,
            rating: .yes
        )
        let initialResult = await initial.save(
            session,
            for: fixture.photos,
            sequence: 1
        )
        XCTAssertEqual(initialResult, .savedToSidecar)
        let backup = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.backup,
                includingPropertiesForKeys: nil
            ).first
        )
        let originalBackup = try Data(contentsOf: backup)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: backup.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: backup.path
            )
        }

        let persistence = SessionPersistence(backupDirectory: fixture.backup)
        let read = await persistence.read(for: fixture.photos)
        let access = try XCTUnwrap(read.access)
        XCTAssertEqual(read.origin, .sidecar)
        session.entries[0].rating = Rating.no.rawValue
        let result = await persistence.save(
            session,
            for: fixture.photos,
            sequence: 1,
            access: access
        )

        XCTAssertEqual(result, .savedToSidecar)
        XCTAssertEqual(
            try readSidecar(in: fixture.photos)?.entries.first?.rating,
            Rating.no.rawValue
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: backup.path
        )
        XCTAssertEqual(try Data(contentsOf: backup), originalBackup)
    }

    func testReadRejectsSidecarChangedAfterExactBytesWereDecoded() async throws {
        let fixture = try makeFixture(named: "ReadLineage")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.photos.appendingPathComponent("A.png")
        let initialPersistence = SessionPersistence(
            backupDirectory: fixture.backup
        )
        let firstSession = currentSession(
            folder: fixture.photos,
            file: source,
            rating: .yes
        )
        let firstSave = await initialPersistence.save(
            firstSession,
            for: fixture.photos,
            sequence: 1
        )
        XCTAssertEqual(firstSave, .savedToSidecar)

        var replacementSession = firstSession
        replacementSession.scannedAt = firstSession.scannedAt
            .addingTimeInterval(1)
        replacementSession.entries[0].rating = Rating.no.rawValue
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let replacementData = try encoder.encode(replacementSession)
        let sidecar = fixture.photos.appendingPathComponent(
            SessionConstants.sidecarName
        )
        let persistence = SessionPersistence(
            backupDirectory: fixture.backup,
            afterSidecarReadForTesting: {
                try! replacementData.write(to: sidecar, options: .atomic)
            }
        )
        let identity = try SessionPersistence.SourceFolderIdentity.capture(
            at: fixture.photos
        )

        let read = await persistence.read(
            for: fixture.photos,
            folderIdentity: identity
        )

        XCTAssertNil(read.session)
        XCTAssertNil(read.access)
        XCTAssertEqual(read.problems, [.sidecarChanged])
        XCTAssertNotNil(read.blockingMessage)
        XCTAssertEqual(try Data(contentsOf: sidecar), replacementData)
    }

    func testSnapshotGenerationOutranksWallClockAndLegacySnapshots() async throws {
        let fixture = try makeFixture(named: "SnapshotGenerationOrdering")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.photos.appendingPathComponent("A.png")
        let persistence = SessionPersistence(backupDirectory: fixture.backup)
        var initial = currentSession(
            folder: fixture.photos,
            file: source,
            rating: .yes
        )
        initial.scannedAt = Date(timeIntervalSince1970: 200)
        let initialSave = await persistence.save(
            initial,
            for: fixture.photos,
            sequence: 1
        )
        XCTAssertEqual(initialSave, .savedToSidecar)

        let sidecar = fixture.photos.appendingPathComponent(
            SessionConstants.sidecarName
        )
        let backup = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.backup,
                includingPropertiesForKeys: nil
            ).first
        )
        let first = try XCTUnwrap(readSidecar(in: fixture.photos))
        XCTAssertEqual(first.snapshotGeneration, 1)

        var newerGeneration = first
        newerGeneration.snapshotGeneration = 2
        newerGeneration.scannedAt = Date(timeIntervalSince1970: 100)
        newerGeneration.entries[0].rating = Rating.no.rawValue
        try writeSession(newerGeneration, to: backup)

        var loaded = await SessionPersistence(
            backupDirectory: fixture.backup
        ).read(for: fixture.photos)
        XCTAssertEqual(loaded.origin, .backup)
        XCTAssertEqual(loaded.session?.snapshotGeneration, 2)
        XCTAssertEqual(loaded.session?.entries[0].rating, Rating.no.rawValue)

        var futureDatedLegacy = newerGeneration
        futureDatedLegacy.snapshotGeneration = nil
        futureDatedLegacy.scannedAt = Date(timeIntervalSince1970: 10_000)
        try writeSession(futureDatedLegacy, to: backup)
        loaded = await SessionPersistence(
            backupDirectory: fixture.backup
        ).read(for: fixture.photos)
        XCTAssertEqual(
            loaded.origin,
            .sidecar,
            "a generated snapshot must outrank a future-dated pre-generation backup"
        )
        XCTAssertEqual(loaded.session?.entries[0].rating, Rating.yes.rawValue)

        var legacySidecar = first
        legacySidecar.snapshotGeneration = nil
        legacySidecar.scannedAt = Date(timeIntervalSince1970: 100)
        try writeSession(legacySidecar, to: sidecar)
        futureDatedLegacy.scannedAt = Date(timeIntervalSince1970: 200)
        try writeSession(futureDatedLegacy, to: backup)
        loaded = await SessionPersistence(
            backupDirectory: fixture.backup
        ).read(for: fixture.photos)
        XCTAssertEqual(
            loaded.origin,
            .backup,
            "two old snapshots must retain their backward-compatible timestamp ordering"
        )
    }

    func testSnapshotGenerationAdvancesAcrossBackupOnlyAndOrdinarySaves() async throws {
        let fixture = try makeFixture(named: "BackupGeneration")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.photos.appendingPathComponent("A.png")
        let persistence = SessionPersistence(backupDirectory: fixture.backup)
        var session = currentSession(
            folder: fixture.photos,
            file: source,
            rating: .yes
        )
        session.scannedAt = Date(timeIntervalSince1970: 300)
        let initialSave = await persistence.save(
            session,
            for: fixture.photos,
            sequence: 1
        )
        XCTAssertEqual(initialSave, .savedToSidecar)
        let initialRead = await persistence.read(for: fixture.photos)
        let access = try XCTUnwrap(initialRead.access)
        let originalPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: fixture.photos.path
            )[.posixPermissions] as? NSNumber
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: originalPermissions],
                ofItemAtPath: fixture.photos.path
            )
        }

        session.scannedAt = Date(timeIntervalSince1970: 200)
        session.entries[0].rating = Rating.no.rawValue
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o500)],
            ofItemAtPath: fixture.photos.path
        )
        let backupOnly = await persistence.save(
            session,
            for: fixture.photos,
            sequence: 2,
            access: access
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: originalPermissions],
            ofItemAtPath: fixture.photos.path
        )
        guard case .savedToBackup = backupOnly else {
            return XCTFail(
                "a read-only sidecar must fall back to the writable backup, got \(backupOnly)"
            )
        }

        let backup = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.backup,
                includingPropertiesForKeys: nil
            ).first
        )
        let backupSession = try readSession(at: backup)
        XCTAssertEqual(backupSession.snapshotGeneration, 2)
        XCTAssertEqual(backupSession.entries[0].rating, Rating.no.rawValue)
        XCTAssertEqual(
            try XCTUnwrap(readSidecar(in: fixture.photos)).snapshotGeneration,
            1
        )

        session.scannedAt = Date(timeIntervalSince1970: 100)
        session.entries[0].rating = Rating.undecided.rawValue
        let finalSave = await persistence.save(
            session,
            for: fixture.photos,
            sequence: 3,
            access: access
        )
        XCTAssertEqual(finalSave, .savedToSidecar)
        let final = try XCTUnwrap(readSidecar(in: fixture.photos))
        XCTAssertEqual(final.snapshotGeneration, 3)
        XCTAssertEqual(
            final.entries[0].rating,
            Rating.undecided.rawValue
        )
    }

    func testLegacySidecarWaitsForExplicitMigrationConfirmation() async throws {
        let fixture = try makeFixture(named: "LegacyConfirmation")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sidecar = fixture.photos.appendingPathComponent(
            SessionConstants.sidecarName
        )
        let legacy = SessionFile(
            version: 2,
            sourcePath: fixture.photos.path,
            scannedAt: Date(timeIntervalSince1970: 1),
            entries: [
                SessionEntry(
                    filename: "A.png",
                    pairedFilename: nil,
                    rating: Rating.yes.rawValue,
                    ratedAt: nil
                )
            ]
        )
        try writeSession(legacy, to: sidecar)
        let originalSidecar = try Data(contentsOf: sidecar)
        let store = SessionStore(
            persistence: SessionPersistence(backupDirectory: fixture.backup)
        )

        store.openFolder(fixture.photos)
        try await waitForLegacyMigrationConfirmation(in: store)
        XCTAssertEqual(store.items.first?.rating, .yes)
        XCTAssertTrue(store.isSessionCommandPresentationActive)
        XCTAssertFalse(store.canExport)
        XCTAssertFalse(store.canCleanUp)
        XCTAssertEqual(try Data(contentsOf: sidecar), originalSidecar)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.backup.path),
            "opening an old session must not create a migration backup before consent"
        )

        let terminationSave = await store.saveSessionForTermination()
        XCTAssertNil(terminationSave)
        XCTAssertEqual(
            try Data(contentsOf: sidecar),
            originalSidecar,
            "termination must preserve the legacy snapshot while confirmation is pending"
        )

        store.confirmLegacySessionMigration()
        let migrated = try await waitForSidecar(in: fixture.photos) {
            $0.version == SessionConstants.currentSchemaVersion
                && $0.snapshotGeneration == 1
                && $0.entries.first?.fileIdentity != nil
        }
        XCTAssertFalse(store.isLegacySessionMigrationConfirmationPresented)
        XCTAssertEqual(migrated.entries.first?.rating, Rating.yes.rawValue)
    }

    func testLegacyPathBackupCanBeReviewedAndClosedWithoutMigration() async throws {
        let fixture = try makeFixture(named: "LegacyPathBackup")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            at: fixture.backup,
            withIntermediateDirectories: true
        )
        let oldBackup = legacyPathBackupURL(
            for: fixture.photos,
            in: fixture.backup
        )
        let legacy = SessionFile(
            version: 3,
            sourcePath: fixture.photos.path,
            scannedAt: Date(timeIntervalSince1970: 1),
            entries: [
                SessionEntry(
                    filename: "A.png",
                    pairedFilename: nil,
                    rating: Rating.no.rawValue,
                    ratedAt: nil
                )
            ],
            fileIDEncoding: .percentEncodedFileSystemPath
        )
        try writeSession(legacy, to: oldBackup)
        let originalBackup = try Data(contentsOf: oldBackup)
        let sidecar = fixture.photos.appendingPathComponent(
            SessionConstants.sidecarName
        )
        let store = SessionStore(
            persistence: SessionPersistence(backupDirectory: fixture.backup)
        )

        store.openFolder(fixture.photos)
        try await waitForLegacyMigrationConfirmation(in: store)
        XCTAssertEqual(store.items.first?.rating, .no)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertEqual(try Data(contentsOf: oldBackup), originalBackup)

        store.closeLegacySessionWithoutMigrating()
        guard case .welcome = store.phase else {
            return XCTFail("Close Folder must leave the legacy review session")
        }
        XCTAssertNil(store.sourceFolder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertEqual(
            try Data(contentsOf: oldBackup),
            originalBackup,
            "cancelling legacy recovery must preserve its only saved copy"
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: fixture.backup,
                includingPropertiesForKeys: nil
            ).count,
            1,
            "cancelling must not create a new identity-keyed backup"
        )
    }

    func testUnmatchedLegacyEntryBlocksMigrationWithoutTouchingCopies() async throws {
        let fixture = try makeFixture(named: "LegacyMissing")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let persistence = SessionPersistence(backupDirectory: fixture.backup)
        let a = fixture.photos.appendingPathComponent("A.png")
        let b = fixture.photos.appendingPathComponent("B.png")
        try Data(contentsOf: a).write(to: b)
        let legacy = SessionFile(
            version: 2,
            sourcePath: fixture.photos.path,
            scannedAt: Date(timeIntervalSince1970: 1),
            entries: [
                SessionEntry(
                    filename: "A.png",
                    pairedFilename: nil,
                    rating: Rating.yes.rawValue,
                    ratedAt: nil
                ),
                SessionEntry(
                    filename: "B.png",
                    pairedFilename: nil,
                    rating: Rating.no.rawValue,
                    ratedAt: nil
                ),
            ]
        )
        let legacySave = await persistence.save(
            legacy,
            for: fixture.photos,
            sequence: 1
        )
        XCTAssertEqual(legacySave, .savedToSidecar)
        let sidecar = fixture.photos.appendingPathComponent(
            SessionConstants.sidecarName
        )
        let originalSidecar = try Data(contentsOf: sidecar)
        let backupFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.backup,
                includingPropertiesForKeys: nil
            ).first
        )
        let originalBackup = try Data(contentsOf: backupFile)
        try FileManager.default.moveItem(
            at: b,
            to: fixture.root.appendingPathComponent("B-away.png")
        )

        let store = SessionStore(persistence: persistence)
        store.openFolder(fixture.photos)
        try await waitForScanError(containing: "older Louppe session", in: store)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(try Data(contentsOf: sidecar), originalSidecar)
        XCTAssertEqual(try Data(contentsOf: backupFile), originalBackup)
    }

    private struct Fixture {
        let root: URL
        let photos: URL
        let backup: URL
    }

    private enum WaitError: Error {
        case timedOut
    }

    private func makeFixture(named name: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Louppe-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        let backup = root.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(
            at: photos,
            withIntermediateDirectories: true
        )
        let source = URL(
            fileURLWithPath: "AppIcon/AppIcon.iconset/icon_16x16.png"
        )
        try Data(contentsOf: source).write(
            to: photos.appendingPathComponent("A.png")
        )
        return Fixture(root: root, photos: photos, backup: backup)
    }

    private func rawChildURL(
        in parent: URL,
        nameBytes: [UInt8],
        isDirectory: Bool
    ) -> URL {
        var representation = parent.withUnsafeFileSystemRepresentation {
            pointer -> [UInt8] in
            guard let pointer else { return [] }
            var bytes: [UInt8] = []
            var cursor = pointer
            while cursor.pointee != 0 {
                bytes.append(UInt8(bitPattern: cursor.pointee))
                cursor = cursor.advanced(by: 1)
            }
            return bytes
        }
        if representation.last != 0x2F {
            representation.append(0x2F)
        }
        representation.append(contentsOf: nameBytes)
        var terminated = representation.map(Int8.init(bitPattern:))
        terminated.append(0)
        return terminated.withUnsafeBufferPointer { buffer in
            URL(
                fileURLWithFileSystemRepresentation: buffer.baseAddress!,
                isDirectory: isDirectory,
                relativeTo: nil
            )
        }
    }

    private func waitForReadySession(
        _ store: SessionStore,
        expectedItems: Int = 1,
        requiresTransitionToFinish: Bool = false
    ) async throws {
        var observedTransition = !requiresTransitionToFinish
        for _ in 0..<240 {
            if store.isSessionTransitioning {
                observedTransition = true
            }
            if observedTransition,
               !store.isSessionTransitioning,
               case .ready = store.phase,
               store.items.count == expectedItems {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw WaitError.timedOut
    }

    private func waitForSemaphore(
        _ semaphore: DispatchSemaphore
    ) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: semaphore.wait(timeout: .now() + 10)
                )
            }
        }
    }

    private func waitForIdentityConflict(
        in store: SessionStore
    ) async throws {
        for _ in 0..<240 {
            if case .welcome = store.phase,
               store.scanError?.contains("not the same physical file") == true {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw WaitError.timedOut
    }

    private func waitForScanError(
        containing text: String,
        in store: SessionStore
    ) async throws {
        for _ in 0..<240 {
            if case .welcome = store.phase,
               store.scanError?.contains(text) == true {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw WaitError.timedOut
    }

    private func waitForLegacyMigrationConfirmation(
        in store: SessionStore
    ) async throws {
        for _ in 0..<240 {
            if case .ready = store.phase,
               store.isLegacySessionMigrationConfirmationPresented {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw WaitError.timedOut
    }

    private func currentSession(
        folder: URL,
        file: URL,
        rating: Rating
    ) -> SessionFile {
        SessionFile(
            version: SessionConstants.currentSchemaVersion,
            sourcePath: folder.path,
            scannedAt: Date(),
            entries: [
                SessionEntry(
                    filename: file.lastPathComponent,
                    pairedFilename: nil,
                    rating: rating.rawValue,
                    ratedAt: nil,
                    fileIdentity: try? FileOperationJournal.captureIdentity(
                        at: file
                    )
                )
            ],
            fileIDEncoding: .percentEncodedFileSystemPath
        )
    }

    private func waitForSidecar(
        in folder: URL,
        where predicate: (SessionFile) -> Bool
    ) async throws -> SessionFile {
        for _ in 0..<200 {
            if let session = try readSidecar(in: folder),
               predicate(session) {
                return session
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw WaitError.timedOut
    }

    private func waitForSaveCalls(
        _ expected: Int,
        in persistence: GatedSessionPersistence
    ) async throws {
        for _ in 0..<200 {
            if await persistence.saveCallCount() >= expected {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw WaitError.timedOut
    }

    private func waitForDeferredSave(
        in store: SessionStore
    ) async throws {
        for _ in 0..<200 {
            if store.hasDeferredPersistenceSave {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw WaitError.timedOut
    }

    private func readSidecar(in folder: URL) throws -> SessionFile? {
        let url = folder.appendingPathComponent(SessionConstants.sidecarName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try readSession(at: url)
    }

    private func readSession(at url: URL) throws -> SessionFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            SessionFile.self,
            from: Data(contentsOf: url)
        )
    }

    private func writeSession(_ session: SessionFile, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: url, options: .atomic)
    }

    private func legacyPathBackupURL(
        for folder: URL,
        in backupDirectory: URL
    ) -> URL {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in folder.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return backupDirectory.appendingPathComponent(
            String(format: "%016llx.json", hash)
        )
    }
}

private actor GatedSessionPersistence: SessionPersistenceClient {
    private var saveCalls = 0
    private var capturedRatings: [String] = []
    private var shouldBlockSaves = true
    private var blockedSaves: [CheckedContinuation<Void, Never>] = []

    func save(
        _ session: SessionFile,
        for folder: URL,
        sequence: UInt64,
        access: SessionPersistence.AccessContext
    ) async -> SessionPersistence.SaveResult {
        saveCalls += 1
        capturedRatings.append(
            session.entries.first?.rating ?? "<missing>"
        )
        if shouldBlockSaves {
            await withCheckedContinuation { continuation in
                blockedSaves.append(continuation)
            }
        }
        return .savedToSidecar
    }

    func read(
        for folder: URL,
        folderIdentity: SessionPersistence.SourceFolderIdentity
    ) async -> SessionPersistence.ReadResult {
        SessionPersistence.ReadResult(
            session: nil,
            origin: nil,
            problems: [],
            access: SessionPersistence.AccessContext(
                id: UUID(),
                folderIdentity: folderIdentity,
                sidecarRevision: .absent
            )
        )
    }

    func saveCallCount() -> Int {
        saveCalls
    }

    func capturedRating(forCall index: Int) -> String? {
        guard capturedRatings.indices.contains(index) else { return nil }
        return capturedRatings[index]
    }

    func releaseNextSave() {
        guard !blockedSaves.isEmpty else { return }
        blockedSaves.removeFirst().resume()
    }

    func releaseAllSaves() {
        shouldBlockSaves = false
        let continuations = blockedSaves
        blockedSaves.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}
