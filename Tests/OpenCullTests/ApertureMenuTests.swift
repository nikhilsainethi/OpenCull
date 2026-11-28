import AppKit
import SwiftUI
import XCTest
@testable import OpenCull

final class ApertureMenuTests: XCTestCase {
    // MARK: Iris geometry

    func testBladeZeroSitsAtTheTopAndBladesRunClockwise() {
        let angles = (0..<6).map { index -> Double in
            let p = ApertureGeometry.labelPoint(index)
            return atan2(Double(p.y), Double(p.x)) * 180 / .pi
        }
        XCTAssertEqual(angles[0], -90, accuracy: 0.5, "Blade 1 is straight up")
        for index in 1..<6 {
            var delta = angles[index] - angles[index - 1]
            if delta < 0 { delta += 360 }
            XCTAssertEqual(delta, 60, accuracy: 0.5, "Blade \(index + 1) follows clockwise")
        }
    }

    func testEachBladeOwnsOneSixthOfTheRim() {
        for index in 0..<6 {
            let span = ApertureGeometry.rimSpan(index)
            XCTAssertEqual((span.end - span.start) * 180 / .pi, 60, accuracy: 0.01)
        }
    }

    func testBladesTileTheLensWithoutOverlap() {
        // Sample points across the lens: every point outside the opening is on exactly one blade.
        let polygons = (0..<6).map { ApertureGeometry.bladePolygon($0, opening: ApertureGeometry.openRadius, arcSamples: 96) }
        let opening = ApertureGeometry.openingVertices(opening: ApertureGeometry.openRadius)
        var checked = 0
        for x in stride(from: -146.0, through: 146, by: 7.3) {
            for y in stride(from: -146.0, through: 146, by: 7.3) {
                let point = CGPoint(x: x, y: y)
                guard hypot(x, y) < 146, !ApertureGeometry.contains(opening, point) else { continue }
                XCTAssertEqual(polygons.filter { ApertureGeometry.contains($0, point) }.count, 1, "point \(point)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 1000)
    }

    func testHitTestingMatchesTheDrawnBlades() {
        for index in 0..<6 {
            XCTAssertEqual(ApertureGeometry.bladeIndex(at: ApertureGeometry.labelPoint(index)), index)
        }
    }

    func testOpeningAndFarPointsSelectNothing() {
        XCTAssertNil(ApertureGeometry.bladeIndex(at: .zero))
        XCTAssertNil(ApertureGeometry.bladeIndex(at: CGPoint(x: 20, y: -20)))
        XCTAssertNil(ApertureGeometry.bladeIndex(at: CGPoint(x: 0, y: -400), maxDistance: 200))
        XCTAssertEqual(ApertureGeometry.bladeIndex(at: CGPoint(x: 0, y: -400)), ApertureGeometry.bladeIndex(at: CGPoint(x: 0, y: -149)),
                       "While holding Space, direction beyond the rim keeps choosing the same blade")
    }

    func testLensStaysInsideTheWindow() {
        let size = CGSize(width: 1000, height: 700)
        let reach = ApertureGeometry.outerReach + 12
        XCTAssertEqual(ApertureGeometry.clampedAnchor(CGPoint(x: 5, y: 5), in: size), CGPoint(x: reach, y: reach))
        XCTAssertEqual(ApertureGeometry.clampedAnchor(CGPoint(x: 995, y: 695), in: size), CGPoint(x: 1000 - reach, y: 700 - reach))
        XCTAssertEqual(ApertureGeometry.clampedAnchor(CGPoint(x: 500, y: 350), in: size), CGPoint(x: 500, y: 350))
        XCTAssertEqual(ApertureGeometry.clampedAnchor(CGPoint(x: 5, y: 5), in: CGSize(width: 200, height: 200)), CGPoint(x: 100, y: 100))
    }

    func testClosedIrisStillHasSixBlades() {
        for index in 0..<6 {
            let polygon = ApertureGeometry.bladePolygon(index, opening: ApertureGeometry.closedRadius)
            XCTAssertTrue(polygon.allSatisfy { $0.x.isFinite && $0.y.isFinite })
            XCTAssertLessThanOrEqual(polygon.map { hypot($0.x, $0.y) }.max() ?? 0, ApertureGeometry.radius + 0.001)
        }
    }

    // MARK: State

    @MainActor func testHoldingSpaceAndReleasingOverABladeChoosesIt() {
        let menu = ApertureMenuState()
        menu.present(at: CGPoint(x: 500, y: 400), in: CGSize(width: 1000, height: 800), holding: true)
        XCTAssertTrue(menu.isPresented)
        XCTAssertTrue(menu.isHolding)
        menu.pointerMoved(to: CGPoint(x: 500, y: 100)) // straight up, beyond the lens
        XCTAssertEqual(menu.highlighted, 0)
        XCTAssertEqual(menu.endHold(), 0)
        XCTAssertFalse(menu.isHolding)
    }

    @MainActor func testQuickTapLeavesTheMenuOpenForClicking() {
        let menu = ApertureMenuState()
        menu.present(at: CGPoint(x: 500, y: 400), in: CGSize(width: 1000, height: 800), holding: true)
        XCTAssertNil(menu.endHold())
        XCTAssertTrue(menu.isPresented)
        menu.pointerMoved(to: CGPoint(x: 500, y: 20)) // far outside the lens in click mode
        XCTAssertNil(menu.highlighted)
        let top = ApertureGeometry.labelPoint(0)
        menu.pointerMoved(to: CGPoint(x: 500 + top.x, y: 400 + top.y))
        XCTAssertEqual(menu.highlighted, 0)
    }

    @MainActor func testArrowKeysWrapAndEscapeGoesBackThenCloses() {
        let menu = ApertureMenuState()
        menu.present(at: .zero, in: CGSize(width: 1000, height: 800), holding: false)
        menu.moveHighlight(by: -1)
        XCTAssertEqual(menu.highlighted, 5)
        menu.moveHighlight(by: 1)
        XCTAssertEqual(menu.highlighted, 0)

        menu.showPage(.albumActions)
        XCTAssertNil(menu.highlighted)
        menu.back()
        XCTAssertTrue(menu.isPresented)
        XCTAssertEqual(menu.page, .main)
        menu.back()
        XCTAssertFalse(menu.isPresented)
    }

    @MainActor func testReopeningStartsOnTheMainIris() {
        let menu = ApertureMenuState()
        menu.present(at: .zero, in: CGSize(width: 1000, height: 800), holding: false)
        menu.showPage(.albumActions)
        menu.dismiss()
        menu.present(at: .zero, in: CGSize(width: 1000, height: 800), holding: false)
        XCTAssertEqual(menu.page, .main)
    }

    // MARK: Keyboard

    private func key(_ code: UInt16, _ chars: String? = nil, type: NSEvent.EventType = .keyDown,
                     modifiers: NSEvent.ModifierFlags = [], repeat isRepeat: Bool = false, presented: Bool = false,
                     holding: Bool = false, editing: Bool = false, canOpen: Bool = true) -> ApertureKeyCommand? {
        ApertureKeyCommand.interpret(type: type, keyCode: code, characters: chars, modifiers: modifiers, isRepeat: isRepeat,
                                     isPresented: presented, isHolding: holding, isEditingText: editing, canOpen: canOpen)
    }

    func testOpeningCommands() {
        XCTAssertEqual(key(40, "k", modifiers: .command), .toggle)
        XCTAssertEqual(key(40, "k", modifiers: .command, presented: true, canOpen: false), .toggle, "⌘K can always close")
        XCTAssertNil(key(40, "k", modifiers: .command, canOpen: false))
        XCTAssertNil(key(40, "k", modifiers: [.command, .shift]))
        XCTAssertEqual(key(49, " "), .beginHold)
        XCTAssertNil(key(49, " ", editing: true), "Space types into text fields")
        XCTAssertNil(key(49, " ", repeat: true))
        XCTAssertNil(key(49, " ", canOpen: false))
        XCTAssertNil(key(35, "p"), "Review shortcuts are untouched while the menu is closed")
    }

    func testKeysWhileTheMenuIsOpen() {
        XCTAssertEqual(key(49, " ", type: .keyUp, presented: true, holding: true), .endHold)
        XCTAssertNil(key(49, " ", type: .keyUp, presented: true, holding: false))
        XCTAssertEqual(key(49, " ", repeat: true, presented: true, holding: true), .swallow)
        XCTAssertEqual(key(49, " ", presented: true), .activateHighlighted)
        XCTAssertEqual(key(53, presented: true), .back)
        XCTAssertEqual(key(36, presented: true), .activateHighlighted)
        XCTAssertEqual(key(123, presented: true), .move(-1))
        XCTAssertEqual(key(125, presented: true), .move(1))
        XCTAssertEqual(key(20, "3", presented: true), .choose(2))
        XCTAssertEqual(key(28, "8", presented: true), .swallow, "There is no eighth blade")
        XCTAssertEqual(key(35, "p", presented: true), .swallow, "Pick must not act behind the menu")
        XCTAssertNil(key(6, "z", modifiers: .command, presented: true), "Undo still reaches the menu bar")
    }

    // MARK: Items

    @MainActor private func makeModel() -> LibraryModel {
        LibraryModel(appDataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                     defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    func testEveryPageFillsAllSixBlades() {
        XCTAssertEqual(AperturePage.main.actions.count, ApertureGeometry.bladeCount)
        XCTAssertEqual(AperturePage.albumActions.actions.count, ApertureGeometry.bladeCount)
    }

    @MainActor func testWithoutAnAlbumOnlyImportIsAvailable() {
        let items = ApertureItem.items(for: .main, model: makeModel())
        XCTAssertEqual(items.map(\.action), [.importPhotos, .cull, .compare, .edit, .accept, .albumActions])
        XCTAssertEqual(items.filter(\.isEnabled).map(\.action), [.importPhotos])
        XCTAssertTrue(items.filter { !$0.isEnabled }.allSatisfy { $0.unavailableReason != nil })
        XCTAssertFalse(items.contains(where: \.isCurrent))
    }

    @MainActor func testAlbumActionsAreUnavailableWithoutAnAlbum() {
        let items = ApertureItem.items(for: .albumActions, model: makeModel())
        XCTAssertEqual(items.map(\.action), [.mergeGroup, .splitGroup, .resetGroups, .findDuplicates, .suggestTarget, .retryAnalysis])
        XCTAssertTrue(items.allSatisfy { !$0.isEnabled })
    }

    @MainActor func testLensRenders() throws {
        let menu = ApertureMenuState()
        menu.present(at: CGPoint(x: 200, y: 200), in: CGSize(width: 400, height: 400), holding: false)
        menu.moveHighlight(by: 1)
        let view = ApertureMenuOverlay(menu: menu, items: ApertureItem.items(for: .main, model: makeModel()), onActivate: { _ in })
            .frame(width: 400, height: 400)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 800)
    }
}
