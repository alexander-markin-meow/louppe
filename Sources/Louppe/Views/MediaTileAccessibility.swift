import SwiftUI

/// One consistent VoiceOver description for Browser and Grid media tiles.
///
/// The visual tile communicates several states with borders, badge shapes,
/// and color. VoiceOver needs the same information as text, plus direct
/// alternatives to the click, double-click, and modifier-click gestures.
enum MediaTileAccessibility {
    enum RatingAction: String, CaseIterable, Equatable {
        case yes = "Decide Yes"
        case no = "Decide No"
        case clear = "Clear Decision"

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
            decisionDescription(for: item.ratingState),
            starDescription(for: item.starRatingState),
            colorDescription(for: item.colorLabelState),
        ]
        if isCurrent { parts.append("Current item") }
        if isSelected { parts.append("Selected") }
        return parts.joined(separator: ", ")
    }

    static func decisionDescription(
        for state: PhotoItemRatingState
    ) -> String {
        switch state {
        case .yes: return "Decision Yes"
        case .no: return "Decision No"
        case .undecided: return "Undecided"
        case .mixed: return "Mixed decision"
        }
    }

    static func ratingDescription(for state: PhotoItemRatingState) -> String {
        decisionDescription(for: state)
    }

    static func starDescription(for state: PhotoItemStarRatingState) -> String {
        switch state {
        case .unrated: return "No stars"
        case .stars(let rating): return "\(rating.count) stars"
        case .mixed: return "Mixed stars"
        }
    }

    static func colorDescription(for state: PhotoItemColorLabelState) -> String {
        switch state {
        case .none: return "No color label"
        case .label(let label): return "\(label.displayName) color label"
        case .mixed: return "Mixed color labels"
        }
    }

    static func ratingActions(canRate: Bool) -> [RatingAction] {
        canRate ? RatingAction.allCases : []
    }

    static func actionHint(canRate: Bool) -> String {
        canRate
            ? "Use actions to show, open, change decision, stars, or color label, or select this item."
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
    let setStars: (StarRating?) -> Void
    let setColor: (PhotoColorLabel?) -> Void
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
            .modifier(
                MediaTileMetadataActionsModifier(
                    isEnabled: canRate,
                    setStars: setStars,
                    setColor: setColor
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

private struct MediaTileMetadataActionsModifier: ViewModifier {
    let isEnabled: Bool
    let setStars: (StarRating?) -> Void
    let setColor: (PhotoColorLabel?) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .accessibilityAction(named: Text("Clear Stars")) { setStars(nil) }
                .accessibilityAction(named: Text("Set 1 Star")) { setStars(.one) }
                .accessibilityAction(named: Text("Set 2 Stars")) { setStars(.two) }
                .accessibilityAction(named: Text("Set 3 Stars")) { setStars(.three) }
                .accessibilityAction(named: Text("Set 4 Stars")) { setStars(.four) }
                .accessibilityAction(named: Text("Set 5 Stars")) { setStars(.five) }
                .accessibilityAction(named: Text("Clear Color Label")) { setColor(nil) }
                .accessibilityAction(named: Text("Set Red Label")) { setColor(.red) }
                .accessibilityAction(named: Text("Set Yellow Label")) { setColor(.yellow) }
                .accessibilityAction(named: Text("Set Green Label")) { setColor(.green) }
                .accessibilityAction(named: Text("Set Blue Label")) { setColor(.blue) }
                .accessibilityAction(named: Text("Set Purple Label")) { setColor(.purple) }
        } else {
            content
        }
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
        setStars: @escaping (StarRating?) -> Void,
        setColor: @escaping (PhotoColorLabel?) -> Void,
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
                setStars: setStars,
                setColor: setColor,
                toggleSelection: toggleSelection
            )
        )
    }
}
