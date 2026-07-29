import SwiftUI
import AppKit

/// AppKit-backed 100% image viewport. One instance survives Gallery
/// navigation, so its normalized inspection position can be restored for the
/// next photo instead of every new SwiftUI ScrollView centering itself.
struct ActualSizeImageView: NSViewRepresentable {
    let item: PhotoItem
    let preview: NSImage?
    let showsClippingWarnings: Bool
    let viewport: ActualSizeViewport
    let onLoading: (Bool) -> Void

    func makeNSView(context: Context) -> ActualSizeScrollView {
        ActualSizeScrollView()
    }

    func updateNSView(
        _ scrollView: ActualSizeScrollView,
        context: Context
    ) {
        scrollView.configure(
            item: item,
            preview: preview,
            showsClippingWarnings: showsClippingWarnings,
            viewport: viewport,
            onLoading: onLoading
        )
    }

    static func dismantleNSView(
        _ scrollView: ActualSizeScrollView,
        coordinator: ()
    ) {
        scrollView.prepareForRemoval()
    }
}

@MainActor
final class ActualSizeScrollView: NSScrollView {
    private let canvas = ActualSizeCanvasView()
    private var sourceTask: Task<Void, Never>?
    private var currentItemID: String?
    private var sourceGeneration: UInt64 = 0
    private var appliedResetGeneration: UInt64?
    private var backingScale: CGFloat = 1
    private var isApplyingViewport = false
    private var viewport: ActualSizeViewport?
    private var onLoading: (Bool) -> Void = { _ in }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        documentView = canvas
        canvas.onTileActivityChanged = { [weak self] active in
            self?.onLoading(active)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        item: PhotoItem,
        preview: NSImage?,
        showsClippingWarnings: Bool,
        viewport: ActualSizeViewport,
        onLoading: @escaping (Bool) -> Void
    ) {
        self.viewport = viewport
        self.onLoading = onLoading
        setAccessibilityLabel("100% view of \(item.displayName)")
        setAccessibilityHelp(
            "Scroll to inspect the photo. The position follows navigation until S resets it."
        )
        canvas.onTileActivityChanged = { [weak self] active in
            self?.onLoading(active)
        }
        canvas.setPreview(preview)
        let clippingChanged = canvas.setShowsClippingWarnings(
            showsClippingWarnings
        )

        let itemChanged = currentItemID != item.id
        if itemChanged {
            captureViewport()
            currentItemID = item.id
            sourceGeneration &+= 1
            let generation = sourceGeneration
            sourceTask?.cancel()
            canvas.beginItem(key: ImagePipeline.cacheKey(for: item))
            HighResolutionImagePipeline.shared.cancelTileRequests(
                exceptSourceKey: nil
            )
            sourceTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let source = await HighResolutionImagePipeline.shared.source(
                    for: item
                )
                guard !Task.isCancelled,
                      self.sourceGeneration == generation,
                      self.currentItemID == item.id else { return }
                self.install(source: source)
            }
        }

        let resetChanged =
            appliedResetGeneration != viewport.resetGeneration
        if resetChanged {
            appliedResetGeneration = viewport.resetGeneration
            applyViewportPosition()
        } else if itemChanged, canvas.source != nil {
            applyViewportPosition()
        }
        if clippingChanged {
            canvas.updateVisibleRect(contentView.documentVisibleRect)
        }
    }

    func prepareForRemoval() {
        // S resets the viewport before SwiftUI removes this representable.
        // Do not let teardown capture the old scroll position over that reset.
        if appliedResetGeneration == viewport?.resetGeneration {
            captureViewport()
        }
        sourceTask?.cancel()
        sourceTask = nil
        sourceGeneration &+= 1
        canvas.prepareForRemoval()
        HighResolutionImagePipeline.shared.cancelTileRequests(
            exceptSourceKey: nil
        )
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        guard clipView === contentView else { return }
        if !isApplyingViewport {
            captureViewport()
        }
        canvas.updateVisibleRect(clipView.documentVisibleRect)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let retained = viewport?.position ?? .center
        let wasApplyingViewport = isApplyingViewport
        isApplyingViewport = true
        super.setFrameSize(newSize)
        updateDocumentGeometry()
        scrollToViewportPosition(retained)
        viewport?.update(position: retained)
        isApplyingViewport = wasApplyingViewport
    }

    override func layout() {
        let retained = viewport?.position ?? .center
        isApplyingViewport = true
        super.layout()
        updateDocumentGeometry()
        if let viewport {
            viewport.update(position: retained)
        }
        scrollToViewportPosition(retained)
        isApplyingViewport = false
        canvas.updateVisibleRect(contentView.documentVisibleRect)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let retained = viewport?.position ?? .center
        isApplyingViewport = true
        updateBackingScale()
        updateDocumentGeometry()
        scrollToViewportPosition(retained)
        viewport?.update(position: retained)
        isApplyingViewport = false
        canvas.updateVisibleRect(contentView.documentVisibleRect)
    }

    private func install(source: ZoomImageSource?) {
        let retained = viewport?.position ?? .center
        isApplyingViewport = true
        updateBackingScale()
        canvas.setSource(source, backingScale: backingScale)
        updateDocumentGeometry()
        scrollToViewportPosition(retained)
        viewport?.update(position: retained)
        isApplyingViewport = false
        canvas.updateVisibleRect(contentView.documentVisibleRect)
    }

    private func updateBackingScale() {
        backingScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        canvas.setBackingScale(backingScale)
    }

    private func updateDocumentGeometry() {
        let viewportSize = contentSize
        let imageSize = canvas.source.map {
            ActualSizeGeometry.documentSize(
                sourcePixels: $0.pixelSize,
                backingScale: backingScale
            )
        } ?? .zero
        let documentSize = CGSize(
            width: max(imageSize.width, viewportSize.width),
            height: max(imageSize.height, viewportSize.height)
        )
        canvas.updateGeometry(
            imageSize: imageSize,
            documentSize: documentSize
        )
    }

    private func applyViewportPosition() {
        scrollToViewportPosition(viewport?.position ?? .center)
    }

    private func scrollToViewportPosition(
        _ position: NormalizedImagePosition
    ) {
        guard canvas.source != nil else { return }
        let offset = ActualSizeGeometry.contentOffset(
            for: position,
            documentSize: canvas.imageSize,
            viewportSize: contentSize
        )
        let wasApplyingViewport = isApplyingViewport
        isApplyingViewport = true
        contentView.scroll(to: offset)
        super.reflectScrolledClipView(contentView)
        isApplyingViewport = wasApplyingViewport
    }

    private func captureViewport() {
        guard let viewport, canvas.source != nil else { return }
        let position = ActualSizeGeometry.normalizedPosition(
            contentOffset: contentView.bounds.origin,
            documentSize: canvas.imageSize,
            viewportSize: contentSize,
            preserving: viewport.position
        )
        viewport.update(position: position)
    }
}

@MainActor
private final class ActualSizeCanvasView: NSView {
    private struct DisplayTile {
        let image: NSImage
        let pixelRect: CGRect
    }

    override var isFlipped: Bool { true }

    private(set) var source: ZoomImageSource?
    private(set) var imageSize: CGSize = .zero
    var onTileActivityChanged: (Bool) -> Void = { _ in }

    private var itemKey: String?
    private var preview: NSImage?
    private var backingScale: CGFloat = 1
    private var imageFrame: CGRect = .zero
    private var tiles: [ZoomTileCoordinate: DisplayTile] = [:]
    private var pending: Set<ZoomTileCoordinate> = []
    private var wanted: Set<ZoomTileCoordinate> = []
    private var generation: UInt64 = 0
    private var reportsTileActivity = false
    private var showsClippingWarnings = false

    func beginItem(key: String) {
        guard itemKey != key else { return }
        stopReportingActivity()
        itemKey = key
        source = nil
        tiles = [:]
        pending = []
        wanted = []
        imageSize = .zero
        imageFrame = bounds
        generation &+= 1
        needsDisplay = true
    }

    func setPreview(_ preview: NSImage?) {
        guard self.preview !== preview else { return }
        self.preview = preview
        needsDisplay = true
    }

    @discardableResult
    func setShowsClippingWarnings(_ value: Bool) -> Bool {
        guard showsClippingWarnings != value else { return false }
        stopReportingActivity()
        showsClippingWarnings = value
        tiles = [:]
        pending = []
        wanted = []
        generation &+= 1
        HighResolutionImagePipeline.shared.cancelTileRequests(
            exceptSourceKey: nil
        )
        needsDisplay = true
        return true
    }

    func setSource(
        _ source: ZoomImageSource?,
        backingScale: CGFloat
    ) {
        self.source = source
        self.backingScale = validScale(backingScale)
        tiles = [:]
        pending = []
        wanted = []
        generation &+= 1
        needsDisplay = true
    }

    func setBackingScale(_ value: CGFloat) {
        let scale = validScale(value)
        guard scale != backingScale else { return }
        backingScale = scale
        // Tiles are keyed and stored in source pixels, so a display-scale
        // change only alters their point-space destination rectangles.
        needsDisplay = true
    }

    func updateGeometry(imageSize: CGSize, documentSize: CGSize) {
        self.imageSize = imageSize
        if frame.size != documentSize {
            setFrameSize(documentSize)
        }
        let nextImageFrame = CGRect(
            x: max((documentSize.width - imageSize.width) / 2, 0),
            y: max((documentSize.height - imageSize.height) / 2, 0),
            width: imageSize.width,
            height: imageSize.height
        )
        guard imageFrame != nextImageFrame else { return }
        imageFrame = nextImageFrame
        needsDisplay = true
    }

    func updateVisibleRect(_ visibleRect: CGRect) {
        guard let source, imageFrame.width > 0, imageFrame.height > 0
        else { return }
        let intersection = visibleRect.intersection(imageFrame)
        guard !intersection.isNull, !intersection.isEmpty else { return }
        let sourceRect = CGRect(
            x: (intersection.minX - imageFrame.minX) * backingScale,
            y: (intersection.minY - imageFrame.minY) * backingScale,
            width: intersection.width * backingScale,
            height: intersection.height * backingScale
        )
        let tilePixels = CGFloat(HighResolutionImagePipeline.tilePixelSize)
        let maximumColumn = max(
            Int(ceil(source.pixelSize.width / tilePixels)) - 1,
            0
        )
        let maximumRow = max(
            Int(ceil(source.pixelSize.height / tilePixels)) - 1,
            0
        )
        let firstColumn = max(Int(floor(sourceRect.minX / tilePixels)) - 1, 0)
        let lastColumn = min(
            Int(floor(max(sourceRect.maxX - 1, 0) / tilePixels)) + 1,
            maximumColumn
        )
        let firstRow = max(Int(floor(sourceRect.minY / tilePixels)) - 1, 0)
        let lastRow = min(
            Int(floor(max(sourceRect.maxY - 1, 0) / tilePixels)) + 1,
            maximumRow
        )
        var coordinates: Set<ZoomTileCoordinate> = []
        if firstColumn <= lastColumn, firstRow <= lastRow {
            for row in firstRow...lastRow {
                for column in firstColumn...lastColumn {
                    coordinates.insert(
                        ZoomTileCoordinate(column: column, row: row)
                    )
                }
            }
        }
        wanted = coordinates
        tiles = tiles.filter { coordinates.contains($0.key) }
        HighResolutionImagePipeline.shared.retainTileRequests(
            sourceKey: source.key,
            coordinates: coordinates,
            showsClippingWarnings: showsClippingWarnings
        )
        requestMissingTiles(source: source)
    }

    func prepareForRemoval() {
        stopReportingActivity()
        generation &+= 1
        pending = []
        wanted = []
        tiles = [:]
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if source == nil {
            drawPreviewFitted()
            return
        }
        if let preview {
            NSGraphicsContext.current?.imageInterpolation = .high
            preview.draw(
                in: imageFrame,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }
        NSGraphicsContext.current?.imageInterpolation = .none
        for tile in tiles.values {
            let rect = CGRect(
                x: imageFrame.minX + tile.pixelRect.minX / backingScale,
                y: imageFrame.minY + tile.pixelRect.minY / backingScale,
                width: tile.pixelRect.width / backingScale,
                height: tile.pixelRect.height / backingScale
            )
            guard rect.intersects(dirtyRect) else { continue }
            tile.image.draw(
                in: rect,
                from: .zero,
                operation: .copy,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.none]
            )
        }
    }

    private func drawPreviewFitted() {
        guard let preview else { return }
        let sourceSize = preview.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return }
        let scale = min(
            bounds.width / sourceSize.width,
            bounds.height / sourceSize.height
        )
        let size = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        let rect = CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        NSGraphicsContext.current?.imageInterpolation = .high
        preview.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    private func requestMissingTiles(source: ZoomImageSource) {
        let missing = wanted.subtracting(tiles.keys).subtracting(pending)
        guard !missing.isEmpty else {
            updateActivityReport()
            return
        }
        pending.formUnion(missing)
        updateActivityReport()
        let requestGeneration = generation
        for coordinate in missing {
            Task { @MainActor [weak self] in
                let tile = await HighResolutionImagePipeline.shared.tile(
                    for: source,
                    coordinate: coordinate,
                    showsClippingWarnings: self?.showsClippingWarnings ?? false
                )
                guard let self else { return }
                guard self.generation == requestGeneration else { return }
                self.pending.remove(coordinate)
                defer { self.updateActivityReport() }
                guard self.source?.key == source.key,
                      self.wanted.contains(coordinate),
                      let tile else { return }
                let pointSize = CGSize(
                    width: tile.pixelRect.width / self.backingScale,
                    height: tile.pixelRect.height / self.backingScale
                )
                self.tiles[coordinate] = DisplayTile(
                    image: NSImage(cgImage: tile.image, size: pointSize),
                    pixelRect: tile.pixelRect
                )
                let rect = CGRect(
                    x: self.imageFrame.minX
                        + tile.pixelRect.minX / self.backingScale,
                    y: self.imageFrame.minY
                        + tile.pixelRect.minY / self.backingScale,
                    width: pointSize.width,
                    height: pointSize.height
                )
                self.setNeedsDisplay(rect)
            }
        }
    }

    private func updateActivityReport() {
        let active = !pending.isEmpty
        guard active != reportsTileActivity else { return }
        reportsTileActivity = active
        onTileActivityChanged(active)
    }

    private func stopReportingActivity() {
        guard reportsTileActivity else { return }
        reportsTileActivity = false
        onTileActivityChanged(false)
    }

    private func validScale(_ value: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : 1
    }
}
