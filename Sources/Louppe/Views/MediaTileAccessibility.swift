import SwiftUI

/// One consistent VoiceOver description for Browser and Grid media tiles.
///
/// The visual tile communicates several states with borders, badge shapes,
/// and color. VoiceOver needs the same information as text, plus direct
/// alternatives to the click, double-click, and modifier-click gestures.
enum MediaTileAccessibility {
    enum RatingAction: String, CaseIterable, Equatable {
        case yes = "Rate Yes"
        case no = "Rate No"
        case clear = "Clear Rating"

        var rating: Rating {
            switch self {
            case .yes: return .yes
            case .no: return .no
            case .clear: return .undecided
            }
        }
    }

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

    static func ratingActions(canRate: Bool) -> [RatingAction] {
        canRate ? RatingAction.allCases : []
    }

    static func actionHint(canRate: Bool) -> String {
        canRate
            ? "Use actions to show, open, rate, or select this item."
            : "Use actions to show, open, or select this item."
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
    let canRate: Bool
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
            .accessibilityHint(
                MediaTileAccessibility.actionHint(canRate: canRate)
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(
                isCurrent || isSelected ? .isSelected : []
            )
            .accessibilityAction(.default, show)
            .accessibilityAction(named: Text(showActionTitle), show)
            .accessibilityAction(named: Text("Open in Gallery"), open)
            .modifier(
                MediaTileRatingActionsModifier(
                    actions: MediaTileAccessibility.ratingActions(
                        canRate: canRate
                    ),
                    rate: rate
                )
            )
            .accessibilityAction(
                named: Text(
                    isSelected ? "Remove from Selection" : "Add to Selection"
                ),
                toggleSelection
            )
    }
}

/// Adds rating actions only while the same central `canRate` condition that
/// drives the visible controls is true. Omitting unavailable custom actions is
/// clearer to VoiceOver than presenting an action whose store guard is a no-op.
private struct MediaTileRatingActionsModifier: ViewModifier {
    let actions: [MediaTileAccessibility.RatingAction]
    let rate: (Rating) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if actions.isEmpty {
            content
        } else {
            content
                .accessibilityAction(
                    named: Text(
                        MediaTileAccessibility.RatingAction.yes.rawValue
                    )
                ) {
                    rate(MediaTileAccessibility.RatingAction.yes.rating)
                }
                .accessibilityAction(
                    named: Text(
                        MediaTileAccessibility.RatingAction.no.rawValue
                    )
                ) {
                    rate(MediaTileAccessibility.RatingAction.no.rating)
                }
                .accessibilityAction(
                    named: Text(
                        MediaTileAccessibility.RatingAction.clear.rawValue
                    )
                ) {
                    rate(MediaTileAccessibility.RatingAction.clear.rating)
                }
        }
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
        canRate: Bool,
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
                canRate: canRate,
                rate: rate,
                toggleSelection: toggleSelection
            )
        )
    }
}
