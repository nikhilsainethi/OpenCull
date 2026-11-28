import AppKit
import CullCore
import PhotosUI
import SwiftUI

struct ContentView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ApertureMenuState.self) private var aperture
    @State private var keyMonitor = KeyMonitor()
    @State private var exportSheet = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var importingPhotos = false
    @State private var importSheet = false
    @State private var isDropTargeted = false
    @State private var photoImportID = UUID()
    @State private var photoImportTask: Task<Void, Never>?

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
        .environment(model)
        .photoDropDestination(isEnabled: model.canImport, cancellationID: model.importCancellationID, onFiles: { payload in
            Task {
                defer { Task.detached { payload.cleanup() } }
                if let receipt = payload.receiptID, !model.finishDropReceipt(receipt) { return }
                await model.importFiles(payload.urls, source: .files)
            }
        }, onFailure: { message in
            model.alert = AlertMessage(title: "Drop needs a local file", message: message)
        }, onTargeted: { isDropTargeted = $0 }, onReceiving: { model.beginDropReceipt($0) },
           onReceiptEnded: { model.finishDropReceipt($0) })
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12).stroke(.tint, lineWidth: 4).padding(8).allowsHitTesting(false)
            }
        }
        .frame(minWidth: 1080, minHeight: 680)
        .disabled(model.isOpening || model.isImporting)
        .overlay {
            if model.isOpening || model.isImporting {
                VStack(spacing: 12) {
                    ProgressView(model.isImporting ? model.importProgress : "Opening photo folder…")
                    Text(model.isImporting ? "Building a local album. Your current album stays available if you cancel." : "Reading files and saved choices. You can cancel without changing the current album.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(model.isImporting ? "Cancel import" : "Cancel opening") {
                        if model.isImporting {
                            photoImportTask?.cancel(); photoImportID = UUID(); photoImportTask = nil
                            importingPhotos = false; photoSelection = []; model.cancelImport()
                        }
                        else { model.cancelOpening() }
                    }
                }.padding(24).frame(width: 340).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .overlay {
            ApertureMenuOverlay(menu: aperture, items: ApertureItem.items(for: aperture.page, model: model), onActivate: activateApertureItem)
        }
        .background(AperturePointerAnchor(menu: aperture))
        .background(WindowReader { model.window = $0 })
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    Button("Open folder…", action: model.showOpenPanel)
                    Button("Import photos or ZIP…") { importSheet = true }
                    Toggle("Include subfolders", isOn: $model.recursive)
                    if !model.recentAlbums.isEmpty {
                        Divider()
                        ForEach(model.recentAlbums) { album in
                            Button("\(album.title) · \(album.count) photos") { model.openRecent(album) }
                        }
                    }
                } label: { Label("Albums", systemImage: "folder") }
                .disabled(model.isChoosingDestination || model.isExporting || model.isImporting || model.isOpening)
            }
            ToolbarItem {
                Button { importSheet = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .disabled(!model.canImport || importingPhotos)
            }
            ToolbarItem(placement: .principal) {
                Picker("Workspace", selection: $model.mode) {
                    ForEach(WorkspaceMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
                }.pickerStyle(.segmented).frame(width: 310).disabled(model.folder == nil)
            }
            ToolbarItem {
                Button { model.acceptSuggestions() } label: { Label("Accept", systemImage: "wand.and.stars") }
                    .disabled(model.isChoosingDestination || model.folder == nil || model.isAnalyzing || model.isExporting || model.isOpening)
                    .help("Apply completed suggestions; uncertain photos stay undecided. Undo is available.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { exportSheet = true } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                    .disabled(model.isChoosingDestination || model.folder == nil || model.isExporting || model.isImporting || model.isOpening)
            }
        }
        .sheet(isPresented: $importSheet) { ImportSourcesView(photoSelection: $photoSelection) }
        .sheet(isPresented: $exportSheet) { ExportSheet() }
        .alert(item: $model.alert) { Alert(title: Text($0.title), message: Text($0.message)) }
        .onChange(of: photoSelection) { _, selection in
            guard !selection.isEmpty else { return }
            importingPhotos = true
            let request = UUID(); photoImportID = request
            photoImportTask = Task {
                var album: URL?
                defer {
                    if let album { Task.detached { try? FileManager.default.removeItem(at: album) } }
                    if photoImportID == request { importingPhotos = false; photoSelection = []; photoImportTask = nil }
                }
                do {
                    let destination = try model.beginPhotosImport()
                    album = destination
                    var metadata: [String: PhotoImportMetadata] = [:]
                    var budget = try PhotoSelectionBudget(selectionCount: selection.count)
                    for (index, item) in selection.enumerated() {
                        try Task.checkCancellation()
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                        try Task.checkCancellation()
                        try budget.receive(byteCount: data.count)
                        let url = try await Task.detached(priority: .userInitiated) {
                            try LibraryModel.storeImportedImage(data, index: index, in: destination)
                        }.value
                        metadata[url.standardizedFileURL.path] = PhotoImportMetadata(assetIdentifier: item.itemIdentifier,
                            representationQuality: "System picker representation; original quality unverified")
                    }
                    try Task.checkCancellation()
                    await model.finishPhotosImport(destination, expectedStaging: destination, metadataByPath: metadata)
                } catch {
                    await model.finishPhotosImport(nil, expectedStaging: album)
                    if photoImportID == request && !(error is CancellationError) {
                        model.alert = AlertMessage(title: "Photos import needs attention", message: "The selected batch was not imported. " + error.localizedDescription)
                    }
                }
            }
        }
        .onAppear {
            keyMonitor.start(handleKey)
            let arguments = CommandLine.arguments
            if let index = arguments.firstIndex(of: "--open"), index + 1 < arguments.count {
                Task { await model.open(URL(fileURLWithPath: arguments[index + 1])) }
            }
        }
        .onDisappear { photoImportTask?.cancel(); model.cancelImport(); keyMonitor.stop(); model.cancelDestinationSelection(); model.cancelOpening(); _ = model.flushPendingSaves() }
        .onChange(of: importSheet || exportSheet) { _, sheetShown in
            aperture.isBlocked = sheetShown
            if sheetShown { aperture.dismiss() }
        }
        .onChange(of: model.isImporting || model.isOpening || model.isChoosingDestination) { _, busy in
            if busy { aperture.dismiss() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            // A held Space key cannot be released into a window that lost focus.
            if (note.object as? NSWindow) === model.window { aperture.dismiss() }
        }
    }

    // MARK: - Aperture menu

    private var canOpenAperture: Bool {
        !aperture.isBlocked && !model.isOpening && !model.isImporting && !model.isChoosingDestination
    }

    private func handleApertureKey(_ event: NSEvent) -> Bool {
        guard let window = model.window, event.window === window else { return false }
        guard let command = ApertureKeyCommand.interpret(
            type: event.type, keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags, isRepeat: event.type == .keyDown && event.isARepeat,
            isPresented: aperture.isPresented, isHolding: aperture.isHolding,
            isEditingText: window.firstResponder is NSText, canOpen: canOpenAperture) else { return false }
        switch command {
        case .toggle: aperture.toggleAtPointer()
        case .beginHold: aperture.presentAtPointer(holding: true)
        case .endHold: if let index = aperture.endHold() { activateApertureItem(index) }
        case .back: aperture.back()
        case .activateHighlighted: if let index = aperture.highlighted { activateApertureItem(index) }
        case .move(let delta): aperture.moveHighlight(by: delta)
        case .choose(let index): activateApertureItem(index)
        case .swallow: break
        }
        return true
    }

    private func activateApertureItem(_ index: Int) {
        let items = ApertureItem.items(for: aperture.page, model: model)
        guard items.indices.contains(index) else { return }
        let item = items[index]
        guard item.isEnabled else { NSSound.beep(); return }
        if item.action == .albumActions { aperture.showPage(.albumActions); return }
        aperture.dismiss()
        perform(item.action)
    }

    private func perform(_ action: ApertureAction) {
        switch action {
        case .importPhotos: importSheet = true
        case .cull: model.mode = .cull
        case .compare: model.mode = .compare; model.prepareComparison()
        case .edit: model.mode = .edit
        case .accept: model.acceptSuggestions()
        case .albumActions: aperture.showPage(.albumActions)
        case .mergeGroup: model.mergeSelectedGroup()
        case .splitGroup: model.splitSelectedGroup()
        case .resetGroups: model.resetGroups()
        case .findDuplicates: model.findExactDuplicates()
        case .suggestTarget: model.suggestTargetCount()
        case .retryAnalysis: model.retryAnalysis()
        }
    }

    private var albumBar: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            Image(systemName: "camera.aperture").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.folder?.lastPathComponent ?? "Album").font(.headline)
                Text("\(model.counts.total) photos · \(model.visibleItems.count) visible").font(.caption).foregroundStyle(.secondary)
                if let manifest = model.importManifest { Text(manifest.sourceSummary).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            Picker("Shooting intent", selection: $model.scoring.shootingIntent) {
                ForEach(ShootingIntent.allCases) { Text($0.title).tag($0) }
            }.frame(maxWidth: 245).help(model.scoring.shootingIntent.help)
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
            else if model.isImporting { ProgressView().controlSize(.small); Text(model.importProgress) }
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
            Button("Import from Files, Photos or Google Photos…") { importSheet = true }.controlSize(.large)
            Text("Or drop local photos, folders or ZIPs here.").font(.caption).foregroundStyle(.secondary)
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
            Text("Hold Space or press ⌘K for the aperture menu")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if handleApertureKey(event) { return true }
        guard event.type == .keyDown else { return false }
        guard model.folder != nil, !model.isImporting, !model.isOpening, !model.isChoosingDestination, let reviewWindow = model.window, event.window === reviewWindow else { return false }
        if ReviewKeyboardNavigation.handleSelectAll(event, responder: event.window?.firstResponder, workspace: model.selectAllVisible) { return true }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
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
    @MainActor static func handleSelectAll(_ event: NSEvent, responder: NSResponder?, workspace: () -> Void) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "a" else { return false }
        // SwiftUI's competing native/custom menu shortcuts can bypass the
        // custom command. Route this window's event directly to its text editor.
        EditingUndoRouter.selectAll(responder, workspace: workspace)
        return true
    }
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
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in MainActor.assumeIsolated { handler(event) } ? nil : event }
    }
    func stop() { if let token { NSEvent.removeMonitor(token) }; token = nil }
}

private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { let view = NSView(); DispatchQueue.main.async { onWindow(view.window) }; return view }
    func updateNSView(_ nsView: NSView, context: Context) { DispatchQueue.main.async { onWindow(nsView.window) } }
}
