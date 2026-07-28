import Foundation

/// The point in an image kept under the center of the 100% viewport.
///
/// Normalized coordinates make the inspection position meaningful across
/// photos with different pixel dimensions and aspect ratios. Y is measured
/// from the top so it matches the flipped AppKit document view used by the
/// Gallery.
struct NormalizedImagePosition: Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat

    static let center = NormalizedImagePosition(x: 0.5, y: 0.5)

    init(x: CGFloat, y: CGFloat) {
        self.x = Self.clamp(x)
        self.y = Self.clamp(y)
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }
}

/// Pure geometry shared by the AppKit viewport and focused regression tests.
enum ActualSizeGeometry {
    static func documentSize(
        sourcePixels: CGSize,
        backingScale: CGFloat
    ) -> CGSize {
        let scale = validBackingScale(backingScale)
        return CGSize(
            width: max(sourcePixels.width, 0) / scale,
            height: max(sourcePixels.height, 0) / scale
        )
    }

    static func contentOffset(
        for position: NormalizedImagePosition,
        documentSize: CGSize,
        viewportSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: offset(
                normalized: position.x,
                documentLength: documentSize.width,
                viewportLength: viewportSize.width
            ),
            y: offset(
                normalized: position.y,
                documentLength: documentSize.height,
                viewportLength: viewportSize.height
            )
        )
    }

    /// Updates only scrollable axes. A small portrait photo may be centered
    /// horizontally, but it must not erase the photographer's preferred X
    /// position before the next large landscape photo arrives.
    static func normalizedPosition(
        contentOffset: CGPoint,
        documentSize: CGSize,
        viewportSize: CGSize,
        preserving previous: NormalizedImagePosition
    ) -> NormalizedImagePosition {
        var x = previous.x
        var y = previous.y
        if documentSize.width > viewportSize.width, documentSize.width > 0 {
            x = (contentOffset.x + viewportSize.width / 2)
                / documentSize.width
        }
        if documentSize.height > viewportSize.height, documentSize.height > 0 {
            y = (contentOffset.y + viewportSize.height / 2)
                / documentSize.height
        }
        return NormalizedImagePosition(x: x, y: y)
    }

    private static func offset(
        normalized: CGFloat,
        documentLength: CGFloat,
        viewportLength: CGFloat
    ) -> CGFloat {
        guard documentLength > viewportLength else { return 0 }
        let proposed = normalized * documentLength - viewportLength / 2
        return min(max(proposed, 0), documentLength - viewportLength)
    }

    private static func validBackingScale(_ value: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : 1
    }
}

/// Non-published interaction state for 100% viewing.
///
/// Scroll-wheel events can arrive many times per frame. Keeping this outside
/// `@Published` prevents a pan from rebuilding the Browser, toolbar, and
/// metadata panel. A current-item publication still causes the persistent
/// AppKit viewport to read and apply the latest position.
@MainActor
final class ActualSizeViewport {
    private(set) var position: NormalizedImagePosition = .center
    private(set) var resetGeneration: UInt64 = 0

    func update(position: NormalizedImagePosition) {
        self.position = position
    }

    func reset() {
        position = .center
        resetGeneration &+= 1
    }
}
