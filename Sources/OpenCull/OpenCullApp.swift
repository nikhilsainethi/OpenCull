import AppKit
import CullCore
import SwiftUI

@main
struct OpenCullApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = LibraryModel()

    var body: some Scene {
        Window("OpenCull", id: "main") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { model.showOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Cull") {
                Button("Pick   (P)") { model.setDecision(.pick) }
                Button("Reject   (X)") { model.setDecision(.reject) }
                Button("Clear Decision   (U)") { model.setDecision(.undecided) }
                Divider()
                Button("Accept Suggestions") { model.acceptSuggestions() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Divider()
                Button("Write XMP Sidecars") { model.writeSidecars() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Copy Picks to Folder…") { model.copyPicks() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) instead of an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
