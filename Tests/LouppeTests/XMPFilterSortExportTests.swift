import Foundation
import XCTest
@testable import Louppe

final class XMPFilterSortExportTests: XCTestCase {
    func testMetadataFacetsTreatEmptyAndMixedAsIndependentValues() {
        let plain = item("PLAIN.JPG", decision: .no)
        let rated = item("RATED.JPG", decision: .yes, stars: .three, color: .red)
        let mixed = pairedItem(
            "MIXED.NEF",
            primaryDecision: .yes,
            pairedDecision: .no,
            primaryStars: .one,
            pairedStars: .five,
            primaryColor: .blue,
            pairedColor: .purple
        )

        var filter = PhotoFilter()
        filter.excludedStarStates = [.unrated]
        XCTAssertFalse(PreparedPhotoFilter(filter).matches(plain))
        XCTAssertTrue(PreparedPhotoFilter(filter).matches(rated))
        XCTAssertTrue(PreparedPhotoFilter(filter).matches(mixed))

        filter = PhotoFilter()
        filter.excludedColorStates = [.none]
        XCTAssertFalse(PreparedPhotoFilter(filter).matches(plain))
        XCTAssertTrue(PreparedPhotoFilter(filter).matches(rated))
        XCTAssertTrue(PreparedPhotoFilter(filter).matches(mixed))

        filter = PhotoFilter()
        filter.excludedDecisionStates = [.mixed]
        filter.excludedStarStates = [.stars(.three)]
        filter.excludedColorStates = [.label(.red)]
        XCTAssertTrue(filter.isActive)
        XCTAssertTrue(PreparedPhotoFilter(filter).matches(plain))
        XCTAssertFalse(PreparedPhotoFilter(filter).matches(rated))
        XCTAssertFalse(PreparedPhotoFilter(filter).matches(mixed))
        XCTAssertFalse(PhotoFilter().isActive)
    }

    func testDecisionSortAndGroupsFollowSpecifiedOrder() {
        let items = [
            item("NO.JPG", decision: .no),
            pairedItem(
                "MIXED.NEF",
                primaryDecision: .yes,
                pairedDecision: .no
            ),
            item("UNDECIDED.JPG"),
            item("YES.JPG", decision: .yes),
        ]

        let forward = PhotoSort(key: .decision, ascending: true)
        XCTAssertEqual(
            items.sorted(by: forward.areInOrder).map(\.id),
            ["YES.JPG", "UNDECIDED.JPG", "MIXED.NEF", "NO.JPG"]
        )
        let reverse = PhotoSort(key: .decision, ascending: false)
        XCTAssertEqual(
            items.sorted(by: reverse.areInOrder).map(\.id),
            ["NO.JPG", "MIXED.NEF", "UNDECIDED.JPG", "YES.JPG"]
        )

        var index = PreparedSessionIndex()
        index.rebuildItems(items, sort: forward)
        index.applyFilter(
            PhotoFilter(),
            to: items,
            sort: forward,
            isGroupingEnabled: true
        )
        XCTAssertEqual(index.visibleGroups.map(\.title), ["Yes", "Undecided", "Mixed", "No"])
        XCTAssertEqual(
            index.visibleGroups.map(\.id),
            [
                .init(key: .decision, value: .decision(.yes)),
                .init(key: .decision, value: .decision(.undecided)),
                .init(key: .decision, value: .decision(.mixed)),
                .init(key: .decision, value: .decision(.no)),
            ]
        )
    }

    func testStarsAndColorsKeepEmptyAndMixedBucketsLastInBothDirections() {
        let starItems = [
            item("UNRATED.JPG"),
            item("FIVE.JPG", stars: .five),
            pairedItem(
                "MIXED.NEF",
                primaryStars: .one,
                pairedStars: .five
            ),
            item("ONE.JPG", stars: .one),
            item("THREE.JPG", stars: .three),
        ]
        XCTAssertEqual(
            starItems.sorted(by: PhotoSort(key: .starRating, ascending: true).areInOrder).map(\.id),
            ["ONE.JPG", "THREE.JPG", "FIVE.JPG", "UNRATED.JPG", "MIXED.NEF"]
        )
        XCTAssertEqual(
            starItems.sorted(by: PhotoSort(key: .starRating, ascending: false).areInOrder).map(\.id),
            ["FIVE.JPG", "THREE.JPG", "ONE.JPG", "UNRATED.JPG", "MIXED.NEF"]
        )

        let colorItems = [
            item("NONE.JPG"),
            item("PURPLE.JPG", color: .purple),
            pairedItem(
                "MIXED.NEF",
                primaryColor: .blue,
                pairedColor: .purple
            ),
            item("RED.JPG", color: .red),
            item("GREEN.JPG", color: .green),
        ]
        XCTAssertEqual(
            colorItems.sorted(by: PhotoSort(key: .colorLabel, ascending: true).areInOrder).map(\.id),
            ["RED.JPG", "GREEN.JPG", "PURPLE.JPG", "NONE.JPG", "MIXED.NEF"]
        )
        XCTAssertEqual(
            colorItems.sorted(by: PhotoSort(key: .colorLabel, ascending: false).areInOrder).map(\.id),
            ["PURPLE.JPG", "GREEN.JPG", "RED.JPG", "NONE.JPG", "MIXED.NEF"]
        )
    }

    func testExportPredicateUsesANDAndExplicitMultiselects() {
        let exact = item("EXACT.JPG", decision: .yes, stars: .four, color: .red)
        let wrongColor = item("BLUE.JPG", decision: .yes, stars: .four, color: .blue)
        let wrongDecision = item("NO.JPG", decision: .no, stars: .four, color: .red)
        let mixedDecision = pairedItem(
            "DECISION.NEF",
            primaryDecision: .yes,
            pairedDecision: .no,
            primaryStars: .four,
            pairedStars: .four,
            primaryColor: .red,
            pairedColor: .red
        )
        let mixedStars = pairedItem(
            "STARS.NEF",
            primaryDecision: .yes,
            pairedDecision: .yes,
            primaryStars: .one,
            pairedStars: .five,
            primaryColor: .red,
            pairedColor: .red
        )
        let mixedColor = pairedItem(
            "COLOR.NEF",
            primaryDecision: .yes,
            pairedDecision: .yes,
            primaryStars: .four,
            pairedStars: .four,
            primaryColor: .red,
            pairedColor: .blue
        )
        let items = [exact, wrongColor, wrongDecision, mixedDecision, mixedStars, mixedColor]

        let exactPredicate = ExportSelectionPredicate(
            decisions: [.yes],
            starStates: [.stars(.four)],
            colorStates: [.label(.red)]
        )
        let exactSnapshot = ExportSelectionSnapshot(items: items, predicate: exactPredicate)
        XCTAssertEqual(exactSnapshot.itemIndices, [0])
        XCTAssertEqual(exactSnapshot.physicalFileCount, 1)

        let allMetadata = ExportSelectionPredicate(decisions: [.yes])
        let allSnapshot = ExportSelectionSnapshot(items: items, predicate: allMetadata)
        XCTAssertEqual(allSnapshot.itemIndices, [0, 1, 4, 5])
        XCTAssertEqual(allSnapshot.physicalFileCount, 6)
        XCTAssertEqual(allSnapshot.mixedStarsCount, 1)
        XCTAssertEqual(allSnapshot.mixedColorCount, 1)
        XCTAssertEqual(
            allMetadata.starStates,
            ExportSelectionPredicate.allStarStates
        )
        XCTAssertEqual(
            allMetadata.colorStates,
            ExportSelectionPredicate.allColorStates
        )

        let mixedAndConcrete = ExportSelectionPredicate(
            decisions: [.yes],
            starStates: [.stars(.four), .mixed],
            colorStates: [.label(.red), .mixed]
        )
        XCTAssertEqual(
            ExportSelectionSnapshot(
                items: items,
                predicate: mixedAndConcrete
            ).itemIndices,
            [0, 4, 5]
        )

        let mixedAsUndecided = ExportSelectionPredicate(
            decisions: [.undecided],
            starStates: [.stars(.four)],
            colorStates: [.label(.red)]
        )
        let mixedDecisionSnapshot = ExportSelectionSnapshot(
            items: items,
            predicate: mixedAsUndecided
        )
        XCTAssertEqual(mixedDecisionSnapshot.itemIndices, [3])
        XCTAssertEqual(mixedDecisionSnapshot.mixedDecisionCount, 1)
        XCTAssertEqual(mixedDecisionSnapshot.physicalFileCount, 2)
    }

    @MainActor
    func testMetadataMutationRefreshesActiveFilterAndSort() {
        let store = SessionStore()
        store.items = [
            item("A.JPG", decision: .yes, stars: .one),
            item("B.JPG", decision: .yes, stars: .five),
        ]
        store.rebuildDerivedDataForTesting()
        store.phase = .ready
        store.sort = PhotoSort(key: .starRating, ascending: true)
        XCTAssertEqual(store.visibleIndices, [0, 1])

        store.filter.excludedStarStates = [.unrated]
        store.currentIndex = 0
        store.setStarRating(nil)

        XCTAssertEqual(store.visibleIndices, [1])
        XCTAssertEqual(store.currentIndex, 1)

        store.resetFilter()
        XCTAssertEqual(store.visibleIndices, [1, 0])
        store.undo()
        XCTAssertEqual(store.visibleIndices, [0, 1])
    }

    private func item(
        _ id: String,
        decision: Rating = .undecided,
        stars: StarRating? = nil,
        color: PhotoColorLabel? = nil
    ) -> PhotoItem {
        PhotoItem(
            primaryFile: file(
                id,
                decision: decision,
                stars: stars,
                color: color
            )
        )
    }

    private func pairedItem(
        _ id: String,
        primaryDecision: Rating = .undecided,
        pairedDecision: Rating = .undecided,
        primaryStars: StarRating? = nil,
        pairedStars: StarRating? = nil,
        primaryColor: PhotoColorLabel? = nil,
        pairedColor: PhotoColorLabel? = nil
    ) -> PhotoItem {
        let pairedID = (id as NSString).deletingPathExtension + ".JPG"
        return PhotoItem(
            primaryFile: file(
                id,
                decision: primaryDecision,
                stars: primaryStars,
                color: primaryColor
            ),
            pairedFile: file(
                pairedID,
                decision: pairedDecision,
                stars: pairedStars,
                color: pairedColor
            )
        )
    }

    private func file(
        _ id: String,
        decision: Rating,
        stars: StarRating?,
        color: PhotoColorLabel?
    ) -> PhotoFile {
        PhotoFile(
            id: id,
            url: URL(fileURLWithPath: "/tmp/\(id)"),
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 1,
            rating: decision,
            starRating: stars,
            colorLabel: color
        )
    }
}
