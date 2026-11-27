import AppKit
import XCTest
@testable import OpenCull

@MainActor private final class ReviewTestView: NSView, ReviewKeyboardResponder {}
@MainActor private final class TextUndoTestView: NSTextView {
    let testUndoManager = UndoManager()
    override var undoManager: UndoManager? { testUndoManager }
}

final class NativeInteractionRoutingTests: XCTestCase {
    @MainActor func testEditorControlsKeepNativeArrowKeys() {
        XCTAssertFalse(ReviewKeyboardNavigation.allows(NSSlider(), mode: .edit))
        XCTAssertFalse(ReviewKeyboardNavigation.allows(NSPopUpButton(), mode: .cull))
        XCTAssertFalse(ReviewKeyboardNavigation.allows(NSView(), mode: .edit), "SwiftUI control hosting responders are not guaranteed to be NSControl")
        XCTAssertFalse(ReviewKeyboardNavigation.allows(NSTextView(), mode: .cull))
        XCTAssertTrue(ReviewKeyboardNavigation.allows(ReviewTestView(), mode: .edit))
        XCTAssertTrue(ReviewKeyboardNavigation.allows(NSView(), mode: .cull))
    }

    @MainActor func testEmptyTextUndoCannotInterceptWorkspaceUndoOrRedo() {
        let text = TextUndoTestView()
        XCTAssertNil(EditingUndoRouter.textManager(text))
        XCTAssertNil(EditingUndoRouter.textManager(text, redo: true))
    }

    @MainActor func testAvailableNativeTextUndoStillTakesPriority() {
        let text = TextUndoTestView()
        text.testUndoManager.registerUndo(withTarget: text) { target in
            target.testUndoManager.registerUndo(withTarget: target) { _ in }
        }
        XCTAssertTrue(EditingUndoRouter.textManager(text) === text.testUndoManager)
        text.testUndoManager.undo()
        XCTAssertTrue(EditingUndoRouter.textManager(text, redo: true) === text.testUndoManager)
    }

    @MainActor func testSelectAllBelongsToActiveTextBeforeWorkspaceSelection() {
        let text = NSTextView()
        text.string = "never"
        text.setSelectedRange(NSRange(location: 5, length: 0))
        var workspaceCalled = false
        EditingUndoRouter.selectAll(text, workspace: { workspaceCalled = true })
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 5))
        XCTAssertFalse(workspaceCalled)
        EditingUndoRouter.selectAll(NSView(), workspace: { workspaceCalled = true })
        XCTAssertTrue(workspaceCalled)
    }
}
