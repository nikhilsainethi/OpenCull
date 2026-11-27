import AppKit
import CullCore
import SwiftUI

struct ContentView: View {
    @Environment(LibraryModel.self) private var model
    @State private var keyMonitor = KeyMonitor()

    var body: some View {
        @Bindable var model = model
        Group {
            if model.folder == nil {
                WelcomeView()
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        GridView()
                        Divider()
                        StatusBar()
                    }
                    .frame(minWidth: 380, idealWidth: 560)
                    DetailView()
                        .frame(minWidth: 480, idealWidth: 760)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(WindowReader { model.window = $0 })
        .toolbar { toolbar }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
            model.open(url)
            return true
        }
        .onAppear {
            keyMonitor.start { handleKey($0) }
            openFolderFromArguments()
        }
        .onDisappear { keyMonitor.stop() }
    }

    /// `OpenCull --open <folder>` opens a folder at launch.
    /// With OPENCULL_SNAPSHOT=<file.png> set, the window is also saved as an image after
    /// analysis and the app quits (used for automated checks and README screenshots).
    private func openFolderFromArguments() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--open"), flag + 1 < arguments.count else { return }
        model.open(URL(fileURLWithPath: arguments[flag + 1]))
        guard let snapshotPath = ProcessInfo.processInfo.environment["OPENCULL_SNAPSHOT"] else { return }
        // Offscreen rendering skips the window background, so use the light appearance
        // to keep text readable in the saved image.
        NSApp.appearance = NSAppearance(named: .aqua)
        Task { @MainActor in
            while model.isAnalyzing { try? await Task.sleep(for: .milliseconds(200)) }
            model.showFaceBoxes = ProcessInfo.processInfo.environment["OPENCULL_SNAPSHOT_FACES"] == "1"
            // Occluded windows may not redraw, so bring the window to the front first.
            NSApp.activate(ignoringOtherApps: true)
            model.window?.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(2)) // let previews decode
            if let view = model.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: snapshotPath))
            }
            NSApp.terminate(nil)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var model = model
        ToolbarItem(placement: .navigation) {
            Button { model.showOpenPanel() } label: { Label("Open Folder", systemImage: "folder") }
                .help("Open a folder of photos (⌘O)")
        }
        if model.folder != nil {
            ToolbarItem {
                Picker("Show", selection: $model.filter) {
                    ForEach(LibraryFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 170)
                .help("Filter photos")
            }
            ToolbarItem {
                Toggle(isOn: $model.showGroups) { Label("Group Similar", systemImage: "square.stack.3d.up") }
                    .help("Show similar shots together")
            }
            ToolbarItem {
                Toggle(isOn: $model.showFaceBoxes) { Label("Face Boxes", systemImage: "face.dashed") }
                    .help("Outline detected faces: green = eyes open, red = closed (F)")
            }
            ToolbarItem {
                Button { model.acceptSuggestions() } label: { Label("Accept Suggestions", systemImage: "wand.and.stars") }
                    .disabled(model.isAnalyzing)
                    .help("Mark every undecided photo with the suggested pick/reject")
            }
            ToolbarItem {
                Menu {
                    Button("Write XMP Sidecars (ratings & labels)") { model.writeSidecars() }
                    Button("Copy Picks to Folder…") { model.copyPicks() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(model.isExporting)
                .help("Export your decisions")
            }
        }
    }

    /// Single-key shortcuts for fast culling. Returns true when the key was handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard model.folder != nil, event.window === model.window else { return false }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        if event.window?.firstResponder is NSText { return false }

        switch event.keyCode {
        case 123: model.selectPrevious(); return true      // left arrow
        case 124: model.selectNext(); return true          // right arrow
        case 125: model.selectNextSection(); return true   // down arrow
        case 126: model.selectPreviousSection(); return true // up arrow
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "p": model.setDecision(.pick)
        case "x": model.setDecision(.reject)
        case "u": model.setDecision(.undecided)
        case "f": model.showFaceBoxes.toggle()
        case "0": model.setRating(0)
        case "1": model.setRating(1)
        case "2": model.setRating(2)
        case "3": model.setRating(3)
        case "4": model.setRating(4)
        case "5": model.setRating(5)
        default: return false
        }
        return true
    }
}

private struct WelcomeView: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("OpenCull").font(.largeTitle.bold())
            Text("Private, on-device photo culling. Nothing is uploaded.\nOpen a folder or drop it here.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Folder…") { model.showOpenPanel() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            VStack(alignment: .leading, spacing: 4) {
                shortcut("← →", "previous / next photo")
                shortcut("↑ ↓", "previous / next group")
                shortcut("P  X  U", "pick / reject / clear")
                shortcut("1 – 5, 0", "star rating / remove rating")
                shortcut("F", "show face boxes")
            }
            .font(.callout)
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortcut(_ keys: String, _ action: String) -> some View {
        HStack {
            Text(keys).font(.callout.monospaced()).frame(width: 90, alignment: .trailing)
            Text(action).foregroundStyle(.secondary)
        }
    }
}

private struct StatusBar: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        let counts = model.counts
        HStack(spacing: 14) {
            if model.isAnalyzing {
                ProgressView(value: Double(model.analyzedCount), total: Double(max(1, counts.total)))
                    .frame(width: 120)
                Text("Analyzing \(model.analyzedCount) of \(counts.total)")
            } else {
                Text("\(counts.total) photos")
            }
            Spacer()
            Label("\(counts.picks)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Label("\(counts.rejects)", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            Label("\(counts.undecided)", systemImage: "circle.dashed").foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Listens for key presses in the app's windows.
final class KeyMonitor {
    private var token: Any?

    func start(_ handler: @escaping (NSEvent) -> Bool) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handler(event) } ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

/// Gives SwiftUI access to the hosting NSWindow.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}
