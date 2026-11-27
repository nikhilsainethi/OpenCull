import AppKit
import XCTest
@testable import OpenCull

@MainActor private final class ReviewTestView: NSView, ReviewKeyboardResponder {}
@MainActor private final class TextUndoTestView: NSTextView {
    let testUndoManager = UndoManager()
    override var undoManager: UndoManager? { testUndoManager }
}

final class NativeInteractionRoutingTests: XCTestCase {
    private func event(_ modifiers: NSEvent.ModifierFlags = .command, characters: String = "a", keyCode: UInt16 = 0) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                       isARepeat: false, keyCode: keyCode))
    }

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

    @MainActor func testCommandAEventSelectsTextBeforeSwiftUIMenuDispatch() throws {
        let text = NSTextView(); text.string = "never"; text.setSelectedRange(NSRange(location: 5, length: 0))
        var workspaceCalled = false
        XCTAssertTrue(ReviewKeyboardNavigation.handleSelectAll(try event(), responder: text, workspace: { workspaceCalled = true }))
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 5))
        XCTAssertFalse(workspaceCalled)
        XCTAssertTrue(ReviewKeyboardNavigation.handleSelectAll(try event(), responder: NSView(), workspace: { workspaceCalled = true }))
        XCTAssertTrue(workspaceCalled)
    }

    @MainActor func testSelectAllEventLeavesOtherKeyboardCommandsUntouched() throws {
        var workspaceCalled = false
        for modifiers: NSEvent.ModifierFlags in [[], .shift, [.command, .shift], [.command, .option], [.command, .control]] {
            XCTAssertFalse(ReviewKeyboardNavigation.handleSelectAll(try event(modifiers), responder: nil, workspace: { workspaceCalled = true }))
        }
        XCTAssertFalse(ReviewKeyboardNavigation.handleSelectAll(try event(.command, characters: "q"), responder: nil, workspace: { workspaceCalled = true }), "Interpret the shortcut's character, not a physical US keyboard position")
        XCTAssertFalse(workspaceCalled)
    }
}
