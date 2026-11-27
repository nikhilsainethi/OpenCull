import AppKit
import CullCore
import SwiftUI

@main
struct OpenCullApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = LibraryModel(appDataDirectory: ProcessInfo.processInfo.environment["OPENCULL_DATA_DIR"].map { URL(fileURLWithPath: $0) })

    var body: some Scene {
        Window("OpenCull", id: "main") {
            ContentView()
                .environment(model)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1560, height: 980)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { model.showOpenPanel() }
                    .keyboardShortcut("o")
                    .disabled(model.isExporting || model.isImporting || model.isOpening)
            }
            CommandGroup(replacing: .undoRedo) {
                Button(EditingUndoRouter.textManager(NSApp.keyWindow?.firstResponder)?.undoMenuItemTitle ?? model.undoTitle) {
                    if let manager = EditingUndoRouter.textManager(NSApp.keyWindow?.firstResponder) { manager.undo() }
                    else { model.undo() }
                }.keyboardShortcut("z").disabled(model.isOpening)
                Button(EditingUndoRouter.textManager(NSApp.keyWindow?.firstResponder, redo: true)?.redoMenuItemTitle ?? model.redoTitle) {
                    if let manager = EditingUndoRouter.textManager(NSApp.keyWindow?.firstResponder, redo: true) { manager.redo() }
                    else { model.redo() }
                }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(model.isOpening)
            }
            CommandGroup(after: .saveItem) {
                Button("Save Workspace") { _ = model.flushPendingSaves() }.keyboardShortcut("s")
            }
            CommandMenu("Cull") {
                Button("Pick   (P)") { model.setDecision(.pick) }.disabled(model.isOpening)
                Button("Reject   (X)") { model.setDecision(.reject) }.disabled(model.isOpening)
                Button("Clear Decision   (U)") { model.setDecision(.undecided) }.disabled(model.isOpening)
                Divider()
                Button("Accept Suggestions") { model.acceptSuggestions() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(model.isAnalyzing || model.isExporting || model.isOpening)
                Button("Select All Visible") { EditingUndoRouter.selectAll(NSApp.keyWindow?.firstResponder, workspace: model.selectAllVisible) }.keyboardShortcut("a").disabled(model.isOpening)
                Button("Compare Selected (N)") { model.mode = .compare; model.prepareComparison() }.disabled(model.isOpening)
                Button("Edit Selected (E)") { model.mode = .edit }.disabled(model.isOpening)
                Divider()
                Button("Write XMP Sidecars") { model.writeSidecars() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.isExporting || model.isAnalyzing || model.isOpening)
                Button("Copy Picks to Folder…") { model.copyPicks() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.isExporting || model.isOpening)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

@MainActor enum EditingUndoRouter {
    static func textManager(_ responder: NSResponder?, redo: Bool = false) -> UndoManager? {
        guard let manager = (responder as? NSTextView)?.undoManager,
              redo ? manager.canRedo : manager.canUndo else { return nil }
        return manager
    }
    static func selectAll(_ responder: NSResponder?, workspace: () -> Void) {
        if let text = responder as? NSText { text.selectAll(nil) }
        else { workspace() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: LibraryModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) instead of an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.cancelOpening()
        if model?.isExporting == true || model?.isImporting == true {
            model?.alert = AlertMessage(title: "Work in progress", message: "Wait for the current import or export to finish before closing OpenCull.")
            return .terminateCancel
        }
        return model?.flushPendingSaves() == false ? .terminateCancel : .terminateNow
    }
}
