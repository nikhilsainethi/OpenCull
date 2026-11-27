import AppKit
import CullCore
import PhotosUI
import SwiftUI

struct ContentView: View {
    @Environment(LibraryModel.self) private var model
    @State private var keyMonitor = KeyMonitor()
    @State private var exportSheet = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var importingPhotos = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if model.folder == nil { welcome }
            else {
                albumBar
                Divider()
                HSplitView {
                    VStack(spacing: 0) {
                        HStack {
                            Picker("Show", selection: $model.filter) {
                                ForEach(LibraryFilter.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden().frame(maxWidth: 180)
                            Spacer()
                            Toggle(isOn: $model.showGroups) { Image(systemName: "square.stack.3d.up") }
                                .toggleStyle(.button).help("Show group headers")
                        }.padding(10)
                        TextField("Search names, subjects, scenes…", text: $model.searchText)
                            .textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.bottom, 8)
                        GridView()
                    }.frame(minWidth: 260, idealWidth: 350, maxWidth: 430)
                    VStack(spacing: 0) {
                        reviewBar
                        Divider()
                        if model.mode == .compare { CompareWorkspaceView() }
                        else { DetailView() }
                    }.frame(minWidth: 480, maxWidth: .infinity)
                    if model.mode == .edit { EditorPanel().frame(minWidth: 285, idealWidth: 315, maxWidth: 350) }
                }
                Divider()
                statusBar
            }
        }
        .frame(minWidth: 1080, minHeight: 680)
        .disabled(model.isOpening)
        .overlay {
            if model.isOpening {
                VStack(spacing: 12) {
                    ProgressView("Opening photo folder…")
                    Text("Reading files and saved choices. You can cancel without changing the current album.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Cancel opening", action: model.cancelOpening)
                }.padding(24).frame(width: 340).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .background(WindowReader { model.window = $0 })
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    Button("Open folder…", action: model.showOpenPanel)
                    Toggle("Include subfolders", isOn: $model.recursive)
                    if !model.recentAlbums.isEmpty {
                        Divider()
                        ForEach(model.recentAlbums) { album in
                            Button("\(album.title) · \(album.count) photos") { model.openRecent(album) }
                        }
                    }
                } label: { Label("Albums", systemImage: "folder") }
                .disabled(model.isExporting || model.isImporting || model.isOpening)
            }
            ToolbarItem { PhotosPicker(selection: $photoSelection, matching: .images) { Label("Photos", systemImage: "photo.on.rectangle") }.disabled(importingPhotos || model.isExporting || model.isOpening) }
            ToolbarItem(placement: .principal) {
                Picker("Workspace", selection: $model.mode) {
                    ForEach(WorkspaceMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
                }.pickerStyle(.segmented).frame(width: 310).disabled(model.folder == nil)
            }
            ToolbarItem {
                Button { model.acceptSuggestions() } label: { Label("Accept", systemImage: "wand.and.stars") }
                    .disabled(model.folder == nil || model.isAnalyzing || model.isExporting || model.isOpening)
                    .help("Apply completed suggestions; uncertain photos stay undecided. Undo is available.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { exportSheet = true } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                    .disabled(model.folder == nil || model.isExporting || model.isImporting || model.isOpening)
            }
        }
        .sheet(isPresented: $exportSheet) { ExportSheet() }
        .alert(item: $model.alert) { Alert(title: Text($0.title), message: Text($0.message)) }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            // Directory validation belongs to the detached loader too: even a
            // resource-value lookup can wait on a cloud provider or permission.
            Task { await model.open(url) }; return true
        }
        .onChange(of: photoSelection) { _, selection in
            guard !selection.isEmpty else { return }
            importingPhotos = true
            Task {
                var album: URL?
                var imported = 0
                do {
                    let destination = try model.beginPhotosImport()
                    album = destination
                    for (index, item) in selection.enumerated() {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                        try await Task.detached(priority: .userInitiated) { try LibraryModel.storeImportedImage(data, index: index, in: destination) }.value
                        imported += 1
                    }
                    await model.finishPhotosImport(destination)
                } catch {
                    await model.finishPhotosImport(imported > 0 ? album : nil)
                    model.alert = AlertMessage(title: "Photos import needs attention", message: "Imported \(imported) of \(selection.count) chosen photos. " + error.localizedDescription)
                }
                importingPhotos = false; photoSelection = []
            }
        }
        .onAppear {
            keyMonitor.start(handleKey)
            let arguments = CommandLine.arguments
            if let index = arguments.firstIndex(of: "--open"), index + 1 < arguments.count {
                Task { await model.open(URL(fileURLWithPath: arguments[index + 1])) }
            }
        }
        .onDisappear { keyMonitor.stop(); model.cancelOpening(); _ = model.flushPendingSaves() }
    }

    private var albumBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.aperture").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.folder?.lastPathComponent ?? "Album").font(.headline)
                Text("\(model.counts.total) photos · \(model.visibleItems.count) visible").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.mode == .compare { Text("⌘-click up to four photos to compare").font(.caption).foregroundStyle(.secondary) }
            Menu {
                Button("Select all visible", action: model.selectAllVisible)
                Button("Compare selected") { model.mode = .compare; model.prepareComparison() }
                Divider()
                Button("Merge selected into a group", action: model.mergeSelectedGroup).disabled(model.selectedItems.count < 2)
                Button("Split selected from groups", action: model.splitSelectedGroup)
                Button("Reset manual groups", action: model.resetGroups)
                Button("Find exact duplicates across album", action: model.findExactDuplicates).disabled(model.isAnalyzing || model.isFindingDuplicates)
                Button("Retry failed analysis", action: model.retryAnalysis).disabled(model.isAnalyzing)
                Divider()
                Stepper("Target: \(model.targetCount) picks", value: Binding(get: { model.targetCount }, set: { model.targetCount = $0 }), in: 1...max(1, model.items.count))
                Button("Suggest target selection", action: model.suggestTargetCount).disabled(model.isAnalyzing)
            } label: { Label("Album actions", systemImage: "ellipsis.circle") }
                .fixedSize()
            Label("On this Mac", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var reviewBar: some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            Picker("Zoom", selection: $model.zoom) { ForEach(ZoomMode.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).frame(width: 190)
            Toggle(isOn: $model.showFaceBoxes) { Label("Faces", systemImage: "face.dashed") }.toggleStyle(.button)
            Toggle(isOn: $model.showOriginal) { Text("Before") }.toggleStyle(.button).help("Show the untouched original (B)")
            Spacer()
            if model.selectedItems.count > 1 { Text("\(model.selectedItems.count) selected").font(.caption).foregroundStyle(.secondary) }
            Button { model.selectPrevious() } label: { Image(systemName: "chevron.left") }.help("Previous photo")
            Button { model.selectNext() } label: { Image(systemName: "chevron.right") }.help("Next photo")
        }.controlSize(.small).padding(10)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if model.isOpening { ProgressView().controlSize(.small); Text("Opening photo folder…") }
            else if model.isAnalyzing {
                ProgressView(value: Double(model.analyzedCount), total: Double(max(1, model.items.count))).frame(width: 100)
                Text("Analyzing \(model.analyzedCount) / \(model.items.count)")
            } else if model.isExporting { ProgressView().controlSize(.small); Text(model.exportProgress) }
            else if model.isImporting { ProgressView().controlSize(.small); Text("Importing chosen Photos images…") }
            else if model.isFindingDuplicates { ProgressView().controlSize(.small); Text("Checking exact duplicates…") }
            else { Text("\(model.items.filter(\.needsReview).count) need review") }
            Spacer()
            Label("\(model.counts.picks)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Label("\(model.counts.rejects)", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            Label("\(model.counts.undecided)", systemImage: "circle.dashed").foregroundStyle(.secondary)
            Divider().frame(height: 14)
            Button(model.saveStatus) { _ = model.flushPendingSaves() }.buttonStyle(.plain)
                .foregroundStyle(model.saveStatus == "Save failed" ? Color.orange : Color.secondary)
        }.font(.caption).padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.aperture").font(.system(size: 64)).foregroundStyle(.tint)
            Text("Your photographs. Your eye.").font(.largeTitle.weight(.semibold))
            Text("Cull, compare, and edit on your Mac.\nOriginals stay untouched.")
                .font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Open a photo folder…", action: model.showOpenPanel).buttonStyle(.borderedProminent).controlSize(.large)
            Toggle("Include subfolders", isOn: Binding(get: { model.recursive }, set: { model.recursive = $0 })).toggleStyle(.checkbox)
            if !model.recentAlbums.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RECENT ALBUMS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(model.recentAlbums.prefix(5)) { album in
                        Button { model.openRecent(album) } label: {
                            HStack { Image(systemName: "folder"); Text(album.title); Spacer(); Text("\(album.count) photos").foregroundStyle(.secondary) }
                        }.buttonStyle(.plain).padding(7)
                    }
                }.frame(width: 380).padding(.top, 12)
            }
            Text("P / X / U  Pick / reject / clear   ·   1–5  Stars   ·   B  Before / after   ·   ⌘Z  Undo")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 16)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard model.folder != nil, !model.isOpening, event.window === model.window,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              ReviewKeyboardNavigation.allows(event.window?.firstResponder, mode: model.mode) else { return false }
        switch event.keyCode {
        case 123: model.selectPrevious(); return true
        case 124: model.selectNext(); return true
        case 125: model.selectNextSection(); return true
        case 126: model.selectPreviousSection(); return true
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "p": model.setDecision(.pick)
        case "x": model.setDecision(.reject)
        case "u": model.setDecision(.undecided)
        case "f": model.showFaceBoxes.toggle()
        case "b": model.showOriginal.toggle()
        case "z": model.zoom = model.zoom == .fit ? .actual : .fit
        case "n": model.mode = .compare; model.prepareComparison()
        case "e": model.mode = .edit
        case "0"..."5": model.setRating(Int(event.charactersIgnoringModifiers ?? "0") ?? 0)
        default: return false
        }
        return true
    }
}

protocol ReviewKeyboardResponder: AnyObject {}

enum ReviewKeyboardNavigation {
    static func allows(_ responder: NSResponder?, mode: WorkspaceMode) -> Bool {
        guard !(responder is NSText), !(responder is NSControl) else { return false }
        return mode != .edit || responder is ReviewKeyboardResponder
    }
}

struct CompareWorkspaceView: View {
    @Environment(LibraryModel.self) private var model
    var body: some View {
        if model.comparisonItems.count < 2 {
            ContentUnavailableView("Choose photos to compare", systemImage: "rectangle.split.2x1", description: Text("⌘-click two to four thumbnails, or choose Compare this group."))
        } else {
            GeometryReader { geometry in
                let columns = model.comparisonItems.count == 2 ? 2 : 2
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns), spacing: 2) {
                    ForEach(model.comparisonItems) { item in
                        VStack(spacing: 0) {
                            ZoomablePhotoView(item: item, recipe: model.showOriginal ? .identity : model.recipe(for: item), zoom: model.zoom,
                                              showFaceBoxes: model.showFaceBoxes, keyFace: model.keyFace(for: item))
                            HStack {
                                Text(item.fileName).lineLimit(1)
                                Spacer()
                                Button { model.select(item.id); model.mode = .edit } label: { Image(systemName: "slider.horizontal.3") }.help("Edit this photo")
                                Button { model.setDecision(.pick, for: item.id) } label: { Image(systemName: "checkmark") }.help("Pick this photo")
                            }.font(.caption).padding(8)
                        }.frame(height: max(160, geometry.size.height / (model.comparisonItems.count > 2 ? 2 : 1)))
                    }
                }
            }.background(.black)
        }
    }
}

final class KeyMonitor {
    private var token: Any?
    func start(_ handler: @escaping (NSEvent) -> Bool) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in MainActor.assumeIsolated { handler(event) } ? nil : event }
    }
    func stop() { if let token { NSEvent.removeMonitor(token) }; token = nil }
}

private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { let view = NSView(); DispatchQueue.main.async { onWindow(view.window) }; return view }
    func updateNSView(_ nsView: NSView, context: Context) { DispatchQueue.main.async { onWindow(nsView.window) } }
}
