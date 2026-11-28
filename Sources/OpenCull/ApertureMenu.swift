import AppKit
import CullCore
import Observation
import SwiftUI

// The aperture menu: a camera-lens iris whose six blades are the options. Hold Space
// (release over a blade) or press ⌘K (click a blade, use arrows/Return or 1-6).

// MARK: - What the menu can do

/// Every action reachable from the aperture menu.
enum ApertureAction: String, CaseIterable, Identifiable {
    case importPhotos, cull, compare, edit, accept, albumActions
    case mergeGroup, splitGroup, resetGroups, findDuplicates, suggestTarget, retryAnalysis
    var id: String { rawValue }
}

/// The main iris, and a second iris for album actions. Each has exactly six blades.
enum AperturePage: Equatable {
    case main, albumActions

    var title: String { self == .main ? "OpenCull" : "Album actions" }

    var actions: [ApertureAction] {
        switch self {
        case .main: [.importPhotos, .cull, .compare, .edit, .accept, .albumActions]
        case .albumActions: [.mergeGroup, .splitGroup, .resetGroups, .findDuplicates, .suggestTarget, .retryAnalysis]
        }
    }
}

/// One blade of the iris, with its current availability.
struct ApertureItem: Identifiable, Equatable {
    let action: ApertureAction
    let title: String
    let symbol: String
    let isEnabled: Bool
    /// True for the workspace that is currently shown (Cull, Compare or Edit).
    let isCurrent: Bool
    /// Why the blade is unavailable, shown in the lens opening.
    let unavailableReason: String?
    var id: ApertureAction { action }

    @MainActor static func items(for page: AperturePage, model: LibraryModel) -> [ApertureItem] {
        let hasAlbum = model.folder != nil
        let busy = model.isOpening || model.isImporting || model.isExporting || model.isChoosingDestination
        let noAlbum = "Open or import an album first"
        return page.actions.map { action in
            switch action {
            case .importPhotos:
                return ApertureItem(action: action, title: "Import", symbol: "square.and.arrow.down", isEnabled: model.canImport,
                                    isCurrent: false, unavailableReason: "Wait for the current task to finish")
            case .cull, .compare, .edit:
                let mode: WorkspaceMode = action == .cull ? .cull : action == .compare ? .compare : .edit
                return ApertureItem(action: action, title: mode.title, symbol: mode.symbol, isEnabled: hasAlbum && !busy,
                                    isCurrent: hasAlbum && model.mode == mode, unavailableReason: hasAlbum ? "Busy" : noAlbum)
            case .accept:
                return ApertureItem(action: action, title: "Accept", symbol: "wand.and.stars",
                                    isEnabled: hasAlbum && !busy && !model.isAnalyzing, isCurrent: false,
                                    unavailableReason: hasAlbum ? "Wait for analysis to finish" : noAlbum)
            case .albumActions:
                return ApertureItem(action: action, title: "Album actions", symbol: "ellipsis.circle", isEnabled: hasAlbum && !busy,
                                    isCurrent: false, unavailableReason: hasAlbum ? "Busy" : noAlbum)
            case .mergeGroup:
                return ApertureItem(action: action, title: "Merge group", symbol: "rectangle.stack.badge.plus",
                                    isEnabled: hasAlbum && model.selectedItems.count >= 2, isCurrent: false,
                                    unavailableReason: "Select two or more photos")
            case .splitGroup:
                return ApertureItem(action: action, title: "Split group", symbol: "square.split.2x1",
                                    isEnabled: hasAlbum && !model.selectedItems.isEmpty, isCurrent: false,
                                    unavailableReason: "Select a photo first")
            case .resetGroups:
                return ApertureItem(action: action, title: "Reset groups", symbol: "arrow.counterclockwise", isEnabled: hasAlbum,
                                    isCurrent: false, unavailableReason: noAlbum)
            case .findDuplicates:
                return ApertureItem(action: action, title: "Duplicates", symbol: "doc.on.doc",
                                    isEnabled: hasAlbum && !model.isAnalyzing && !model.isFindingDuplicates, isCurrent: false,
                                    unavailableReason: "Wait for analysis to finish")
            case .suggestTarget:
                return ApertureItem(action: action, title: "Target \(model.targetCount)", symbol: "target",
                                    isEnabled: hasAlbum && !model.isAnalyzing, isCurrent: false,
                                    unavailableReason: "Wait for analysis to finish")
            case .retryAnalysis:
                return ApertureItem(action: action, title: "Retry analysis", symbol: "arrow.clockwise",
                                    isEnabled: hasAlbum && !model.isAnalyzing, isCurrent: false,
                                    unavailableReason: "Analysis is already running")
            }
        }
    }
}

// MARK: - Iris geometry

/// A six-blade iris. The lens opening is a regular hexagon; each blade is bounded by one
/// hexagon side extended to the rim, the next side's extension, and the rim arc between
/// them. The blades tile the lens exactly. Coordinates are relative to the lens center
/// with y pointing down (SwiftUI convention).
enum ApertureGeometry {
    static let bladeCount = 6
    /// Radius of the blade rim.
    static let radius: CGFloat = 150
    /// Width of the lens barrel ring drawn around the blades.
    static let barrelWidth: CGFloat = 14
    /// Circumradius of the hexagonal opening when the iris is fully open / closed.
    static let openRadius: CGFloat = 54
    static let closedRadius: CGFloat = 5
    /// Extra distance outside the barrel that still counts as pointing at a blade.
    static let clickTolerance: CGFloat = 24
    static var outerReach: CGFloat { radius + barrelWidth }

    private static let step = 2 * Double.pi / Double(bladeCount)

    /// Fixed rotation chosen so blade 0's label sits straight above the opening; the
    /// remaining blades follow clockwise.
    static let rotation: Double = {
        let centroid = polygonCentroid(bladePolygon(0, opening: openRadius, rotation: 0))
        return -Double.pi / 2 - Darwin.atan2(Double(centroid.y), Double(centroid.x))
    }()

    static func openingVertices(opening: CGFloat, rotation: Double = rotation) -> [CGPoint] {
        (0..<bladeCount).map { k in
            let angle = rotation + Double(k) * step
            return CGPoint(x: opening * CGFloat(Darwin.cos(angle)), y: opening * CGFloat(Darwin.sin(angle)))
        }
    }

    /// Where the extension of the opening side ending at vertex `j` meets the rim.
    private static func rimPoint(_ j: Int, vertices v: [CGPoint]) -> CGPoint {
        let a = v[(j - 1 + bladeCount) % bladeCount], b = v[j % bladeCount]
        var dx = b.x - a.x, dy = b.y - a.y
        let length = max(hypot(dx, dy), .ulpOfOne)
        dx /= length; dy /= length
        let along = b.x * dx + b.y * dy
        let t = -along + sqrt(max(0, along * along - (b.x * b.x + b.y * b.y) + radius * radius))
        return CGPoint(x: b.x + t * dx, y: b.y + t * dy)
    }

    /// Angles (radians) of the rim arc owned by blade `index`; always one sixth of the circle.
    static func rimSpan(_ index: Int, opening: CGFloat = openRadius) -> (start: Double, end: Double) {
        let v = openingVertices(opening: opening)
        let p0 = rimPoint(index, vertices: v), p1 = rimPoint(index + 1, vertices: v)
        let start = Darwin.atan2(Double(p0.y), Double(p0.x))
        var end = Darwin.atan2(Double(p1.y), Double(p1.x))
        while end <= start { end += 2 * .pi }
        return (start, end)
    }

    /// The blade outline as a polygon (the rim arc is sampled).
    static func bladePolygon(_ index: Int, opening: CGFloat, rotation: Double = rotation, arcSamples: Int = 24) -> [CGPoint] {
        let v = openingVertices(opening: opening, rotation: rotation)
        let k = index % bladeCount
        let p0 = rimPoint(k, vertices: v), p1 = rimPoint(k + 1, vertices: v)
        let start = Darwin.atan2(Double(p0.y), Double(p0.x))
        var end = Darwin.atan2(Double(p1.y), Double(p1.x))
        while end <= start { end += 2 * .pi }
        var points = [v[k], v[(k + 1) % bladeCount], p1]
        for i in 1..<arcSamples {
            let angle = end - (end - start) * Double(i) / Double(arcSamples)
            points.append(CGPoint(x: radius * CGFloat(Darwin.cos(angle)), y: radius * CGFloat(Darwin.sin(angle))))
        }
        points.append(p0)
        return points
    }

    /// Visual center of a fully open blade, where its icon and title are drawn.
    static func labelPoint(_ index: Int) -> CGPoint { polygonCentroid(bladePolygon(index, opening: openRadius)) }

    /// Which blade a point (relative to the lens center) is on. Nil inside the opening,
    /// or beyond `maxDistance` when given. Outside the rim the direction decides.
    static func bladeIndex(at point: CGPoint, maxDistance: CGFloat? = nil) -> Int? {
        let distance = hypot(point.x, point.y)
        if contains(openingVertices(opening: openRadius), point) { return nil }
        if distance > (maxDistance ?? .infinity) { return nil }
        if distance <= radius {
            for k in 0..<bladeCount where contains(bladePolygon(k, opening: openRadius), point) { return k }
        }
        // Beyond the rim (or on a sampled seam): use the rim arc each blade owns.
        let angle = Darwin.atan2(Double(point.y), Double(point.x))
        for k in 0..<bladeCount {
            let span = rimSpan(k)
            var a = angle
            while a < span.start { a += 2 * .pi }
            if a < span.end { return k }
        }
        return nil
    }

    /// Keeps the whole lens inside a container of `size`.
    static func clampedAnchor(_ point: CGPoint, in size: CGSize, margin: CGFloat = 12) -> CGPoint {
        let reach = outerReach + margin
        func clamp(_ value: CGFloat, _ length: CGFloat) -> CGFloat {
            length <= reach * 2 ? length / 2 : min(max(value, reach), length - reach)
        }
        return CGPoint(x: clamp(point.x, size.width), y: clamp(point.y, size.height))
    }

    static func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    static func polygonCentroid(_ p: [CGPoint]) -> CGPoint {
        var area: CGFloat = 0, cx: CGFloat = 0, cy: CGFloat = 0
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count]
            let cross = a.x * b.y - b.x * a.y
            area += cross; cx += (a.x + b.x) * cross; cy += (a.y + b.y) * cross
        }
        guard abs(area) > .ulpOfOne else { return .zero }
        return CGPoint(x: cx / (3 * area), y: cy / (3 * area))
    }
}

// MARK: - State

@MainActor @Observable
final class ApertureMenuState {
    private(set) var isPresented = false
    private(set) var page: AperturePage = .main
    /// Lens center in the coordinates of the main window's content.
    private(set) var anchor: CGPoint = .zero
    private(set) var highlighted: Int?
    /// True while Space is held down: releasing it chooses the highlighted blade.
    private(set) var isHolding = false
    /// Set while a sheet covers the window, so the menu cannot open underneath it.
    var isBlocked = false

    /// A flipped view filling the window content, used to read the pointer position.
    @ObservationIgnored weak var pointerView: NSView?

    func present(at point: CGPoint, in size: CGSize, holding: Bool) {
        anchor = ApertureGeometry.clampedAnchor(point, in: size)
        page = .main
        highlighted = nil
        isHolding = holding
        isPresented = true
    }

    /// Opens the menu under the mouse pointer, or in the middle of the window when the
    /// pointer is elsewhere.
    func presentAtPointer(holding: Bool) {
        guard let view = pointerView, let window = view.window else { return }
        let size = view.bounds.size
        var point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !view.bounds.contains(point) { point = CGPoint(x: size.width / 2, y: size.height / 2) }
        present(at: point, in: size, holding: holding)
    }

    func toggleAtPointer() {
        if isPresented { dismiss() } else { presentAtPointer(holding: false) }
    }

    func dismiss() {
        isPresented = false
        isHolding = false
        highlighted = nil
        page = .main
    }

    /// Updates the highlighted blade from a pointer position in content coordinates.
    func pointerMoved(to location: CGPoint) {
        guard isPresented else { return }
        let offset = CGPoint(x: location.x - anchor.x, y: location.y - anchor.y)
        let limit = isHolding ? nil : ApertureGeometry.outerReach + ApertureGeometry.clickTolerance
        highlighted = ApertureGeometry.bladeIndex(at: offset, maxDistance: limit)
    }

    /// Arrow keys move the highlight around the iris, wrapping at the ends.
    func moveHighlight(by delta: Int) {
        let count = ApertureGeometry.bladeCount
        let start = highlighted ?? (delta > 0 ? -1 : 0)
        highlighted = ((start + delta) % count + count) % count
    }

    /// Space was released. Returns the blade to activate, if one is highlighted.
    /// Otherwise the menu stays open for clicking or keyboard use.
    func endHold() -> Int? {
        isHolding = false
        return highlighted
    }

    func showPage(_ newPage: AperturePage) {
        page = newPage
        highlighted = nil
    }

    /// Escape: leave the album-actions iris, or close the menu from the main iris.
    func back() {
        if page == .main { dismiss() } else { showPage(.main) }
    }
}

// MARK: - Keyboard

/// What a key press means for the menu. Pure, so it can be tested without windows.
enum ApertureKeyCommand: Equatable {
    case toggle, beginHold, endHold, back, activateHighlighted, move(Int), choose(Int), swallow

    static let spaceKey: UInt16 = 49

    static func interpret(type: NSEvent.EventType, keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags,
                          isRepeat: Bool, isPresented: Bool, isHolding: Bool, isEditingText: Bool, canOpen: Bool) -> ApertureKeyCommand? {
        if type == .keyUp {
            return keyCode == spaceKey && isPresented && isHolding ? .endHold : nil
        }
        guard type == .keyDown else { return nil }
        let modifierKeys = modifiers.intersection([.command, .control, .option, .shift])
        if modifierKeys == .command, characters?.lowercased() == "k" {
            return isPresented || canOpen ? .toggle : nil
        }
        if isPresented {
            // Leave other Command shortcuts (undo, save...) to the menus.
            guard modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
            switch keyCode {
            case 53, 51: return .back                      // Escape, Delete
            case 36, 76: return .activateHighlighted       // Return, Enter
            case 123, 126: return .move(-1)                // Left, Up
            case 124, 125: return .move(1)                 // Right, Down
            case spaceKey: return isRepeat || isHolding ? .swallow : .activateHighlighted
            default: break
            }
            if let characters, let number = Int(characters), (1...ApertureGeometry.bladeCount).contains(number) {
                return .choose(number - 1)
            }
            // Keep single-key review shortcuts (P, X, 1-5...) from acting behind the menu.
            return .swallow
        }
        if keyCode == spaceKey, modifierKeys.isEmpty, !isRepeat, !isEditingText, canOpen {
            return .beginHold
        }
        return nil
    }
}

// MARK: - Views

/// Fills the window content and lets the menu convert the pointer position.
struct AperturePointerAnchor: NSViewRepresentable {
    let menu: ApertureMenuState

    final class FlippedView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let view = FlippedView()
        menu.pointerView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { menu.pointerView = nsView }
}

/// Dimmed backdrop plus the lens, shown above the whole window content.
struct ApertureMenuOverlay: View {
    let menu: ApertureMenuState
    let items: [ApertureItem]
    let onActivate: (Int) -> Void

    var body: some View {
        ZStack {
            if menu.isPresented {
                Color.black.opacity(0.22)
                    .contentShape(Rectangle())
                    .transition(.opacity)
                ApertureLens(menu: menu, items: items, onActivate: onActivate)
                    .id(menu.page) // re-run the iris animation when switching pages
                    .position(menu.anchor)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.14), value: menu.isPresented)
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let location) = phase { menu.pointerMoved(to: location) }
        }
        .onTapGesture(coordinateSpace: .local) { location in tapped(at: location) }
        .allowsHitTesting(menu.isPresented)
    }

    private func tapped(at location: CGPoint) {
        let offset = CGPoint(x: location.x - menu.anchor.x, y: location.y - menu.anchor.y)
        if ApertureGeometry.contains(ApertureGeometry.openingVertices(opening: ApertureGeometry.openRadius), offset) {
            menu.back()
        } else if let index = ApertureGeometry.bladeIndex(at: offset,
                                                          maxDistance: ApertureGeometry.outerReach + ApertureGeometry.clickTolerance) {
            onActivate(index)
        } else {
            menu.dismiss()
        }
    }
}

private struct ApertureLens: View {
    let menu: ApertureMenuState
    let items: [ApertureItem]
    let onActivate: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opening = ApertureGeometry.closedRadius

    private let reach = ApertureGeometry.outerReach
    private var progress: Double {
        Double((opening - ApertureGeometry.closedRadius) / (ApertureGeometry.openRadius - ApertureGeometry.closedRadius))
    }

    var body: some View {
        ZStack {
            barrel
            ForEach(Array(items.prefix(ApertureGeometry.bladeCount).enumerated()), id: \.element.id) { index, item in
                blade(index, item: item)
            }
            ForEach(Array(items.prefix(ApertureGeometry.bladeCount).enumerated()), id: \.element.id) { index, item in
                label(index, item: item)
            }
            lensOpening
        }
        .frame(width: reach * 2, height: reach * 2)
        .compositingGroup()
        .shadow(color: .black.opacity(0.45), radius: 22, y: 8)
        .onAppear {
            if reduceMotion { opening = ApertureGeometry.openRadius }
            else { withAnimation(.spring(duration: 0.42, bounce: 0.18)) { opening = ApertureGeometry.openRadius } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Aperture menu, \(menu.page.title)")
    }

    // Lens barrel: a dark ring with engraved ticks and a red index dot at the top.
    private var barrel: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
            Path { path in
                let center = CGPoint(x: reach, y: reach)
                for tick in 0..<72 {
                    let angle = Double(tick) * .pi / 36
                    let cosAngle = CGFloat(Darwin.cos(angle))
                    let sinAngle = CGFloat(Darwin.sin(angle))
                    let long = tick % 6 == 0
                    let inner = ApertureGeometry.radius + (long ? 3 : 6)
                    let outer = reach - 3
                    path.move(to: CGPoint(x: center.x + inner * cosAngle, y: center.y + inner * sinAngle))
                    path.addLine(to: CGPoint(x: center.x + outer * cosAngle, y: center.y + outer * sinAngle))
                }
            }
            .stroke(Color.white.opacity(0.22), lineWidth: 1)
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 1).padding(0.5)
            Circle().fill(Color.red).frame(width: 5, height: 5).offset(y: -(reach - 7))
        }
    }

    private func blade(_ index: Int, item: ApertureItem) -> some View {
        let shape = BladeShape(index: index, opening: opening, center: CGPoint(x: reach, y: reach))
        let highlighted = menu.highlighted == index
        let tint: [Color] = highlighted
            ? (item.isEnabled ? [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.7)] : [Color(white: 0.38), Color(white: 0.28)])
            : [Color(white: item.isEnabled ? 0.30 : 0.22), Color(white: item.isEnabled ? 0.13 : 0.10)]
        // Shade each blade from its inner edge toward the rim, like brushed metal.
        let inner = ApertureGeometry.openingVertices(opening: ApertureGeometry.openRadius)[index]
        let rim = ApertureGeometry.labelPoint(index)
        let start = UnitPoint(x: (inner.x + reach) / (reach * 2), y: (inner.y + reach) / (reach * 2))
        let end = UnitPoint(x: (rim.x * 1.45 + reach) / (reach * 2), y: (rim.y * 1.45 + reach) / (reach * 2))
        return ZStack {
            shape.fill(LinearGradient(colors: tint, startPoint: start, endPoint: end))
            shape.stroke(Color.black.opacity(0.65), lineWidth: 1.2)
            shape.stroke(item.isCurrent ? Color.accentColor : Color.white.opacity(0.07), lineWidth: item.isCurrent ? 2 : 0.6)
        }
    }

    private func label(_ index: Int, item: ApertureItem) -> some View {
        // Slightly outside the centroid, where the blade is widest.
        let point = ApertureGeometry.labelPoint(index).applying(CGAffineTransform(scaleX: 1.07, y: 1.07))
        return VStack(spacing: 3) {
            Image(systemName: item.symbol).font(.system(size: 19, weight: .medium))
            Text(item.title).font(.system(size: 11, weight: .semibold)).multilineTextAlignment(.center).lineLimit(2)
            Text("\(index + 1)").font(.system(size: 9, weight: .medium).monospacedDigit()).opacity(0.55)
        }
        .foregroundStyle(item.isEnabled ? Color.white : Color.white.opacity(0.35))
        .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
        .frame(width: 78)
        .position(x: reach + point.x, y: reach + point.y)
        .opacity(max(0, (progress - 0.55) / 0.45))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityHint(item.isEnabled ? "" : (item.unavailableReason ?? "Unavailable"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onActivate(index) }
    }

    // The hexagonal opening: you look through the lens at the photo behind it.
    private var lensOpening: some View {
        let item = menu.highlighted.flatMap { items.indices.contains($0) ? items[$0] : nil }
        let title = item?.title ?? menu.page.title
        let detail: String = {
            if let item, !item.isEnabled { return item.unavailableReason ?? "Unavailable" }
            if item != nil { return menu.isHolding ? "Release Space" : "Click or Return" }
            return menu.page == .main ? "Esc to close" : "Esc to go back"
        }()
        let hexagon = OpeningShape(opening: opening, center: CGPoint(x: reach, y: reach))
        return ZStack {
            hexagon.fill(.ultraThinMaterial)
            hexagon.fill(Color.black.opacity(0.5))
            hexagon.stroke(Color.white.opacity(0.25), lineWidth: 1)
            VStack(spacing: 2) {
                if menu.page != .main && item == nil {
                    Image(systemName: "chevron.backward").font(.system(size: 10, weight: .bold))
                }
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                Text(detail).font(.system(size: 8.5)).opacity(0.75).lineLimit(2).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .frame(width: 78)
            .opacity(max(0, (progress - 0.6) / 0.4))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { menu.back() }
    }
}

/// One iris blade; `opening` animates from closed to open.
private struct BladeShape: Shape {
    let index: Int
    var opening: CGFloat
    let center: CGPoint

    var animatableData: CGFloat {
        get { opening }
        set { opening = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let points = ApertureGeometry.bladePolygon(index, opening: opening)
        var path = Path()
        path.addLines(points.map { CGPoint(x: center.x + $0.x, y: center.y + $0.y) })
        path.closeSubpath()
        return path
    }
}

/// The hexagonal lens opening.
private struct OpeningShape: Shape {
    var opening: CGFloat
    let center: CGPoint

    var animatableData: CGFloat {
        get { opening }
        set { opening = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addLines(ApertureGeometry.openingVertices(opening: opening).map { CGPoint(x: center.x + $0.x, y: center.y + $0.y) })
        path.closeSubpath()
        return path
    }
}
