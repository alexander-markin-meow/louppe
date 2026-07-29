import Foundation
import OSLog

/// Pure, non-observable session indexing state.
///
/// `SessionStore` remains the UI-facing source of truth, but delegates
/// structure-dependent lookup work here so sorting, filtering, grouping, and
/// navigation maps can be tested without creating a window or observable
/// object. The item array itself stays owned by `SessionStore`.
struct PreparedSessionIndex {
    private static let signposter = OSSignposter(
        subsystem: "com.alexandermarkin.louppe",
        category: "Session Index"
    )

    struct VisibleLocation: Equatable {
        let position: Int
        let groupIndex: Int
        let positionInGroup: Int
    }

    /// Stable Browser identity prepared only when visibility changes. Keeping
    /// this beside `visibleIndices` avoids rebuilding an O(N) id/index array
    /// every time a rating or loading indicator publishes the store.
    struct VisibleEntry: Identifiable, Equatable {
        let id: String
        let index: Int
    }

    private(set) var sortedIndices: [Int] = []
    private(set) var itemIndexByID: [String: Int] = [:]
    private(set) var visibleIndices: [Int] = []
    private(set) var visibleEntries: [VisibleEntry] = []
    private(set) var visibleGroups: [PhotoGroup] = []
    private(set) var visibleGroupTitles: [Int: String] = [:]
    private(set) var visibleLocations: [Int: VisibleLocation] = [:]

    mutating func rebuildItems(
        _ items: [PhotoItem],
        sort: PhotoSort
    ) {
        let interval = Self.signposter.beginInterval("Rebuild Item Index")
        defer {
            Self.signposter.endInterval("Rebuild Item Index", interval)
        }
        var indicesByID: [String: Int] = [:]
        indicesByID.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            indicesByID[item.id] = index
        }
        itemIndexByID = indicesByID
        rebuildSort(items, sort: sort)
    }

    mutating func rebuildSort(
        _ items: [PhotoItem],
        sort: PhotoSort
    ) {
        let interval = Self.signposter.beginInterval("Sort Session")
        defer {
            Self.signposter.endInterval("Sort Session", interval)
        }
        // FolderScanner and every structural reconstruction keep `items` in
        // PhotoSort() order. Reuse that physical order for the default view
        // instead of repeating the same O(N log N) localized-name sort on the
        // main actor after a scan, or when the user returns to the default.
        if sort == PhotoSort() {
            sortedIndices = Array(items.indices)
            return
        }
        sortedIndices = items.indices.sorted {
            sort.areInOrder(items[$0], items[$1])
        }
    }

    mutating func applyFilter(
        _ filter: PhotoFilter,
        to items: [PhotoItem],
        sort: PhotoSort,
        isGroupingEnabled: Bool
    ) {
        let interval = Self.signposter.beginInterval("Filter Session")
        defer {
            Self.signposter.endInterval("Filter Session", interval)
        }
        let prepared = PreparedPhotoFilter(filter)
        visibleIndices = sortedIndices.filter { prepared.matches(items[$0]) }
        rebuildGroups(
            for: items,
            sort: sort,
            isGroupingEnabled: isGroupingEnabled
        )
    }

    mutating func rebuildGroups(
        for items: [PhotoItem],
        sort: PhotoSort,
        isGroupingEnabled: Bool
    ) {
        let interval = Self.signposter.beginInterval("Build Visible Groups")
        defer {
            Self.signposter.endInterval("Build Visible Groups", interval)
        }
        visibleGroups = makeGroups(
            for: items,
            sort: sort,
            isGroupingEnabled: isGroupingEnabled
        )
        visibleEntries = visibleIndices.compactMap { index in
            guard items.indices.contains(index) else { return nil }
            return VisibleEntry(id: items[index].id, index: index)
        }

        var titles: [Int: String] = [:]
        var locations: [Int: VisibleLocation] = [:]
        locations.reserveCapacity(visibleIndices.count)
        var visiblePosition = 0
        for (groupIndex, group) in visibleGroups.enumerated() {
            if let title = group.title, let first = group.indices.first {
                titles[first] = title
            }
            for (positionInGroup, itemIndex) in group.indices.enumerated() {
                locations[itemIndex] = VisibleLocation(
                    position: visiblePosition,
                    groupIndex: groupIndex,
                    positionInGroup: positionInGroup
                )
                visiblePosition += 1
            }
        }
        visibleGroupTitles = titles
        visibleLocations = locations
    }

    func itemIndex(forID id: String) -> Int? {
        itemIndexByID[id]
    }

    func location(forItemIndex index: Int) -> VisibleLocation? {
        visibleLocations[index]
    }

    mutating func reset() {
        self = PreparedSessionIndex()
    }

    private func makeGroups(
        for items: [PhotoItem],
        sort: PhotoSort,
        isGroupingEnabled: Bool
    ) -> [PhotoGroup] {
        guard !visibleIndices.isEmpty else { return [] }
        guard isGroupingEnabled, sort.key != .name else {
            return [
                PhotoGroup(
                    id: .ungrouped,
                    title: nil,
                    indices: visibleIndices
                )
            ]
        }

        let key = sort.key
        var groups: [PhotoGroup] = []
        var run: [Int] = []
        var previousItem: PhotoItem?

        func closeRun() {
            guard let first = run.first else { return }
            let firstItem = items[first]
            groups.append(
                PhotoGroup(
                    id: key.groupID(for: firstItem),
                    title: key.groupTitle(for: firstItem),
                    indices: run
                )
            )
        }

        for index in visibleIndices {
            let item = items[index]
            if let previousItem, !key.sameGroup(previousItem, item) {
                closeRun()
                run = []
            }
            run.append(index)
            previousItem = item
        }
        closeRun()
        return groups
    }
}
