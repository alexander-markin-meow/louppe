import Foundation
import XCTest
@testable import Louppe

@MainActor
final class RecoveryGatingTests: XCTestCase {
    func testUnresolvedRecoveryLeavesReviewAvailableButBlocksFileMutations() {
        let store = readyStore()
        var report = FileOperationJournal.RecoveryReport()
        report.unresolvedOperations = 1
        report.unresolvedFiles = 1
        report.details = ["The source file no longer has the expected identity."]
        store.presentOperationRecoveryReportForTesting(report)

        XCTAssertTrue(store.recoveryNeedsAttention)
        XCTAssertFalse(store.isFileOperationRunning)
        XCTAssertFalse(store.isSessionCommandPresentationActive)
        XCTAssertTrue(store.canRate)
        XCTAssertFalse(store.canExport)
        XCTAssertFalse(store.canCleanUp)
        XCTAssertFalse(store.exportWillStart(mode: .copy))

        store.setIndex(1)
        XCTAssertEqual(store.currentIndex, 1)
        store.toggleSelection(of: 2)
        XCTAssertEqual(store.selectedIndices, [1, 2])

        store.rate(.yes)
        XCTAssertEqual(store.items[1].rating, .yes)
        XCTAssertEqual(store.items[2].rating, .yes)
    }

    func testRatingUndoAboveBlockedCleanUpUndoRemainsUsable() {
        let store = readyStore()
        store.pushCleanUpUndoForTesting()

        var report = FileOperationJournal.RecoveryReport()
        report.unresolvedOperations = 1
        report.unresolvedFiles = 1
        store.presentOperationRecoveryReportForTesting(report)

        store.rate(.yes)
        XCTAssertEqual(store.items[0].rating, .yes)
        XCTAssertTrue(store.canUndo, "the newer rating remains undoable")

        store.undo()
        XCTAssertEqual(store.items[0].rating, .undecided)
        XCTAssertFalse(
            store.canUndo,
            "the retained Clean Up restore stays blocked during recovery"
        )

        store.presentOperationRecoveryReportForTesting(nil)
        XCTAssertTrue(
            store.canUndo,
            "the blocked Clean Up restore was retained for a later retry"
        )
    }

    func testRecoveryWarningOnlySuggestsReconnectForUnavailableVolume() {
        let store = readyStore()
        var mismatch = FileOperationJournal.RecoveryReport()
        mismatch.unresolvedOperations = 1
        mismatch.unresolvedFiles = 1
        mismatch.details = ["The file changed since the operation began."]
        store.presentOperationRecoveryReportForTesting(mismatch)

        let mismatchMessage = store.recoveryAttentionMessage ?? ""
        XCTAssertFalse(mismatchMessage.localizedCaseInsensitiveContains("reconnect"))
        XCTAssertTrue(mismatchMessage.contains("Copy, Move, and Clean Up are paused"))

        var unavailable = mismatch
        unavailable.unavailableVolumes = ["/Volumes/CAMERA CARD"]
        store.presentOperationRecoveryReportForTesting(unavailable)
        XCTAssertTrue(store.recoveryAttentionMessage?.contains("Reconnect") == true)
        XCTAssertTrue(store.recoveryAttentionMessage?.contains("CAMERA CARD") == true)

        var locked = FileOperationJournal.RecoveryReport()
        locked.operationLockUnavailable = true
        store.presentOperationRecoveryReportForTesting(locked)
        XCTAssertTrue(store.recoveryNeedsAttention)
        XCTAssertFalse(store.operationRecoveryReportRequiresAcknowledgement)
        XCTAssertFalse(
            store.recoveryAttentionMessage?
                .localizedCaseInsensitiveContains("reconnect") == true
        )
    }

    func testNoOpRecoveryCompletesWithoutAReport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LouppeRecoveryGating-\(UUID().uuidString)",
            isDirectory: true
        )
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        let source = root.appendingPathComponent("SOURCE.JPG")
        let destination = root.appendingPathComponent("EXPORTED.JPG")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("photo".utf8).write(to: source)

        let writer = try FileOperationJournal.start(
            kind: .exportMove,
            seeds: [
                .init(
                    itemID: "SOURCE.JPG",
                    source: source,
                    destination: destination
                ),
            ],
            directory: journals
        )
        XCTAssertTrue(FileOperationJournal.finalize(
            writer,
            operationIsConsistent: false
        ))

        let store = SessionStore(
            operationJournalDirectory: journals,
            automaticallyRecoversInterruptedOperations: true
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while store.isRecoveringInterruptedOperations, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertFalse(store.isRecoveringInterruptedOperations)
        XCTAssertFalse(store.recoveryNeedsAttention)
        XCTAssertNil(store.operationRecoveryReport)
        XCTAssertFalse(
            FileOperationJournal.hasPendingOperations(directory: journals)
        )
    }

    func testRecoveryActionsCannotRaceTermination() {
        let store = readyStore()
        var report = FileOperationJournal.RecoveryReport()
        report.unresolvedOperations = 1
        report.unresolvedFiles = 1
        store.presentOperationRecoveryReportForTesting(report)

        store.beginTerminationPreparation()
        XCTAssertFalse(store.canRetryInterruptedOperationRecovery)
        XCTAssertFalse(store.canKeepInterruptedFilesAsTheyAre)
        store.retryInterruptedOperationRecovery()
        store.keepInterruptedFilesAsTheyAre()

        XCTAssertTrue(store.recoveryNeedsAttention)
        XCTAssertFalse(store.isRecoveringInterruptedOperations)
        store.cancelTerminationPreparation()
    }

    private func readyStore() -> SessionStore {
        let store = SessionStore()
        store.items = ["A.JPG", "B.JPG", "C.JPG"].map { id in
            PhotoItem(
                id: id,
                primaryURL: URL(fileURLWithPath: "/tmp/\(id)"),
                pairedURL: nil,
                captureDate: nil,
                cameraModel: nil,
                lensModel: nil,
                fileSize: 1
            )
        }
        store.sort = PhotoSort(key: .name, ascending: true)
        store.phase = .ready
        return store
    }
}
