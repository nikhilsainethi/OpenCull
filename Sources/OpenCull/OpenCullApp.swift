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
                    .disabled(model.isExporting || model.isImporting)
            }
            CommandGroup(replacing: .undoRedo) {
                Button(model.undoTitle) {
                    if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.undoManager?.undo() }
                    else { model.undo() }
                }.keyboardShortcut("z")
                Button(model.redoTitle) {
                    if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.undoManager?.redo() }
                    else { model.redo() }
                }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .saveItem) {
                Button("Save Workspace") { _ = model.flushPendingSaves() }.keyboardShortcut("s")
            }
            CommandMenu("Cull") {
                Button("Pick   (P)") { model.setDecision(.pick) }
                Button("Reject   (X)") { model.setDecision(.reject) }
                Button("Clear Decision   (U)") { model.setDecision(.undecided) }
                Divider()
                Button("Accept Suggestions") { model.acceptSuggestions() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(model.isAnalyzing || model.isExporting)
                Button("Select All Visible") { model.selectAllVisible() }.keyboardShortcut("a")
                Button("Compare Selected (N)") { model.mode = .compare; model.prepareComparison() }
                Button("Edit Selected (E)") { model.mode = .edit }
                Divider()
                Button("Write XMP Sidecars") { model.writeSidecars() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.isExporting || model.isAnalyzing)
                Button("Copy Picks to Folder…") { model.copyPicks() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.isExporting)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
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
        if model?.isExporting == true || model?.isImporting == true {
            model?.alert = AlertMessage(title: "Work in progress", message: "Wait for the current import or export to finish before closing OpenCull.")
            return .terminateCancel
        }
        return model?.flushPendingSaves() == false ? .terminateCancel : .terminateNow
    }
}
