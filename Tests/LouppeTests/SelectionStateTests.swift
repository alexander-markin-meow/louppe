import XCTest
@testable import Louppe

@MainActor
final class SelectionStateTests: XCTestCase {
    func testFileOperationPreventsIdleSystemSleepUntilCompletion() {
        let store = readyStore()
        XCTAssertFalse(store.isPreventingIdleSystemSleep)

        XCTAssertTrue(store.exportWillStart(mode: .copy))
        XCTAssertTrue(store.isPreventingIdleSystemSleep)

        store.finishExport(
            mode: .copy,
            movedIDs: [],
            requiresRecovery: false
        )
        XCTAssertFalse(store.isPreventingIdleSystemSleep)
    }

    func testRangeSelectionDropsMembersHiddenByFilter() {
        let store = readyStore()
        store.setIndex(1)
        store.selectRange(to: 3)
        XCTAssertEqual(store.selectedIndices, [1, 2, 3])

        store.filter.excludedTypes = ["PNG"]

        XCTAssertEqual(store.visibleIndices, [0, 2])
        XCTAssertEqual(store.selectedIndices, [2])
        XCTAssertEqual(store.currentIndex, 2)
    }

    func testTogglingCurrentMovesAnchorToSurvivingSelection() {
        let store = readyStore()
        store.setIndex(1)

        store.toggleSelection(of: 3)
        XCTAssertEqual(store.selectedIndices, [1, 3])
        XCTAssertEqual(store.currentIndex, 1)

        store.toggleSelection(of: 1)
        XCTAssertEqual(store.selectedIndices, [3])
        XCTAssertEqual(store.currentIndex, 3)
    }

    func testBatchRatingAndUndoKeepSelectionAndIdentityRules() {
        let store = readyStore()
        store.selectRange(to: 2)

        store.rate(.yes)

        XCTAssertEqual(store.items.prefix(3).map(\.rating), [.yes, .yes, .yes])
        XCTAssertTrue(store.selectedIndices.isEmpty)
        XCTAssertEqual(store.currentIndex, 3)

        store.undo()

        XCTAssertEqual(
            store.items.prefix(3).map(\.rating),
            [.undecided, .undecided, .undecided]
        )
        XCTAssertEqual(store.currentIndex, 0)
    }

    func testPlainGridSelectionLeavesRatingUntouchedAndClearsSelection() {
        let store = readyStore()
        store.toggleRating(at: 0)
        store.selectRange(to: 2)

        GridCellActions(store: store, index: 3).selectPhoto()

        XCTAssertEqual(store.currentIndex, 3)
        XCTAssertTrue(store.selectedIndices.isEmpty)
        XCTAssertEqual(
            store.items.map(\.rating),
            [.yes, .undecided, .undecided, .undecided]
        )
    }

    func testGridRatingControlCyclesEveryStateWithoutAdvancing() {
        let store = readyStore()
        let actions = GridCellActions(store: store, index: 2)

        actions.cycleRating()
        XCTAssertEqual(store.items[2].rating, .yes)
        XCTAssertEqual(store.currentIndex, 2)

        actions.cycleRating()
        XCTAssertEqual(store.items[2].rating, .no)
        XCTAssertEqual(store.currentIndex, 2)

        actions.cycleRating()
        XCTAssertEqual(store.items[2].rating, .undecided)
        XCTAssertEqual(store.currentIndex, 2)
    }

    func testGridRatingControlCountsEveryRapidActivation() {
        let store = readyStore()
        let actions = GridCellActions(store: store, index: 2)

        actions.cycleRating()
        actions.cycleRating()

        XCTAssertEqual(store.items[2].rating, .no)
        XCTAssertEqual(store.currentIndex, 2)
    }

    func testGridRatingControlDoesNotMutateWhileRatingIsUnavailable() {
        let store = readyStore()
        let actions = GridCellActions(store: store, index: 2)
        XCTAssertTrue(store.exportWillStart(mode: .copy))
        defer {
            store.finishExport(
                mode: .copy,
                movedIDs: [],
                requiresRecovery: false
            )
        }

        XCTAssertFalse(store.canRate)
        actions.cycleRating()

        XCTAssertEqual(store.items[2].rating, .undecided)
        XCTAssertEqual(store.currentIndex, 0)
    }

    func testGridRubberBandDefersToRatingAndPlayableVideoControls() {
        let tileFrame = CGRect(x: 10, y: 20, width: 170, height: 190)
        let frames = [3: tileFrame]

        XCTAssertFalse(
            GridRubberBandHitTest.shouldTrackCanvasDrag(
                startingAt: CGPoint(x: 170, y: 30),
                tileFrames: frames,
                playableVideoIndices: []
            ),
            "the top-trailing rating target must own its drag"
        )
        XCTAssertFalse(
            GridRubberBandHitTest.shouldTrackCanvasDrag(
                startingAt: CGPoint(x: 95, y: 105),
                tileFrames: frames,
                playableVideoIndices: [3]
            ),
            "a playable video's centered Play control must own its drag"
        )
        XCTAssertTrue(
            GridRubberBandHitTest.shouldTrackCanvasDrag(
                startingAt: CGPoint(x: 95, y: 105),
                tileFrames: frames,
                playableVideoIndices: []
            ),
            "the same center point remains selection canvas on a photo"
        )
        XCTAssertTrue(
            GridRubberBandHitTest.shouldTrackCanvasDrag(
                startingAt: CGPoint(x: 30, y: 90),
                tileFrames: frames,
                playableVideoIndices: [3]
            )
        )
        XCTAssertTrue(
            GridRubberBandHitTest.shouldTrackCanvasDrag(
                startingAt: CGPoint(x: 30, y: 195),
                tileFrames: frames,
                playableVideoIndices: [3]
            ),
            "the filename below the square media region remains selectable"
        )
        XCTAssertTrue(
            GridRubberBandHitTest.shouldTrackCanvasDrag(
                startingAt: CGPoint(x: 200, y: 30),
                tileFrames: frames,
                playableVideoIndices: [3]
            ),
            "gaps between tiles remain valid selection origins"
        )
    }

    func testGridPhotoClickSignalsBeforeChangingCurrentPhoto() {
        let store = readyStore()
        var currentWhenSignalled: Int?
        let actions = GridCellActions(
            store: store,
            index: 3,
            onPointerCurrentChange: {
                currentWhenSignalled = store.currentIndex
            }
        )

        actions.selectPhoto()

        XCTAssertEqual(currentWhenSignalled, 0)
        XCTAssertEqual(store.currentIndex, 3)
    }

    func testGridRatingClickSignalsOnlyWhenItMovesCurrentPhoto() {
        let store = readyStore()
        var signalCount = 0
        let actions = GridCellActions(
            store: store,
            index: 2,
            onPointerCurrentChange: {
                signalCount += 1
            }
        )

        actions.cycleRating()
        actions.cycleRating()

        XCTAssertEqual(signalCount, 1)
        XCTAssertEqual(store.currentIndex, 2)
        XCTAssertEqual(store.items[2].rating, .no)
    }

    func testGridBatchRatingDoesNotSignalCurrentPhotoChange() {
        let store = readyStore()
        store.selectRange(to: 2)
        var signalCount = 0
        let actions = GridCellActions(
            store: store,
            index: 1,
            onPointerCurrentChange: {
                signalCount += 1
            }
        )

        actions.cycleRating()

        XCTAssertEqual(signalCount, 0)
        XCTAssertEqual(store.currentIndex, 0)
        XCTAssertEqual(store.items.prefix(3).map(\.rating), [.yes, .yes, .yes])
    }

    func testGridRatingControlPreservesBatchSelectionBehavior() {
        let store = readyStore()
        store.selectRange(to: 2)

        GridCellActions(store: store, index: 1).cycleRating()

        XCTAssertEqual(store.items.prefix(3).map(\.rating), [.yes, .yes, .yes])
        XCTAssertEqual(store.selectedIndices, [0, 1, 2])
        XCTAssertEqual(store.currentIndex, 0)
    }

    func testZeroMatchFilterHasNoImplicitSelection() {
        let store = readyStore()
        store.filter.excludedTypes = ["JPEG", "PNG"]

        XCTAssertTrue(store.visibleIndices.isEmpty)
        XCTAssertTrue(store.effectiveSelection.isEmpty)

        store.rate(.no)

        XCTAssertTrue(store.items.allSatisfy { $0.rating == .undecided })
    }

    private func readyStore() -> SessionStore {
        let store = SessionStore()
        store.items = [
            makeItem("A.JPG"),
            makeItem("B.PNG"),
            makeItem("C.JPG"),
            makeItem("D.PNG"),
        ]
        store.sort = PhotoSort(key: .name, ascending: true)
        store.phase = .ready
        return store
    }

    private func makeItem(_ id: String) -> PhotoItem {
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

}
