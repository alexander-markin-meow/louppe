import Foundation

/// Pure selection authority behind `SessionStore`.
///
/// Numeric indices are the fast render-facing projection for the current item
/// generation. Item IDs are the durable authority used when a rescan or
/// structural operation rebuilds that generation.
struct SelectionState: Equatable {
    private(set) var indices: Set<Int> = []
    private(set) var itemIDs: Set<String> = []

    /// Replaces the selection, drops indices outside the current generation,
    /// and refreshes the stable-ID projection. Returns whether views need a
    /// selection publication.
    @discardableResult
    mutating func replace(
        with candidates: Set<Int>,
        items: [PhotoItem]
    ) -> Bool {
        let valid = Set(candidates.filter { items.indices.contains($0) })
        itemIDs = Set(valid.map { items[$0].id })
        guard indices != valid else { return false }
        indices = valid
        return true
    }

    @discardableResult
    mutating func clear(items: [PhotoItem]) -> Bool {
        replace(with: [], items: items)
    }

    func effectiveSelection(
        currentIndex: Int,
        visibleIndices: [Int],
        itemCount: Int
    ) -> Set<Int> {
        if !indices.isEmpty { return indices }
        guard !visibleIndices.isEmpty,
              (0..<itemCount).contains(currentIndex) else { return [] }
        return [currentIndex]
    }

    @discardableResult
    mutating func retainVisible(
        items: [PhotoItem],
        preparedIndex: PreparedSessionIndex
    ) -> Bool {
        replace(
            with: Set(indices.filter {
                preparedIndex.location(forItemIndex: $0) != nil
            }),
            items: items
        )
    }

    /// Remaps a stable selection into a newly scanned/reordered item
    /// generation. Returns a replacement current index when the old current
    /// photo no longer lies inside the restored explicit selection.
    @discardableResult
    mutating func restore(
        itemIDs desiredItemIDs: Set<String>,
        items: [PhotoItem],
        preparedIndex: PreparedSessionIndex,
        visibleOnly: Bool,
        currentIndex: Int
    ) -> Int? {
        var remapped = Set(
            desiredItemIDs.compactMap { preparedIndex.itemIndex(forID: $0) }
        )
        if visibleOnly {
            remapped = Set(remapped.filter {
                preparedIndex.location(forItemIndex: $0) != nil
            })
        }
        replace(with: remapped, items: items)
        guard !remapped.isEmpty, !remapped.contains(currentIndex) else {
            return nil
        }
        return remapped.min {
            (preparedIndex.location(forItemIndex: $0)?.position ?? $0)
                < (preparedIndex.location(forItemIndex: $1)?.position ?? $1)
        }
    }

    @discardableResult
    mutating func selectRange(
        from anchorIndex: Int,
        to targetIndex: Int,
        visibleIndices: [Int],
        items: [PhotoItem],
        preparedIndex: PreparedSessionIndex
    ) -> Bool {
        guard let target =
                preparedIndex.location(forItemIndex: targetIndex)?.position
        else { return false }
        let anchor =
            preparedIndex.location(forItemIndex: anchorIndex)?.position
            ?? target
        return replace(
            with: Set(
                visibleIndices[min(anchor, target)...max(anchor, target)]
            ),
            items: items
        )
    }

    /// Toggles one item and returns a replacement current index when the
    /// former current item has just left the explicit selection.
    mutating func toggle(
        _ index: Int,
        currentIndex: Int,
        visibleIndices: [Int],
        items: [PhotoItem]
    ) -> Int? {
        guard items.indices.contains(index) else { return nil }
        var updated = effectiveSelection(
            currentIndex: currentIndex,
            visibleIndices: visibleIndices,
            itemCount: items.count
        )
        if updated.contains(index), updated.count > 1 {
            updated.remove(index)
        } else {
            updated.insert(index)
        }
        replace(
            with: updated == [currentIndex] ? [] : updated,
            items: items
        )
        guard !indices.isEmpty, !indices.contains(currentIndex) else {
            return nil
        }
        return indices.contains(index) ? index : indices.min()
    }

    @discardableResult
    mutating func selectToEdge(
        from currentIndex: Int,
        forward: Bool,
        visibleIndices: [Int],
        items: [PhotoItem],
        preparedIndex: PreparedSessionIndex
    ) -> Bool {
        guard let position =
                preparedIndex.location(forItemIndex: currentIndex)?.position
        else { return false }
        return replace(
            with: Set(
                forward
                    ? visibleIndices[position...]
                    : visibleIndices[...position]
            ),
            items: items
        )
    }

    @discardableResult
    mutating func selectAllVisible(
        _ visibleIndices: [Int],
        items: [PhotoItem]
    ) -> Bool {
        replace(with: Set(visibleIndices), items: items)
    }

    @discardableResult
    mutating func updateRubberBand(
        _ candidates: Set<Int>,
        items: [PhotoItem]
    ) -> Bool {
        replace(with: candidates, items: items)
    }

    /// The Grid deliberately leaves current alone during a drag so it cannot
    /// auto-scroll beneath the pointer. This returns the post-drag anchor.
    func committedAnchor(currentIndex: Int) -> Int? {
        guard !indices.isEmpty,
              !indices.contains(currentIndex) else { return nil }
        return indices.min()
    }
}
