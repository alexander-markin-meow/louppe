import Darwin
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

        // Quit must await the active checkpoint instead of launching another
        // full snapshot alongside it. Once that older checkpoint completes,
        // the deferred rating is captured exactly once.
        try await Task.sleep(nanoseconds: 30_000_000)
        let callsBeforeActiveCheckpointCompletes =
            await persistence.saveCallCount()
        XCTAssertEqual(callsBeforeActiveCheckpointCompletes, 1)
        await persistence.releaseNextSave()
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

    func testCleanTerminationDoesNotWriteAnIdenticalSnapshot() async throws {
        let fixture = try makeFixture(named: "CleanTermination")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let persistence = GatedSessionPersistence()
        let store = SessionStore(persistence: persistence)
        store.openFolder(fixture.photos)
        try await waitForReadySession(store)
        try await waitForSaveCalls(1, in: persistence)
        await persistence.releaseAllSaves()
        let initialSaveFinished = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(initialSaveFinished)

        store.beginTerminationPreparation()
        let result = await store.saveSessionForTermination()
        let finalSaveCallCount = await persistence.saveCallCount()

        XCTAssertNil(result)
        XCTAssertEqual(
            finalSaveCallCount,
            1,
            "Quit must not turn a clean session into a new storage dependency"
        )
    }

    func testCleanTerminationAwaitsOptionalInitialCheckpointWithoutDuplicatingIt() async throws {
        let fixture = try makeFixture(named: "CleanActiveTermination")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let persistence = GatedSessionPersistence()
        let store = SessionStore(persistence: persistence)
        store.openFolder(fixture.photos)
        try await waitForReadySession(store)
        try await waitForSaveCalls(1, in: persistence)

        store.beginTerminationPreparation()
        let completion = CompletionProbe()
        let termination = Task { @MainActor in
            let result = await store.saveSessionForTermination()
            await completion.markFinished()
            return result
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        let callsWhileCheckpointIsActive = await persistence.saveCallCount()
        let finishedBeforeCheckpoint = await completion.isFinished()
        XCTAssertFalse(
            finishedBeforeCheckpoint,
            "Quit must await an already-active durability checkpoint"
        )
        XCTAssertEqual(callsWhileCheckpointIsActive, 1)

        await persistence.releaseAllSaves()
        let result = await termination.value
        XCTAssertEqual(result, .savedToSidecar)
        let reachedIdle = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(reachedIdle)
        let finalSaveCallCount = await persistence.saveCallCount()
        XCTAssertEqual(finalSaveCallCount, 1)
    }

    func testFailedOptionalInitialCheckpointDoesNotBlockCleanQuit() async throws {
        let fixture = try makeFixture(named: "CleanFailedActiveTermination")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let failure = SessionPersistence.SaveResult.failed(
            SessionPersistence.SaveFailure(
                sidecar: .volumeUnavailable,
                backup: .outOfSpace
            )
        )
        let persistence = GatedSessionPersistence(results: [failure])
        let store = SessionStore(persistence: persistence)
        store.openFolder(fixture.photos)
        try await waitForReadySession(store)
        try await waitForSaveCalls(1, in: persistence)

        store.beginTerminationPreparation()
        let termination = Task { @MainActor in
            await store.saveSessionForTermination()
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        let callsBeforeRelease = await persistence.saveCallCount()
        XCTAssertEqual(callsBeforeRelease, 1)

        await persistence.releaseAllSaves()
        let result = await termination.value
        XCTAssertNil(
            result,
            "failure of optional maintenance must not produce a Quit blocker"
        )
        let finalSaveCallCount = await persistence.saveCallCount()
        XCTAssertEqual(finalSaveCallCount, 1)
        XCTAssertTrue(
            store.persistenceWarning?.contains(
                "No new ratings are waiting to be saved"
            ) == true
        )
    }

    func testTerminationRetriesAGenuinelyUnsavedSnapshotOnce() async throws {
        let fixture = try makeFixture(named: "RequiredTerminationRetry")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let failure = SessionPersistence.SaveResult.failed(
            SessionPersistence.SaveFailure(
                sidecar: .volumeUnavailable,
                backup: .outOfSpace
            )
        )
        let persistence = GatedSessionPersistence(
            results: [failure, .savedToSidecar]
        )
        let store = SessionStore(persistence: persistence)
        store.openFolder(fixture.photos)
        try await waitForReadySession(store)
        try await waitForSaveCalls(1, in: persistence)
        await persistence.releaseAllSaves()
        let initialSaveFinished = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(initialSaveFinished)

        store.rate(.yes, at: 0)
        store.beginTerminationPreparation()
        let result = await store.saveSessionForTermination()
        let saveCallCount = await persistence.saveCallCount()
        XCTAssertEqual(result, .savedToSidecar)
        XCTAssertEqual(saveCallCount, 2)
    }

    func testTerminationDoesNotRepeatAnInvalidSnapshotCheck() async throws {
        let fixture = try makeFixture(named: "InvalidTerminationSnapshot")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let persistence = GatedSessionPersistence(
            results: [.rejectedInvalidSnapshot]
        )
        let store = SessionStore(persistence: persistence)
        store.openFolder(fixture.photos)
        try await waitForReadySession(store)
        try await waitForSaveCalls(1, in: persistence)
        await persistence.releaseAllSaves()
        let initialSaveFinished = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(initialSaveFinished)

        store.beginTerminationPreparation()
        let result = await store.saveSessionForTermination()
        let saveCallCount = await persistence.saveCallCount()
        XCTAssertEqual(result, .rejectedInvalidSnapshot)
        XCTAssertEqual(saveCallCount, 1)
    }

    func testDirtyDisconnectedSessionQuitsAfterSavingToLocalBackup() async throws {
        let fixture = try makeFixture(named: "DisconnectedStoreTermination")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let persistence = SessionPersistence(backupDirectory: fixture.backup)
        let store = SessionStore(persistence: persistence)
        store.openFolder(fixture.photos)
        try await waitForReadySession(store)
        _ = try await waitForSidecar(in: fixture.photos) {
            $0.entries.first?.rating == Rating.undecided.rawValue
        }
        let initialSaveFinished = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(initialSaveFinished)

        let disconnectedFolder = fixture.root.appendingPathComponent(
            "Disconnected Photos",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: fixture.photos,
            to: disconnectedFolder
        )
        store.rate(.no, at: 0)
        store.beginTerminationPreparation()

        let result = await store.saveSessionForTermination()

        XCTAssertEqual(
            result,
            .savedToBackup(sidecarFailure: .volumeUnavailable)
        )
        XCTAssertTrue(result?.canDiscardInMemoryState == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.photos.path))
        let disconnectedSidecar = try readSession(
            at: disconnectedFolder.appendingPathComponent(
                SessionConstants.sidecarName
            )
        )
        XCTAssertEqual(
            disconnectedSidecar.entries.first?.rating,
            Rating.undecided.rawValue
        )
        let backup = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.backup,
                includingPropertiesForKeys: nil
            ).first
        )
        XCTAssertEqual(
            try readSession(at: backup).entries.first?.rating,
            Rating.no.rawValue
        )

        // Backup-only success keeps Retry available for repairing the card's
        // sidecar later, but it is already durable and must never block Quit.
        XCTAssertTrue(store.canRetryPersistence)
        store.cancelTerminationPreparation()
        store.beginTerminationPreparation()
        let cleanOfflineQuit = await store.saveSessionForTermination()
        XCTAssertNil(cleanOfflineQuit)
        XCTAssertTrue(store.canRetryPersistence)
    }

    func testBackupOnlyCloseRemainsOptionalOnTheWelcomeScreen() async throws {
        let fixture = try makeFixture(named: "BackupOnlyClose")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let persistence = GatedSessionPersistence(
            results: [
                .savedToSidecar,
                .savedToBackup(sidecarFailure: .volumeUnavailable),
            ]
        )
        let store = SessionStore(
            persistence: persistence,
            saveTrailingDelay: 10,
            saveMaximumDelay: 20
        )
        store.openFolder(fixture.photos)
        try await waitForReadySession(store)
        try await waitForSaveCalls(1, in: persistence)
        await persistence.releaseAllSaves()
        let initialSaveFinished = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(initialSaveFinished)

        store.rate(.yes, at: 0)
        store.closeSession()
        for _ in 0..<240 {
            if case .welcome = store.phase, !store.isSessionTransitioning {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard case .welcome = store.phase else {
            return XCTFail("a backup-only save should safely close the folder")
        }
        XCTAssertTrue(store.canRetryPersistence)
        let closeSaveCallCount = await persistence.saveCallCount()
        XCTAssertEqual(closeSaveCallCount, 2)

        store.beginTerminationPreparation()
        let quitResult = await store.saveSessionForTermination()
        let finalSaveCallCount = await persistence.saveCallCount()
        XCTAssertNil(quitResult)
        XCTAssertEqual(finalSaveCallCount, 2)
        XCTAssertTrue(store.canRetryPersistence)
    }

    func testFailedSameFolderRescanDoesNotKeepAStaleRetryButton() async throws {
        let fixture = try makeFixture(named: "FailedRescanRetry")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let persistence = GatedSessionPersistence(
            results: [
                .savedToBackup(sidecarFailure: .volumeUnavailable),
            ]
        )
        let store = SessionStore(persistence: persistence)
        store.openFolder(fixture.photos)
        try await waitForReadySession(store)
        try await waitForSaveCalls(1, in: persistence)
        await persistence.releaseAllSaves()
        let initialSaveFinished = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(initialSaveFinished)
        XCTAssertTrue(store.canRetryPersistence)

        let unavailableFolder = fixture.root.appendingPathComponent(
            "Unavailable Photos",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: fixture.photos,
            to: unavailableFolder
        )
        store.rescan()
        for _ in 0..<240 {
            if case .welcome = store.phase, !store.isSessionTransitioning {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        guard case .welcome = store.phase else {
            return XCTFail("the unavailable same-folder rescan should fail")
        }
        XCTAssertNil(store.persistenceWarning)
        XCTAssertFalse(store.canRetryPersistence)
    }

    func testFailedOptionalRepairStillSaysRatingsAreSafe() async throws {
        let fixture = try makeFixture(named: "OptionalRepairMessage")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let repairFailure = SessionPersistence.SaveResult.failed(
            SessionPersistence.SaveFailure(
                sidecar: .volumeUnavailable,
                backup: .outOfSpace
            )
        )
        let persistence = GatedSessionPersistence(
            results: [
                .savedToBackup(sidecarFailure: .volumeUnavailable),
                repairFailure,
            ]
        )
        let store = SessionStore(persistence: persistence)
        store.openFolder(fixture.photos)
        try await waitForReadySession(store)
        try await waitForSaveCalls(1, in: persistence)
        await persistence.releaseAllSaves()
        let initialSaveFinished = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(initialSaveFinished)

        store.retryPersistence()
        try await waitForSaveCalls(2, in: persistence)
        let repairFinished = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(repairFinished)
        XCTAssertTrue(
            store.persistenceWarning?.contains(
                "No new ratings are waiting to be saved"
            ) == true
        )
        XCTAssertFalse(
            store.persistenceWarning?.contains("not saved") == true
        )

        store.beginTerminationPreparation()
        let quitResult = await store.saveSessionForTermination()
        let saveCallCount = await persistence.saveCallCount()
        XCTAssertNil(quitResult)
        XCTAssertEqual(saveCallCount, 2)
    }

    func testNewRatingClearsOptionalSafeWarningAndOlderRepairCannotRestoreIt() async throws {
        let fixture = try makeFixture(named: "OptionalRepairBecomesDirty")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let repairFailure = SessionPersistence.SaveResult.failed(
            SessionPersistence.SaveFailure(
                sidecar: .volumeUnavailable,
                backup: .outOfSpace
            )
        )
        let persistence = GatedSessionPersistence(
            results: [
                .savedToBackup(sidecarFailure: .volumeUnavailable),
                repairFailure,
                .savedToSidecar,
            ]
        )
        let store = SessionStore(persistence: persistence)
        store.openFolder(fixture.photos)
        try await waitForReadySession(store)
        try await waitForSaveCalls(1, in: persistence)
        await persistence.releaseNextSave()
        let initialSaveFinished = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(initialSaveFinished)
        XCTAssertTrue(
            store.persistenceWarning?.contains("ratings are safe") == true
        )

        store.retryPersistence()
        try await waitForSaveCalls(2, in: persistence)
        store.rate(.yes, at: 0)
        XCTAssertNil(
            store.persistenceWarning,
            "a safe message for an older generation must disappear immediately"
        )

        await persistence.releaseNextSave()
        let repairFinished = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(repairFinished)
        XCTAssertNil(
            store.persistenceWarning,
            "an older optional repair must not label a newer unsaved rating safe"
        )

        await persistence.releaseAllSaves()
        store.beginTerminationPreparation()
        let finalResult = await store.saveSessionForTermination()
        XCTAssertEqual(finalResult, .savedToSidecar)
        XCTAssertNil(store.persistenceWarning)
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

        let storePersistence = SessionPersistence(
            backupDirectory: fixture.backup
        )
        let store = SessionStore(persistence: storePersistence)
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

        let storePersistence = SessionPersistence(
            backupDirectory: fixture.backup
        )
        let store = SessionStore(persistence: storePersistence)
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

        let storePersistence = SessionPersistence(
            backupDirectory: fixture.backup
        )
        let store = SessionStore(persistence: storePersistence)
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

    func testFolderReplacementAfterSaveLockCannotTouchEitherLineage() async throws {
        let fixture = try makeFixture(named: "FolderSwapAfterLock")
        let lockAcquired = DispatchSemaphore(value: 0)
        let releaseSave = DispatchSemaphore(value: 0)
        defer {
            releaseSave.signal()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        let initial = SessionPersistence(backupDirectory: fixture.backup)
        let source = fixture.photos.appendingPathComponent("A.png")
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
        let backupFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.backup,
                includingPropertiesForKeys: nil
            ).first
        )
        let originalBackup = try Data(contentsOf: backupFile)

        let guarded = SessionPersistence(
            backupDirectory: fixture.backup,
            afterSaveLockAcquiredForTesting: {
                lockAcquired.signal()
                _ = releaseSave.wait(timeout: .now() + 10)
            }
        )
        let read = await guarded.read(for: fixture.photos)
        let access = try XCTUnwrap(read.access)
        session.entries[0].rating = Rating.no.rawValue
        let saving = Task {
            await guarded.save(
                session,
                for: fixture.photos,
                sequence: 1,
                access: access
            )
        }
        let acquired = await waitForSemaphore(lockAcquired)
        XCTAssertEqual(acquired, .success)

        let originalFolder = fixture.root.appendingPathComponent(
            "Original Photos",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: fixture.photos, to: originalFolder)
        let originalSidecar = try Data(
            contentsOf: originalFolder.appendingPathComponent(
                SessionConstants.sidecarName
            )
        )
        try FileManager.default.createDirectory(
            at: fixture.photos,
            withIntermediateDirectories: true
        )
        let replacementSidecar = fixture.photos.appendingPathComponent(
            SessionConstants.sidecarName
        )
        let sentinel = Data("replacement session".utf8)
        try sentinel.write(to: replacementSidecar)

        releaseSave.signal()
        let saveResult = await saving.value
        XCTAssertEqual(saveResult, .sourceFolderChanged)
        XCTAssertEqual(try Data(contentsOf: replacementSidecar), sentinel)
        XCTAssertEqual(
            try Data(
                contentsOf: originalFolder.appendingPathComponent(
                    SessionConstants.sidecarName
                )
            ),
            originalSidecar
        )
        XCTAssertEqual(try Data(contentsOf: backupFile), originalBackup)
    }

    func testNonDirectoryAncestorIsAReplacementNotAnOfflineVolume() async throws {
        let fixture = try makeFixture(named: "NonDirectoryAncestor")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let mount = fixture.root.appendingPathComponent("Card", isDirectory: true)
        let photos = mount.appendingPathComponent("DCIM", isDirectory: true)
        try FileManager.default.createDirectory(
            at: photos,
            withIntermediateDirectories: true
        )
        let source = photos.appendingPathComponent("A.png")
        try FileManager.default.moveItem(
            at: fixture.photos.appendingPathComponent("A.png"),
            to: source
        )
        let persistence = SessionPersistence(backupDirectory: fixture.backup)
        var session = currentSession(
            folder: photos,
            file: source,
            rating: .yes
        )
        let initialResult = await persistence.save(
            session,
            for: photos,
            sequence: 1
        )
        XCTAssertEqual(initialResult, .savedToSidecar)
        let read = await persistence.read(for: photos)
        let access = try XCTUnwrap(read.access)
        let backupFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.backup,
                includingPropertiesForKeys: nil
            ).first
        )
        let originalBackup = try Data(contentsOf: backupFile)

        let disconnectedMount = fixture.root.appendingPathComponent(
            "Card Away",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: mount, to: disconnectedMount)
        let sentinel = Data("not a mounted card".utf8)
        try sentinel.write(to: mount)
        session.entries[0].rating = Rating.no.rawValue

        let result = await persistence.save(
            session,
            for: photos,
            sequence: 2,
            access: access
        )
        XCTAssertEqual(result, .sourceFolderChanged)
        XCTAssertEqual(try Data(contentsOf: mount), sentinel)
        XCTAssertEqual(try Data(contentsOf: backupFile), originalBackup)
        XCTAssertEqual(
            try readSession(
                at: disconnectedMount
                    .appendingPathComponent("DCIM", isDirectory: true)
                    .appendingPathComponent(SessionConstants.sidecarName)
            ).entries.first?.rating,
            Rating.yes.rawValue
        )
    }

    func testReplacedMissingAncestorIsNotAnOfflineVolume() async throws {
        let fixture = try makeFixture(named: "SymlinkAncestor")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let mount = fixture.root.appendingPathComponent(
            "Card",
            isDirectory: true
        )
        let photos = mount.appendingPathComponent("DCIM", isDirectory: true)
        try FileManager.default.createDirectory(
            at: photos,
            withIntermediateDirectories: true
        )
        let source = photos.appendingPathComponent("A.png")
        try FileManager.default.moveItem(
            at: fixture.photos.appendingPathComponent("A.png"),
            to: source
        )
        let persistence = SessionPersistence(backupDirectory: fixture.backup)
        var session = currentSession(
            folder: photos,
            file: source,
            rating: .yes
        )
        let initialResult = await persistence.save(
            session,
            for: photos,
            sequence: 1
        )
        XCTAssertEqual(initialResult, .savedToSidecar)
        let read = await persistence.read(for: photos)
        let access = try XCTUnwrap(read.access)
        let backupFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.backup,
                includingPropertiesForKeys: nil
            ).first
        )
        let originalBackup = try Data(contentsOf: backupFile)
        let disconnectedMount = fixture.root.appendingPathComponent(
            "Card Away",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: mount, to: disconnectedMount)
        try FileManager.default.createDirectory(
            at: mount,
            withIntermediateDirectories: false
        )
        session.entries[0].rating = Rating.no.rawValue

        let directoryReplacement = await persistence.save(
            session,
            for: photos,
            sequence: 2,
            access: access
        )
        XCTAssertEqual(directoryReplacement, .sourceFolderChanged)
        XCTAssertEqual(try Data(contentsOf: backupFile), originalBackup)

        try FileManager.default.removeItem(at: mount)
        let missingTarget = fixture.root.appendingPathComponent(
            "Missing Card",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: mount,
            withDestinationURL: missingTarget
        )

        let result = await persistence.save(
            session,
            for: photos,
            sequence: 3,
            access: access
        )

        XCTAssertEqual(result, .sourceFolderChanged)
        XCTAssertEqual(try Data(contentsOf: backupFile), originalBackup)
        XCTAssertEqual(
            try readSession(
                at: disconnectedMount
                    .appendingPathComponent("DCIM", isDirectory: true)
                    .appendingPathComponent(SessionConstants.sidecarName)
            ).entries.first?.rating,
            Rating.yes.rawValue
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: mount.path
            ),
            missingTarget.path
        )
    }

    func testUUIDOwnedFolderStillMatchesAfterDeviceNumberChanges() throws {
        let fixture = try makeFixture(named: "RemountedDeviceNumber")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let identity = try SessionPersistence.SourceFolderIdentity.capture(
            at: fixture.photos
        )
        guard identity.volumeUUIDString != nil else {
            throw XCTSkip(
                "the test volume has no UUID, so st_dev is its required fallback"
            )
        }
        let replacement = identity.systemNumber == UInt64.max
            ? identity.systemNumber - 1
            : identity.systemNumber + 1
        let remounted = identity.remappingSourceSystemNumberForTesting(
            to: replacement
        )

        XCTAssertNotEqual(remounted.systemNumber, identity.systemNumber)
        XCTAssertEqual(remounted, identity)
        XCTAssertTrue(
            remounted.matches(folder: fixture.photos),
            "a UUID-owned card must retain its folder identity across st_dev reassignment"
        )
    }

    func testChangedDeviceWithMissingFolderCannotAdvanceOfflineBackup() async throws {
        let fixture = try makeFixture(named: "DifferentCardMissingFolder")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let persistence = SessionPersistence(backupDirectory: fixture.backup)
        let source = fixture.photos.appendingPathComponent("A.png")
        var session = currentSession(
            folder: fixture.photos,
            file: source,
            rating: .yes
        )
        let baselineResult = await persistence.save(
            session,
            for: fixture.photos,
            sequence: 1
        )
        XCTAssertEqual(baselineResult, .savedToSidecar)
        let read = await persistence.read(for: fixture.photos)
        let access = try XCTUnwrap(read.access)
        guard access.folderIdentity.volumeUUIDString != nil else {
            throw XCTSkip(
                "the test volume has no UUID, so st_dev is its required fallback"
            )
        }
        let replacementDevice = access.folderIdentity.systemNumber
            == UInt64.max
            ? access.folderIdentity.systemNumber - 1
            : access.folderIdentity.systemNumber + 1
        let remappedIdentity = access.folderIdentity
            .remappingSourceSystemNumberForTesting(to: replacementDevice)
        let remappedAccess = SessionPersistence.AccessContext(
            id: access.id,
            folderIdentity: remappedIdentity,
            sidecarRevision: access.sidecarRevision,
            backupRevision: access.backupRevision,
            initialSnapshotGeneration: access.initialSnapshotGeneration
        )
        let backup = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.backup,
                includingPropertiesForKeys: nil
            ).first
        )
        let originalBackup = try Data(contentsOf: backup)
        let disconnectedFolder = fixture.root.appendingPathComponent(
            "Original Card",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: fixture.photos,
            to: disconnectedFolder
        )
        session.entries[0].rating = Rating.no.rawValue

        let result = await persistence.save(
            session,
            for: fixture.photos,
            sequence: 2,
            access: remappedAccess
        )

        XCTAssertEqual(result, .sourceFolderChanged)
        XCTAssertEqual(
            try Data(contentsOf: backup),
            originalBackup,
            "an ambiguous missing path must not advance the original card's backup"
        )
    }

    func testDisconnectedFolderSavesLatestRatingsToIdentityBackup() async throws {
        let fixture = try makeFixture(named: "DisconnectedFolderBackup")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let persistence = SessionPersistence(backupDirectory: fixture.backup)
        let source = fixture.photos.appendingPathComponent("A.png")
        var session = currentSession(
            folder: fixture.photos,
            file: source,
            rating: .yes
        )
        let initialSave = await persistence.save(
            session,
            for: fixture.photos,
            sequence: 1
        )
        XCTAssertEqual(initialSave, .savedToSidecar)
        let sidecarName = SessionConstants.sidecarName
        let originalSidecar = try Data(
            contentsOf: fixture.photos.appendingPathComponent(sidecarName)
        )
        let read = await persistence.read(for: fixture.photos)
        let access = try XCTUnwrap(read.access)

        // Model an ejected card: the exact opened path is absent, while the
        // identity-keyed Application Support backup remains available.
        let disconnectedFolder = fixture.root.appendingPathComponent(
            "Disconnected Photos",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: fixture.photos,
            to: disconnectedFolder
        )
        session.entries[0].rating = Rating.no.rawValue

        let offlineSave = await persistence.save(
            session,
            for: fixture.photos,
            sequence: 2,
            access: access
        )
        XCTAssertEqual(
            offlineSave,
            .savedToBackup(sidecarFailure: .volumeUnavailable)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.photos.path),
            "an offline backup save must not recreate the disconnected path"
        )
        XCTAssertEqual(
            try Data(
                contentsOf: disconnectedFolder.appendingPathComponent(
                    sidecarName
                )
            ),
            originalSidecar,
            "an offline backup save must not alter the card's sidecar"
        )
        let backup = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.backup,
                includingPropertiesForKeys: nil
            ).first
        )
        XCTAssertEqual(
            try readSession(at: backup).entries.first?.rating,
            Rating.no.rawValue
        )
        XCTAssertEqual(try readSession(at: backup).snapshotGeneration, 2)

        try FileManager.default.moveItem(
            at: disconnectedFolder,
            to: fixture.photos
        )
        let reopened = await SessionPersistence(
            backupDirectory: fixture.backup
        ).read(for: fixture.photos)
        XCTAssertEqual(reopened.origin, .backup)
        XCTAssertEqual(
            reopened.session?.entries.first?.rating,
            Rating.no.rawValue
        )
    }

    func testReconnectWithExternalSidecarEditAbortsOfflineBackupCommit() async throws {
        let fixture = try makeFixture(named: "ReconnectDuringOfflineSave")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.photos.appendingPathComponent("A.png")
        var session = currentSession(
            folder: fixture.photos,
            file: source,
            rating: .yes
        )
        let baseline = SessionPersistence(backupDirectory: fixture.backup)
        let baselineResult = await baseline.save(
            session,
            for: fixture.photos,
            sequence: 1
        )
        XCTAssertEqual(baselineResult, .savedToSidecar)

        let reader = SessionPersistence(backupDirectory: fixture.backup)
        let read = await reader.read(for: fixture.photos)
        let access = try XCTUnwrap(read.access)
        let backup = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.backup,
                includingPropertiesForKeys: nil
            ).first
        )
        let originalBackup = try Data(contentsOf: backup)
        let disconnectedFolder = fixture.root.appendingPathComponent(
            "Disconnected Photos",
            isDirectory: true
        )
        let originalFolder = fixture.photos
        let sidecar = originalFolder.appendingPathComponent(
            SessionConstants.sidecarName
        )
        let externalEdit = Data("external sidecar edit".utf8)
        let reconnectOnce = OneShotFlag()
        let persistence = SessionPersistence(
            backupDirectory: fixture.backup,
            beforeBackupValidationForTesting: {
                guard reconnectOnce.take() else { return }
                try FileManager.default.moveItem(
                    at: disconnectedFolder,
                    to: originalFolder
                )
                try externalEdit.write(to: sidecar, options: .atomic)
            }
        )
        // Use the access captured before disconnecting so this save is bound
        // to the exact original directory identity.
        try FileManager.default.moveItem(
            at: originalFolder,
            to: disconnectedFolder
        )
        session.entries[0].rating = Rating.no.rawValue

        let result = await persistence.save(
            session,
            for: originalFolder,
            sequence: 1,
            access: access
        )

        XCTAssertEqual(result, .sidecarChanged)
        XCTAssertEqual(try Data(contentsOf: sidecar), externalEdit)
        XCTAssertEqual(
            try Data(contentsOf: backup),
            originalBackup,
            "reconnecting with an external edit must leave the backup lineage untouched"
        )
    }

    func testOfflineBackupAdoptsACommittedRenameAfterTrailingError() async throws {
        let fixture = try makeFixture(named: "OfflineBackupRenameCommit")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.photos.appendingPathComponent("A.png")
        var session = currentSession(
            folder: fixture.photos,
            file: source,
            rating: .yes
        )
        let baseline = SessionPersistence(backupDirectory: fixture.backup)
        let baselineResult = await baseline.save(
            session,
            for: fixture.photos,
            sequence: 1
        )
        XCTAssertEqual(baselineResult, .savedToSidecar)

        let persistence = SessionPersistence(
            backupDirectory: fixture.backup,
            afterBackupReplaceForTesting: {
                throw CocoaError(.fileWriteUnknown)
            }
        )
        let read = await persistence.read(for: fixture.photos)
        let access = try XCTUnwrap(read.access)
        let disconnectedFolder = fixture.root.appendingPathComponent(
            "Disconnected Photos",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: fixture.photos,
            to: disconnectedFolder
        )

        session.entries[0].rating = Rating.no.rawValue
        let firstOfflineSave = await persistence.save(
            session,
            for: fixture.photos,
            sequence: 1,
            access: access
        )
        XCTAssertEqual(
            firstOfflineSave,
            .savedToBackup(sidecarFailure: .volumeUnavailable)
        )

        // A second save on the same access proves the first committed backup
        // advanced the in-memory CAS revision instead of making Retry collide
        // with Louppe's own already-renamed bytes.
        session.entries[0].rating = Rating.undecided.rawValue
        let secondOfflineSave = await persistence.save(
            session,
            for: fixture.photos,
            sequence: 2,
            access: access
        )
        XCTAssertEqual(
            secondOfflineSave,
            .savedToBackup(sidecarFailure: .volumeUnavailable)
        )
        let backup = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.backup,
                includingPropertiesForKeys: nil
            ).first
        )
        let savedBackup = try readSession(at: backup)
        XCTAssertEqual(savedBackup.snapshotGeneration, 3)
        XCTAssertEqual(
            savedBackup.entries.first?.rating,
            Rating.undecided.rawValue
        )
        XCTAssertEqual(
            try readSession(
                at: disconnectedFolder.appendingPathComponent(
                    SessionConstants.sidecarName
                )
            ).entries.first?.rating,
            Rating.yes.rawValue
        )
    }

    func testReconnectedSidecarAdoptsTheExactBackupOwnedCommit() async throws {
        let fixture = try makeFixture(named: "ReconnectAfterSidecarRename")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.photos.appendingPathComponent("A.png")
        var session = currentSession(
            folder: fixture.photos,
            file: source,
            rating: .yes
        )
        let baseline = SessionPersistence(backupDirectory: fixture.backup)
        let baselineResult = await baseline.save(
            session,
            for: fixture.photos,
            sequence: 1
        )
        XCTAssertEqual(baselineResult, .savedToSidecar)

        let disconnectedFolder = fixture.root.appendingPathComponent(
            "Disconnected Photos",
            isDirectory: true
        )
        let originalFolder = fixture.photos
        let disconnectOnce = OneShotFlag()
        let persistence = SessionPersistence(
            backupDirectory: fixture.backup,
            afterSidecarReplaceForTesting: {
                if disconnectOnce.take() {
                    try FileManager.default.moveItem(
                        at: originalFolder,
                        to: disconnectedFolder
                    )
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        )
        let read = await persistence.read(for: fixture.photos)
        let access = try XCTUnwrap(read.access)

        session.entries[0].rating = Rating.no.rawValue
        let interruptedSave = await persistence.save(
            session,
            for: fixture.photos,
            sequence: 1,
            access: access
        )
        XCTAssertEqual(
            interruptedSave,
            .savedToBackup(sidecarFailure: .volumeUnavailable)
        )
        try FileManager.default.moveItem(
            at: disconnectedFolder,
            to: fixture.photos
        )

        session.entries[0].rating = Rating.undecided.rawValue
        let repairedSave = await persistence.save(
            session,
            for: fixture.photos,
            sequence: 2,
            access: access
        )
        XCTAssertEqual(repairedSave, .savedToSidecar)
        let sidecar = try XCTUnwrap(readSidecar(in: fixture.photos))
        XCTAssertEqual(sidecar.snapshotGeneration, 3)
        XCTAssertEqual(
            sidecar.entries.first?.rating,
            Rating.undecided.rawValue
        )
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

    func testExternalRollbackToOlderBackupIsNotAdoptedAsOwnCommit() async throws {
        let fixture = try makeFixture(named: "ExternalBackupRollback")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.photos.appendingPathComponent("A.png")
        let baseline = SessionPersistence(backupDirectory: fixture.backup)
        let initialSession = currentSession(
            folder: fixture.photos,
            file: source,
            rating: .yes
        )
        let initialResult = await baseline.save(
            initialSession,
            for: fixture.photos,
            sequence: 1
        )
        XCTAssertEqual(initialResult, .savedToSidecar)
        let sidecar = fixture.photos.appendingPathComponent(
            SessionConstants.sidecarName
        )
        let backup = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.backup,
                includingPropertiesForKeys: nil
            ).first
        )
        let olderBackupBytes = try Data(contentsOf: backup)

        var newerSidecar = try readSession(at: sidecar)
        newerSidecar.entries[0].rating = Rating.no.rawValue
        newerSidecar.snapshotGeneration = 2
        try writeSession(newerSidecar, to: sidecar)
        let persistence = SessionPersistence(backupDirectory: fixture.backup)
        let read = await persistence.read(for: fixture.photos)
        XCTAssertEqual(read.origin, .sidecar)
        let access = try XCTUnwrap(read.access)

        // This is an external rollback, not a revision Louppe marked as a
        // possible post-rename commit for this access. Exact equality with the
        // older backup must therefore remain a conflict.
        try olderBackupBytes.write(to: sidecar, options: .atomic)
        var proposed = newerSidecar
        proposed.entries[0].rating = Rating.undecided.rawValue
        let result = await persistence.save(
            proposed,
            for: fixture.photos,
            sequence: 1,
            access: access
        )
        XCTAssertEqual(result, .sidecarChanged)
        XCTAssertEqual(try Data(contentsOf: sidecar), olderBackupBytes)
        XCTAssertEqual(try Data(contentsOf: backup), olderBackupBytes)
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

    func testContendedPersistenceLockReturnsInsteadOfWaitingForever() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Louppe-BoundedPersistenceLock-\(UUID().uuidString)",
            isDirectory: true
        )
        let lock = root.appendingPathComponent("session.lock")
        let holderAcquired = DispatchSemaphore(value: 0)
        let releaseHolder = DispatchSemaphore(value: 0)
        defer {
            releaseHolder.signal()
            try? FileManager.default.removeItem(at: root)
        }

        let holder = Task.detached {
            try DurableFileIO.withExclusiveFileLock(at: lock) {
                holderAcquired.signal()
                _ = releaseHolder.wait(timeout: .now() + 10)
            }
        }
        let acquisition = await waitForSemaphore(holderAcquired)
        XCTAssertEqual(acquisition, .success)

        let startedAt = DispatchTime.now().uptimeNanoseconds
        do {
            try DurableFileIO.withExclusiveFileLock(
                at: lock,
                timeout: 0.15
            ) {}
            XCTFail("the second writer unexpectedly acquired the held lock")
        } catch DurableFileIO.IOError.system(
            let operation,
            _,
            let code
        ) {
            XCTAssertEqual(operation, "wait for persistence lock")
            XCTAssertEqual(code, EWOULDBLOCK)
        } catch {
            XCTFail("unexpected lock error: \(error)")
        }
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - startedAt
        ) / 1_000_000_000
        XCTAssertGreaterThanOrEqual(
            elapsed,
            0.10,
            "contention should use the bounded retry window"
        )
        XCTAssertLessThan(
            elapsed,
            1,
            "a second Louppe process must not leave saving or Quit deadlocked"
        )

        releaseHolder.signal()
        try await holder.value
        XCTAssertNoThrow(
            try DurableFileIO.withExclusiveFileLock(
                at: lock,
                timeout: 0.15
            ) {}
        )
    }

    func testPersistenceReportsContendedLockAsBusy() async throws {
        let fixture = try makeFixture(named: "BusyPersistenceResult")
        let holderAcquired = DispatchSemaphore(value: 0)
        let releaseHolder = DispatchSemaphore(value: 0)
        defer {
            releaseHolder.signal()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let first = SessionPersistence(
            backupDirectory: fixture.backup,
            afterSaveLockAcquiredForTesting: {
                holderAcquired.signal()
                _ = releaseHolder.wait(timeout: .now() + 10)
            }
        )
        let second = SessionPersistence(backupDirectory: fixture.backup)
        let identity = try SessionPersistence.SourceFolderIdentity.capture(
            at: fixture.photos
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
        let session = currentSession(
            folder: fixture.photos,
            file: fixture.photos.appendingPathComponent("A.png"),
            rating: .yes
        )
        let holdingSave = Task {
            await first.save(
                session,
                for: fixture.photos,
                sequence: 1,
                access: firstAccess
            )
        }
        let acquisition = await waitForSemaphore(holderAcquired)
        XCTAssertEqual(acquisition, .success)

        let busyResult = await second.save(
            session,
            for: fixture.photos,
            sequence: 1,
            access: secondAccess
        )
        XCTAssertEqual(
            busyResult,
            .failed(SessionPersistence.SaveFailure(
                sidecar: .busy,
                backup: .busy
            ))
        )

        releaseHolder.signal()
        _ = await holdingSave.value
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

    func testLegacySidecarMigratesAutomaticallyWhenEveryFilenameIsPresent() async throws {
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
        let store = SessionStore(
            persistence: SessionPersistence(backupDirectory: fixture.backup)
        )

        store.openFolder(fixture.photos)
        try await waitForReadySession(store)
        let migrated = try await waitForSidecar(in: fixture.photos) {
            $0.version == SessionConstants.currentSchemaVersion
                && $0.snapshotGeneration == 1
                && $0.entries.first?.fileIdentity != nil
        }
        XCTAssertEqual(store.items.first?.rating, .yes)
        XCTAssertFalse(store.isLegacySessionMigrationConfirmationPresented)
        XCTAssertTrue(store.canExport)
        XCTAssertTrue(store.canCleanUp)
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
        XCTAssertNil(store.persistenceWarning)
        XCTAssertFalse(store.canRetryPersistence)
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

    func testUnmatchedLegacyEntryCanBeForgottenAfterExplicitConfirmation() async throws {
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

        let storePersistence = SessionPersistence(
            backupDirectory: fixture.backup
        )
        let store = SessionStore(persistence: storePersistence)
        store.openFolder(fixture.photos)
        try await waitForLegacyMigrationConfirmation(in: store)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.rating, .yes)
        XCTAssertEqual(store.legacySessionMigrationMissingFileCount, 1)
        XCTAssertTrue(store.isSessionCommandPresentationActive)
        XCTAssertFalse(store.canExport)
        XCTAssertFalse(store.canCleanUp)
        XCTAssertEqual(try Data(contentsOf: sidecar), originalSidecar)
        XCTAssertEqual(try Data(contentsOf: backupFile), originalBackup)

        let terminationSave = await store.saveSessionForTermination()
        XCTAssertNil(terminationSave)
        XCTAssertEqual(try Data(contentsOf: sidecar), originalSidecar)
        XCTAssertEqual(try Data(contentsOf: backupFile), originalBackup)

        store.closeLegacySessionWithoutMigrating()
        guard case .welcome = store.phase else {
            return XCTFail("Close Folder must leave the legacy review session")
        }
        XCTAssertEqual(store.legacySessionMigrationMissingFileCount, 0)
        XCTAssertEqual(try Data(contentsOf: sidecar), originalSidecar)
        XCTAssertEqual(try Data(contentsOf: backupFile), originalBackup)

        let migrationStore = SessionStore(persistence: storePersistence)
        migrationStore.openFolder(fixture.photos)
        try await waitForLegacyMigrationConfirmation(in: migrationStore)
        XCTAssertEqual(migrationStore.legacySessionMigrationMissingFileCount, 1)
        migrationStore.confirmLegacySessionMigration()

        let migrated = try await waitForSidecar(in: fixture.photos) {
            $0.version == SessionConstants.currentSchemaVersion
                && $0.entries.count == 1
                && $0.entries.first?.fileIdentity != nil
        }
        XCTAssertFalse(
            migrationStore.isLegacySessionMigrationConfirmationPresented
        )
        XCTAssertEqual(migrationStore.legacySessionMigrationMissingFileCount, 0)
        XCTAssertEqual(migrated.entries.first?.filename, "A.png")
        XCTAssertEqual(migrated.entries.first?.rating, Rating.yes.rawValue)
        XCTAssertFalse(migrated.entries.contains { $0.filename == "B.png" })
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

private final class OneShotFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isAvailable = true

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isAvailable else { return false }
        isAvailable = false
        return true
    }
}

private actor CompletionProbe {
    private var finished = false

    func markFinished() {
        finished = true
    }

    func isFinished() -> Bool {
        finished
    }
}

private actor GatedSessionPersistence: SessionPersistenceClient {
    private var saveCalls = 0
    private var capturedRatings: [String] = []
    private var shouldBlockSaves = true
    private var blockedSaves: [CheckedContinuation<Void, Never>] = []
    private let results: [SessionPersistence.SaveResult]

    init(
        results: [SessionPersistence.SaveResult] = [.savedToSidecar]
    ) {
        self.results = results.isEmpty ? [.savedToSidecar] : results
    }

    func save(
        _ session: SessionFile,
        for folder: URL,
        sequence: UInt64,
        access: SessionPersistence.AccessContext
    ) async -> SessionPersistence.SaveResult {
        let callIndex = saveCalls
        saveCalls += 1
        capturedRatings.append(
            session.entries.first?.rating ?? "<missing>"
        )
        if shouldBlockSaves {
            await withCheckedContinuation { continuation in
                blockedSaves.append(continuation)
            }
        }
        return results[min(callIndex, results.count - 1)]
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
