import SwiftUI

/// One consistent VoiceOver description for Browser and Grid media tiles.
///
/// The visual tile communicates several states with borders, badge shapes,
/// and color. VoiceOver needs the same information as text, plus direct
/// alternatives to the click, double-click, and modifier-click gestures.
enum MediaTileAccessibility {
    static func value(
        for item: PhotoItem,
        isCurrent: Bool,
        isSelected: Bool
    ) -> String {
        var parts = [
            mediaDescription(for: item),
            ratingDescription(for: item.ratingState),
        ]
        if isCurrent { parts.append("Current item") }
        if isSelected { parts.append("Selected") }
        return parts.joined(separator: ", ")
    }

    static func ratingDescription(
        for state: PhotoItemRatingState
    ) -> String {
        switch state {
        case .yes: return "Rated Yes"
        case .no: return "Rated No"
        case .undecided: return "Undecided"
        case .mixed: return "Mixed rating"
        }
    }

    private static func mediaDescription(for item: PhotoItem) -> String {
        if item.fileTypeLabel == "RAW + JPEG" {
            return "RAW and JPEG photo"
        }
        return "\(item.fileTypeLabel) \(item.isVideo ? "video" : "photo")"
    }
}

/// Adds a complete, gesture-free interaction surface for a media tile while
/// leaving its visual behavior to the Browser or Grid.
private struct MediaTileAccessibilityModifier: ViewModifier {
    let item: PhotoItem
    let isCurrent: Bool
    let isSelected: Bool
    let showActionTitle: String
    let show: () -> Void
    let open: () -> Void
    let rate: (Rating) -> Void
    let toggleSelection: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.displayName)
            .accessibilityValue(
                MediaTileAccessibility.value(
                    for: item,
                    isCurrent: isCurrent,
                    isSelected: isSelected
                )
            )
            .accessibilityHint("Use actions to show, open, rate, or select this item.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(
                isCurrent || isSelected ? .isSelected : []
            )
            .accessibilityAction(.default, show)
            .accessibilityAction(named: Text(showActionTitle), show)
            .accessibilityAction(named: Text("Open in Gallery"), open)
            .accessibilityAction(named: Text("Rate Yes")) {
                rate(.yes)
            }
            .accessibilityAction(named: Text("Rate No")) {
                rate(.no)
            }
            .accessibilityAction(named: Text("Clear Rating")) {
                rate(.undecided)
            }
            .accessibilityAction(
                named: Text(
                    isSelected ? "Remove from Selection" : "Add to Selection"
                ),
                toggleSelection
            )
    }
}

extension View {
    func mediaTileAccessibility(
        item: PhotoItem,
        isCurrent: Bool,
        isSelected: Bool,
        showActionTitle: String = "Show Item",
        show: @escaping () -> Void,
        open: @escaping () -> Void,
        rate: @escaping (Rating) -> Void,
        toggleSelection: @escaping () -> Void
    ) -> some View {
        modifier(
            MediaTileAccessibilityModifier(
                item: item,
                isCurrent: isCurrent,
                isSelected: isSelected,
                showActionTitle: showActionTitle,
                show: show,
                open: open,
                rate: rate,
                toggleSelection: toggleSelection
            )
        )
    }
}
