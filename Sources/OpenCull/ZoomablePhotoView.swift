import AppKit
import CullCore
import SwiftUI

/// Review fit, real physical-pixel 100%, and a detected face with native scroll
/// bars, trackpad scrolling and drag-to-pan. A decode failure has a terminal UI.
struct ZoomablePhotoView: View {
    let item: PhotoItem
    let recipe: EditRecipe
    let zoom: ZoomMode
    var showFaceBoxes = false
    var keyFace: Int?
    var centerAtActualSize = false
    var inspectingBurst = false
    @Environment(LibraryModel.self) private var model
    @State private var image: CGImage?
    @State private var error: String?
    @State private var representation = PreviewSource.original
    @State private var loadedKey: String?

    private var hasGeometryEdits: Bool { recipe.crop != nil || recipe.rotation != 0 }
    private var size: Int { zoom == .fit ? 2400 : 0 }
    private var renderKey: String {
        PreviewCache.versionKey(for: item, size: size, recipe: recipe) + (inspectingBurst ? "#burst-review" : "")
    }
    private var focusFace: CGRect? {
        guard zoom != .actual || centerAtActualSize else { return nil }
        guard !hasGeometryEdits, let analysis = item.analysis else { return nil }
        if let keyFace, analysis.faces.indices.contains(keyFace) { return analysis.faces[keyFace].boundingBox }
        if centerAtActualSize { return nil }
        return (analysis.significantFaces.isEmpty ? analysis.faces : analysis.significantFaces)
            .max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }?.boundingBox
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            if let image, loadedKey == renderKey {
                NativePhotoViewport(image: image, identity: renderKey, zoom: zoom, face: focusFace,
                                    faces: showFaceBoxes && !hasGeometryEdits ? item.analysis?.faces ?? [] : [],
                                    threshold: model.scoring.eyesClosedThreshold, keyFace: keyFace, name: item.fileName,
                                    frameBurstFace: inspectingBurst)
            } else if let error, loadedKey == renderKey {
                ContentUnavailableView("Preview unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                    .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if image != nil, loadedKey == renderKey {
                Text([representation.caption, reviewHint].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .task(id: renderKey) {
            let key = renderKey
            let loaded: SourcedPreview
            if inspectingBurst {
                loaded = await PreviewCache.shared.burstPreview(for: item, size: size)
            } else {
                loaded = SourcedPreview(result: await PreviewCache.shared.result(for: item, size: size, recipe: recipe), source: .original)
            }
            guard !Task.isCancelled else { return }
            representation = loaded.source
            switch loaded.result {
            case .image(let decoded): image = decoded; error = nil
            case .failure(let message): image = nil; error = message
            }
            loadedKey = key
        }
    }

    private var reviewHint: String {
        if zoom == .face && hasGeometryEdits { return "100% · Face coordinates are unavailable after crop or rotation" }
        if zoom == .face && focusFace == nil { return "100% · No detected face · Drag to pan" }
        if showFaceBoxes && hasGeometryEdits { return "Face boxes hidden after crop or rotation" }
        switch zoom { case .fit: return "Fit to window"; case .actual: return "100% · One image pixel per display pixel · Drag to pan"; case .face: return "Face detail · Drag to pan" }
    }
}

/// The backing-scale calculation is independent of AppKit layout so the 100%
/// contract is testable on both standard and Retina displays.
enum PhotoViewportGeometry {
    static func layout(image: CGSize, viewport: CGSize, backingScale: CGFloat, zoom: ZoomMode, face: CGRect?, frameBurstFace: Bool = false)
        -> (canvas: CGSize, imageRect: CGRect, center: CGPoint) {
        let width = max(1, image.width), height = max(1, image.height)
        let viewport = CGSize(width: max(1, viewport.width), height: max(1, viewport.height))
        let actual = 1 / max(1, backingScale)
        var scale = actual
        if zoom == .fit {
            scale = min(viewport.width / width, viewport.height / height)
        } else if zoom == .face, let face, face.width > 0, face.height > 0 {
            let fitFace = min(viewport.width * 0.65 / (width * face.width), viewport.height * 0.7 / (height * face.height))
            // Match framing across burst panes, even for a thumbnail or a very
            // large head. The separate actual mode always retains 1:1 pixels.
            scale = frameBurstFace ? fitFace : max(actual, min(actual * 4, fitFace))
        }
        let rendered = CGSize(width: width * scale, height: height * scale)
        let canvas = CGSize(width: max(viewport.width, rendered.width), height: max(viewport.height, rendered.height))
        let grid = max(1, backingScale)
        let x = zoom == .fit ? (canvas.width - rendered.width) / 2 : ((canvas.width - rendered.width) / 2 * grid).rounded() / grid
        let y = zoom == .fit ? (canvas.height - rendered.height) / 2 : ((canvas.height - rendered.height) / 2 * grid).rounded() / grid
        let imageRect = CGRect(x: x, y: y,
                               width: rendered.width, height: rendered.height)
        let focus = zoom == .fit ? nil : face?.center
        let center = CGPoint(x: imageRect.minX + (focus?.x ?? 0.5) * imageRect.width,
                             y: imageRect.minY + (focus?.y ?? 0.5) * imageRect.height)
        return (canvas, imageRect, center)
    }

    static func scrollOrigin(center: CGPoint, canvas: CGSize, viewport: CGSize, backingScale: CGFloat) -> CGPoint {
        let scale = max(1, backingScale)
        func offset(_ focus: CGFloat, _ extent: CGFloat, _ visible: CGFloat) -> CGFloat {
            let available = max(0, ((extent - visible) * scale).rounded(.down))
            return min(available, max(0, ((focus - visible / 2) * scale).rounded())) / scale
        }
        return CGPoint(x: offset(center.x, canvas.width, viewport.width),
                       y: offset(center.y, canvas.height, viewport.height))
    }
}

private extension CGRect { var center: CGPoint { CGPoint(x: midX, y: midY) } }

private struct NativePhotoViewport: NSViewRepresentable {
    let image: CGImage
    let identity: String
    let zoom: ZoomMode
    let face: CGRect?
    let faces: [FaceInfo]
    let threshold: Float
    let keyFace: Int?
    let name: String
    let frameBurstFace: Bool

    func makeNSView(context: Context) -> PhotoScrollView {
        let view = PhotoScrollView()
        view.hasHorizontalScroller = true; view.hasVerticalScroller = true
        view.autohidesScrollers = true; view.borderType = .noBorder
        view.drawsBackground = true; view.backgroundColor = .black
        view.usesPredominantAxisScrolling = false
        view.documentView = view.canvas
        view.canvas.setAccessibilityRole(.image)
        return view
    }
    func updateNSView(_ view: PhotoScrollView, context: Context) {
        view.configure(image: image, identity: identity, zoom: zoom, face: face,
                       faces: faces, threshold: threshold, keyFace: keyFace, name: name, frameBurstFace: frameBurstFace)
    }
}

private final class PhotoScrollView: NSScrollView {
    let canvas = PhotoCanvasView()
    private var identity = ""
    private var zoom = ZoomMode.fit
    private var frameBurstFace = false
    private var face: CGRect?
    private var needsCenter = true
    private var isLayingOutPhoto = false

    func configure(image: CGImage, identity: String, zoom: ZoomMode, face: CGRect?,
                   faces: [FaceInfo], threshold: Float, keyFace: Int?, name: String, frameBurstFace: Bool) {
        if self.identity != identity || self.zoom != zoom || self.face != face || self.frameBurstFace != frameBurstFace { needsCenter = true }
        self.frameBurstFace = frameBurstFace
        self.identity = identity; self.zoom = zoom; self.face = face
        canvas.image = image; canvas.faces = faces; canvas.threshold = threshold; canvas.keyFace = keyFace
        canvas.setAccessibilityLabel(name)
        canvas.setAccessibilityHelp(zoom == .fit ? "Photo fitted to available space" : "Scroll or drag to pan the photo")
        needsLayout = true; canvas.needsDisplay = true
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }
    override func layout() {
        super.layout()
        guard !isLayingOutPhoto, let image = canvas.image else { return }
        isLayingOutPhoto = true
        defer { isLayingOutPhoto = false }
        let viewport = contentView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        let oldRect = canvas.imageRect
        let oldCenter = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        let relative = CGPoint(x: oldRect.width > 0 ? (oldCenter.x - oldRect.minX) / oldRect.width : 0.5,
                               y: oldRect.height > 0 ? (oldCenter.y - oldRect.minY) / oldRect.height : 0.5)
        let layout = PhotoViewportGeometry.layout(image: CGSize(width: image.width, height: image.height), viewport: viewport,
                                                   backingScale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1,
                                                   zoom: zoom, face: face, frameBurstFace: frameBurstFace)
        canvas.setFrameSize(layout.canvas); canvas.imageRect = layout.imageRect
        let center = needsCenter ? layout.center : CGPoint(x: layout.imageRect.minX + relative.x * layout.imageRect.width,
                                                            y: layout.imageRect.minY + relative.y * layout.imageRect.height)
        let origin = PhotoViewportGeometry.scrollOrigin(center: center, canvas: layout.canvas, viewport: viewport,
                                                       backingScale: window?.backingScaleFactor ?? 1)
        contentView.scroll(to: origin); reflectScrolledClipView(contentView)
        needsCenter = false
    }
}

private final class PhotoCanvasView: NSView, ReviewKeyboardResponder {
    var image: CGImage?
    var imageRect = CGRect.zero
    var faces: [FaceInfo] = []
    var threshold: Float = 0.16
    var keyFace: Int?
    private var dragPoint: CGPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); dirtyRect.fill()
        guard let image else { return }
        let photo = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        photo.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.high])
        for (index, face) in faces.enumerated() {
            let box = face.boundingBox
            let rect = CGRect(x: imageRect.minX + box.minX * imageRect.width, y: imageRect.minY + box.minY * imageRect.height,
                              width: box.width * imageRect.width, height: box.height * imageRect.height)
            let color: NSColor
            switch PeopleAssessment.assess(face, eyesClosedThreshold: threshold).eyeState {
            case .unknown: color = .systemGray
            case .closed: color = .systemRed
            case .oneEyeClosed: color = .systemOrange
            case .open: color = .systemGreen
            }
            color.setStroke()
            let path = NSBezierPath(rect: rect); path.lineWidth = index == keyFace ? 4 : 2; path.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self); dragPoint = event.locationInWindow; NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let previous = dragPoint, let scroll = enclosingScrollView else { return }
        let next = event.locationInWindow
        let origin = scroll.contentView.bounds.origin
        let proposed = CGRect(origin: CGPoint(x: origin.x - (next.x - previous.x), y: origin.y + (next.y - previous.y)),
                              size: scroll.contentView.bounds.size)
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(proposed).origin)
        scroll.reflectScrolledClipView(scroll.contentView); dragPoint = next
    }
    override func mouseUp(with event: NSEvent) { dragPoint = nil; NSCursor.openHand.set() }
}
