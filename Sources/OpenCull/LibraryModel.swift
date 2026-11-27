import AppKit
import CullCore
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, undecided, picks, rejects, suggestedPicks, flagged, review, edited
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All photos"; case .undecided: "Undecided"; case .picks: "Picks"
        case .rejects: "Rejects"; case .suggestedPicks: "Suggested picks"; case .flagged: "Has issues"
        case .review: "Needs review"; case .edited: "Edited"
        }
    }
    func matches(_ item: PhotoItem) -> Bool {
        switch self {
        case .all, .edited: true
        case .undecided: item.decision == .undecided
        case .picks: item.decision == .pick
        case .rejects: item.decision == .reject
        case .suggestedPicks: item.suggestion == .pick
        case .flagged: !item.issues.isEmpty
        case .review: item.needsReview
        }
    }
}

struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct GridSection: Identifiable {
    let id: String
    let title: String?
    let items: [PhotoItem]
}

@MainActor @Observable
final class LibraryModel {
    private(set) var folder: URL?
    private(set) var items: [PhotoItem] = []
    var selectedID: PhotoItem.ID?
    var selection: Set<String> = []
    var filter: LibraryFilter = .all { didSet { reconcileSelection() } }
    var searchText = "" { didSet { reconcileSelection() } }
    var mode: WorkspaceMode = .cull { didSet { if mode == .compare { prepareComparison() } } }
    var zoom: ZoomMode = .fit
    var showOriginal = false
    var showGroups = true
    var showFaceBoxes = false
    var recursive = false
    var autoAdvance = true { didSet { defaults.set(autoAdvance, forKey: "autoAdvance") } }
    var usePreferences = false { didSet { defaults.set(usePreferences, forKey: "usePreferences"); reevaluate() } }
    var targetCount = 50
    private(set) var isAnalyzing = false
    private(set) var analyzedCount = 0
    private(set) var isExporting = false
    private(set) var exportProgress = ""
    private(set) var isFindingDuplicates = false
    private(set) var isImporting = false
    private(set) var layoutVersion = 0
    private(set) var editRevision = 0
    private(set) var saveStatus = "Saved"
    private(set) var hasUnsavedChanges = false
    private(set) var recentAlbums: [RecentAlbum] = []
    private(set) var styles: [SavedStyle] = []
    private(set) var preference = PreferenceProfile()
    var alert: AlertMessage?
    var grouping: GroupingOptions { didSet { optionsChanged() } }
    var scoring: ScoringOptions { didSet { optionsChanged() } }
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let io: WorkspaceIO
    @ObservationIgnored private let analyzePhoto: @Sendable (URL, URL?) throws -> PhotoAnalysis
    @ObservationIgnored private var store: SessionStore?
    @ObservationIgnored private var analysisCache: [String: PhotoAnalysis] = [:]
    @ObservationIgnored private var fingerprints: [String: String] = [:]
    private(set) var records: [String: PhotoWorkspaceRecord] = [:]
    @ObservationIgnored private var examples: [String: PreferenceExample] = [:]
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var indexByID: [String: Int] = [:]
    private var undoStack: [WorkspaceSnapshot] = []
    private var redoStack: [WorkspaceSnapshot] = []
    @ObservationIgnored private var lastEditKey: String?
    @ObservationIgnored private var lastEditDate = Date.distantPast
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoTitle: String { undoStack.last.map { "Undo \($0.name)" } ?? "Undo" }
    var redoTitle: String { redoStack.last.map { "Redo \($0.name)" } ?? "Redo" }

    init(appDataDirectory: URL? = nil, defaults: UserDefaults = .standard,
         analyze: @escaping @Sendable (URL, URL?) throws -> PhotoAnalysis = { try PhotoAnalyzer().analyze(url: $0, fallback: $1) }) {
        self.defaults = defaults
        analyzePhoto = analyze
        let root = appDataDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenCull", isDirectory: true)
        io = WorkspaceIO(root: root)
        grouping = defaults.data(forKey: "grouping").flatMap { try? JSONDecoder().decode(GroupingOptions.self, from: $0) } ?? GroupingOptions()
        scoring = defaults.data(forKey: "scoring").flatMap { try? JSONDecoder().decode(ScoringOptions.self, from: $0) } ?? ScoringOptions()
        autoAdvance = defaults.object(forKey: "autoAdvance") as? Bool ?? true
        usePreferences = defaults.bool(forKey: "usePreferences")
        do {
            if let global = try io.read(GlobalWorkspaceDocument.self, at: io.globalURL) {
                recentAlbums = global.recents
                styles = global.styles
                examples = global.examples
                rebuildPreference()
            }
        } catch { reportSaveError(error) }
    }

    var visibleItems: [PhotoItem] { items.filter(matches) }
    var selectedItem: PhotoItem? {
        guard let id = selectedID, let index = indexByID[id], matches(items[index]) else { return nil }
        return items[index]
    }
    var selectedItems: [PhotoItem] {
        let ids = selection.isEmpty ? Set([selectedID].compactMap { $0 }) : selection
        return visibleItems.filter { ids.contains($0.id) }
    }
    var comparisonItems: [PhotoItem] { Array(selectedItems.prefix(4)) }
    var selectedRecipe: EditRecipe { selectedItem.map { recipe(for: $0) } ?? .identity }
    var counts: (total: Int, picks: Int, rejects: Int, undecided: Int) {
        let picks = items.filter { $0.decision == .pick }.count
        let rejects = items.filter { $0.decision == .reject }.count
        return (items.count, picks, rejects, items.count - picks - rejects)
    }
    var sections: [GridSection] {
        guard showGroups else { return [GridSection(id: "all", title: nil, items: visibleItems)] }
        var result: [GridSection] = []
        for item in visibleItems {
            let id = item.groupSize > 1 ? "group-\(item.groupID ?? -1)" : "single-\(item.id)"
            if result.last?.id == id {
                let old = result.removeLast()
                result.append(GridSection(id: id, title: old.title, items: old.items + [item]))
            } else {
                result.append(GridSection(id: id, title: item.groupSize > 1 ? "Similar shots · \(item.groupSize)" : nil, items: [item]))
            }
        }
        return result
    }
    private func matches(_ item: PhotoItem) -> Bool {
        guard filter.matches(item) else { return false }
        if filter == .edited && recipe(for: item).isIdentity { return false }
        let words = searchText.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = ([item.fileName] + (item.analysis?.labels ?? []) + item.issues.map(\.label)).joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
    func recipe(for item: PhotoItem) -> EditRecipe { records[item.id]?.recipe ?? .identity }
    func keyFace(for item: PhotoItem) -> Int? { records[item.id]?.keyFace }
    func groupMaxSharpness(for item: PhotoItem) -> Float? {
        guard let group = item.groupID, item.groupSize > 1 else { return nil }
        return items.filter { $0.groupID == group }.compactMap { $0.analysis?.subjectSharpness }.max()
    }
    func select(_ id: String, extending: Bool = false) {
        guard let index = indexByID[id], matches(items[index]) else { return }
        if extending {
            if selection.contains(id), selection.count > 1 { selection.remove(id) } else { selection.insert(id) }
        } else { selection = [id] }
        selectedID = selection.contains(id) ? id : selectedItems.first?.id
        if mode == .compare { capComparisonSelection() }
    }
    func selectAllVisible() { selection = Set(visibleItems.map(\.id)); selectedID = visibleItems.first?.id }
    private func reconcileSelection() {
        let visible = visibleItems
        let ids = Set(visible.map(\.id))
        selection.formIntersection(ids)
        if selectedID.map({ !ids.contains($0) }) ?? true {
            selectedID = visible.first(where: { selection.contains($0.id) })?.id ?? visible.first?.id
        }
        if let selectedID { selection.insert(selectedID) }
        if selection.isEmpty, let selectedID { selection = [selectedID] }
        if mode == .compare { capComparisonSelection() }
    }

    // MARK: Import and analysis
    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Open album"; panel.message = "Choose a folder of photos"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func open(_ url: URL) {
        guard !isExporting, !isImporting else { return }
        let scanned: [PhotoItem]
        do { scanned = try PhotoScanner.scan(folder: url, recursive: recursive) }
        catch { alert = AlertMessage(title: "Could not open folder", message: error.localizedDescription); return }
        guard flushPendingSaves() else { return }
        analysisTask?.cancel()
        generation = UUID()
        isAnalyzing = false
        let newStore = SessionStore(folder: url, baseDirectory: io.root.appendingPathComponent("Sessions"))
        var decisions: [String: SessionStore.Entry] = [:]
        var workspace = WorkspaceDocument()
        var messages: [String] = []
        do { decisions = try newStore.readDecisions() } catch { messages.append(error.localizedDescription) }
        do { analysisCache = try newStore.readAnalysis() } catch { analysisCache = [:]; messages.append(error.localizedDescription) }
        do { workspace = try io.read(WorkspaceDocument.self, at: newStore.directory.appendingPathComponent("workspace.json")) ?? WorkspaceDocument() }
        catch { messages.append(error.localizedDescription) }
        fingerprints = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, newStore.fingerprint(for: $0)) })
        records = [:]
        var loaded = scanned
        var legacy = 0, changed = 0
        for i in loaded.indices {
            let id = loaded[i].id, key = newStore.key(for: loaded[i].url), fingerprint = fingerprints[id]!
            if let entry = decisions[key] {
                if entry.fingerprint == fingerprint || entry.fingerprint == nil {
                    loaded[i].decision = entry.decision; loaded[i].rating = entry.rating
                    if entry.fingerprint == nil { legacy += 1 }
                } else { changed += 1 }
            }
            if let record = workspace.records[key], record.fingerprint == fingerprint { records[id] = record }
            else { records[id] = PhotoWorkspaceRecord(fingerprint: fingerprint) }
            loaded[i].analysis = analysisCache[newStore.analysisKey(for: loaded[i])]
        }
        folder = url; store = newStore; items = loaded
        editRevision &+= 1
        undoStack = []; redoStack = []; lastEditKey = nil
        filter = .all; searchText = ""; selection = []; selectedID = nil
        reevaluate(); reconcileSelection()
        window?.title = "\(url.lastPathComponent) — OpenCull"
        recentAlbums.removeAll { $0.path == url.path }
        recentAlbums.insert(RecentAlbum(path: url.path, opened: Date(), recursive: recursive, count: items.count), at: 0)
        recentAlbums = Array(recentAlbums.prefix(12))
        if legacy > 0 { messages.append("Restored \(legacy) legacy choices without file identity. Review them before export; future saves track identity.") }
        if changed > 0 { messages.append("\(changed) files changed since the saved choices. Their old choices were not applied.") }
        if items.isEmpty { messages.append("No supported photos were found. Enable Include subfolders to scan nested folders.") }
        if !messages.isEmpty { alert = AlertMessage(title: "Album opened with notes", message: messages.joined(separator: "\n\n")) }
        scheduleSave()
        startAnalysis()
    }
    func openRecent(_ album: RecentAlbum) { recursive = album.recursive; open(URL(fileURLWithPath: album.path)) }
    func beginPhotosImport() throws -> URL {
        guard !isImporting, !isExporting else { throw CocoaError(.userCancelled) }
        let album = io.root.appendingPathComponent("Imports/Photos-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        isImporting = true
        return album
    }
    func finishPhotosImport(_ album: URL?) {
        isImporting = false
        if let album { open(album) }
    }
    nonisolated static func storeImportedImage(_ data: Data, index: Int, in album: URL) throws {
        guard index >= 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source),
              let ext = UTType(type as String)?.preferredFilenameExtension,
              ImageLoader.supportedExtensions.contains(ext.lowercased()) else { throw CocoaError(.fileReadCorruptFile) }
        let destination = album.appendingPathComponent(String(format: "Photo_%05d", index + 1)).appendingPathExtension(ext)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        try data.write(to: destination, options: .atomic)
    }
    private func startAnalysis() {
        struct Job: Sendable { let id: String; let url: URL; let fallback: URL?; let fingerprint: String; let cacheKey: String }
        guard let store else { return }
        let jobs = items.filter { $0.analysis == nil }.map {
            Job(id: $0.id, url: $0.url, fallback: $0.companions.first { !ImageLoader.isRaw($0) },
                fingerprint: fingerprints[$0.id] ?? store.fingerprint(for: $0), cacheKey: store.analysisKey(for: $0))
        }
        analyzedCount = items.count - jobs.count
        guard !jobs.isEmpty else { return }
        isAnalyzing = true
        let token = generation, analyze = analyzePhoto
        let concurrency = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))
        analysisTask = Task { [weak self] in
            await withTaskGroup(of: (Job, Result<PhotoAnalysis, Error>).self) { group in
                var next = 0
                func enqueue() {
                    guard next < jobs.count, !Task.isCancelled else { return }
                    let job = jobs[next]; next += 1
                    group.addTask(priority: .utility) { (job, Result { try analyze(job.url, job.fallback) }) }
                }
                for _ in 0..<concurrency { enqueue() }
                for await (job, result) in group {
                    guard !Task.isCancelled, self?.generation == token else { group.cancelAll(); break }
                    self?.receive(id: job.id, fingerprint: job.fingerprint, cacheKey: job.cacheKey, result: result)
                    if (self?.analyzedCount ?? 0) % 20 == 0 { self?.reevaluate() }
                    enqueue()
                }
            }
            guard !Task.isCancelled, self?.generation == token else { return }
            self?.isAnalyzing = false
            self?.reevaluate()
            self?.saveAnalysisCache()
        }
    }
    private func receive(id: String, fingerprint: String, cacheKey: String, result: Result<PhotoAnalysis, Error>) {
        guard let index = indexByID[id] else { return }
        guard let store, store.fingerprint(for: items[index]) == fingerprint else {
            items[index].analysis = nil
            items[index].analysisError = "This photo changed during analysis. Reopen the album to analyze its new version."
            analyzedCount += 1
            return
        }
        switch result {
        case .success(let analysis):
            items[index].analysis = analysis; items[index].analysisError = nil
            analysisCache[cacheKey] = analysis
        case .failure(let error): items[index].analysisError = error.localizedDescription
        }
        analyzedCount += 1
    }
    func retryAnalysis() {
        guard !isAnalyzing else { return }
        for i in items.indices where items[i].analysisError != nil { items[i].analysisError = nil }
        startAnalysis()
    }
    private func reevaluate() {
        for i in items.indices {
            guard var analysis = items[i].analysis else { continue }
            if let face = records[items[i].id]?.keyFace, analysis.faces.indices.contains(face), let sharpness = analysis.faces[face].sharpness {
                analysis.subjectSharpness = sharpness
            } else {
                analysis.subjectSharpness = analysis.significantFaces.compactMap(\.sharpness).min() ?? analysis.sharpness
            }
            items[i].analysis = analysis
        }
        Scorer.evaluate(&items, grouping: grouping, scoring: scoring, preference: usePreferences ? preference : nil,
                        groupOverrides: records.compactMapValues { $0.manualGroup })
        items.sort {
            let a = $0.groupID ?? Int.max, b = $1.groupID ?? Int.max
            if a != b { return a < b }
            let da = $0.analysis?.captureDate ?? .distantFuture, db = $1.analysis?.captureDate ?? .distantFuture
            if da != db { return da < db }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        indexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        layoutVersion &+= 1; reconcileSelection()
    }
    private func optionsChanged() {
        defaults.set(try? JSONEncoder().encode(grouping), forKey: "grouping")
        defaults.set(try? JSONEncoder().encode(scoring), forKey: "scoring")
        reevaluate()
    }
    func resetOptions() { grouping = GroupingOptions(); scoring = ScoringOptions() }

    // MARK: Choices, history and culling controls
    func setDecision(_ decision: Decision) {
        setDecision(decision, targets: selectedItems, advance: mode != .compare)
    }
    func setDecision(_ decision: Decision, for id: String) {
        guard let index = indexByID[id], matches(items[index]) else { return }
        setDecision(decision, targets: [items[index]], advance: false)
    }
    private func setDecision(_ decision: Decision, targets: [PhotoItem], advance: Bool) {
        guard !targets.isEmpty else { return }
        let oldVisible = visibleItems.map(\.id), current = selectedID
        remember("\(decision == .pick ? "Pick" : decision == .reject ? "Reject" : "Clear") \(targets.count == 1 ? "photo" : "photos")")
        for target in targets { if let i = indexByID[target.id] { items[i].decision = decision } }
        recordExamples(for: targets.map(\.id)); reevaluate()
        if advance, targets.count == 1, autoAdvance, decision != .undecided, let current, let position = oldVisible.firstIndex(of: current) {
            let visible = Set(visibleItems.map(\.id))
            selectedID = oldVisible.dropFirst(position + 1).first(where: visible.contains) ?? oldVisible.prefix(position).reversed().first(where: visible.contains) ?? visibleItems.first?.id
            selection = Set([selectedID].compactMap { $0 })
        }
        scheduleSave()
    }
    func setRating(_ rating: Int) {
        let targets = selectedItems; guard !targets.isEmpty else { return }
        remember("Rate photos")
        for target in targets { if let i = indexByID[target.id] { items[i].rating = max(0, min(5, rating)) } }
        recordExamples(for: targets.map(\.id)); reevaluate(); scheduleSave()
    }
    func acceptSuggestions() {
        guard !isAnalyzing, !isExporting else { return }
        let targets = items.indices.filter { items[$0].decision == .undecided && items[$0].suggestion != .undecided && !items[$0].needsReview }
        guard !targets.isEmpty else { alert = AlertMessage(title: "Nothing ready to accept", message: "Uncertain or incomplete photos stay undecided for your review."); return }
        remember("Accept suggestions")
        for i in targets { items[i].decision = items[i].suggestion }
        reconcileSelection(); scheduleSave()
        alert = AlertMessage(title: "Suggestions applied", message: "\(targets.count) choices applied. Undo restores all of them. Photos needing review remain undecided.")
    }
    func suggestTargetCount() {
        guard !isAnalyzing else { return }
        let proposed = Scorer.cullToTarget(&items, count: targetCount)
        reconcileSelection(); layoutVersion &+= 1
        alert = AlertMessage(title: "Target selection ready", message: "\(proposed) suggested picks. Review these suggestions, then accept them. Your existing choices were preserved.")
    }
    func setKeyFace(_ index: Int?) {
        guard let item = selectedItem else { return }
        remember("Change focus subject"); records[item.id]?.keyFace = index; reevaluate(); scheduleSave()
    }
    func splitSelectedGroup() {
        let targets = selectedItems; guard !targets.isEmpty else { return }
        remember("Split groups")
        for item in targets { records[item.id]?.manualGroup = "single-\(UUID().uuidString)" }
        reevaluate(); scheduleSave()
    }
    func mergeSelectedGroup() {
        let targets = selectedItems; guard targets.count > 1 else { return }
        remember("Merge group"); let token = UUID().uuidString
        for item in targets { records[item.id]?.manualGroup = token }
        reevaluate(); scheduleSave()
    }
    func resetGroups() {
        remember("Reset groups")
        for id in records.keys { records[id]?.manualGroup = nil }
        reevaluate(); scheduleSave()
    }
    func findExactDuplicates() {
        guard !isAnalyzing, !isFindingDuplicates else { return }
        isFindingDuplicates = true
        let snapshot = items, token = generation
        Task {
            let result = await Task.detached(priority: .utility) { Result { try ExactDuplicateFinder.groups(in: snapshot) } }.value
            isFindingDuplicates = false
            guard generation == token else { return }
            switch result {
            case .success(let groups):
                remember("Group exact duplicates")
                for group in groups { let id = UUID().uuidString; for member in group { records[member]?.manualGroup = id } }
                reevaluate(); scheduleSave()
                alert = AlertMessage(title: "Duplicate scan finished", message: "Found \(groups.count) byte-identical groups across the album. No files were removed.")
            case .failure(let error): alert = AlertMessage(title: "Duplicate scan failed", message: error.localizedDescription)
            }
        }
    }
    func prepareComparison() {
        guard let selected = selectedItem else { return }
        if selectedItems.count >= 2 { capComparisonSelection(); return }
        let group = visibleItems.filter { $0.groupID == selected.groupID }
        if group.count > 1 { selection = Set(group.prefix(4).map(\.id)) }
        else {
            let visible = visibleItems, index = visible.firstIndex { $0.id == selected.id } ?? 0
            selection = Set(visible.dropFirst(index).prefix(4).map(\.id))
        }
        if let selectedID { selection.insert(selectedID) }
        capComparisonSelection()
    }
    private func capComparisonSelection() {
        guard selection.count > 4 else { return }
        var keep = Array(visibleItems.filter { selection.contains($0.id) }.prefix(4).map(\.id))
        if let selectedID, !keep.contains(selectedID) { keep[keep.count - 1] = selectedID }
        selection = Set(keep)
    }
    private func snapshot(_ name: String) -> WorkspaceSnapshot {
        WorkspaceSnapshot(name: name, decisions: Dictionary(uniqueKeysWithValues: items.map { ($0.id, DecisionState(decision: $0.decision, rating: $0.rating)) }), records: records, selected: selectedID, selection: selection)
    }
    private func remember(_ name: String) {
        undoStack.append(snapshot(name)); if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack = []; lastEditKey = nil
    }
    private func restore(_ state: WorkspaceSnapshot) {
        for i in items.indices { if let value = state.decisions[items[i].id] { items[i].decision = value.decision; items[i].rating = value.rating } }
        // Export is an external side effect, so its synchronization ledger must survive Undo.
        let previouslyExported = Set(records.filter { $0.value.exported }.map(\.key))
        records = state.records
        for id in previouslyExported { records[id]?.exported = true }
        selectedID = state.selected; selection = state.selection
        editRevision &+= 1
        recordExamples(for: items.map(\.id)); reevaluate(); scheduleSave()
    }
    func undo() { guard let state = undoStack.popLast() else { return }; redoStack.append(snapshot(state.name)); restore(state); lastEditKey = nil }
    func redo() { guard let state = redoStack.popLast() else { return }; undoStack.append(snapshot(state.name)); restore(state); lastEditKey = nil }

    // MARK: Editing
    func setRecipe(_ recipe: EditRecipe, name: String = "Edit photo", coalescing: String? = nil) {
        guard let item = selectedItem else { return }
        // Even a no-op Reset/Original is a new intent that cancels older async adjustments.
        editRevision &+= 1
        let edit = recipe.clamped()
        guard self.recipe(for: item) != edit else { return }
        let key = coalescing.map { item.id + "#" + $0 }
        if key == nil || key != lastEditKey || Date().timeIntervalSince(lastEditDate) > 0.8 { remember(name) }
        lastEditKey = key; lastEditDate = Date()
        records[item.id]?.recipe = edit; showOriginal = false; reconcileSelection(); scheduleSave()
    }
    func applyPreset(_ preset: EditingPreset) { setRecipe(preset.recipe, name: "Apply \(preset.title)") }
    func applyStyle(_ style: SavedStyle) {
        guard let item = selectedItem else { return }
        if let profile = style.profile {
            guard hasUsableStyleAnalysis(item), let analysis = item.analysis else { alert = AlertMessage(title: "Analysis needed", message: "Complete this photo's analysis before applying its adaptive profile."); return }
            var recipe = profile.recipe(for: analysis)
            recipe.crop = selectedRecipe.crop; recipe.rotation = selectedRecipe.rotation
            setRecipe(recipe, name: "Apply \(style.name)")
        } else { setRecipe(style.recipe, name: "Apply \(style.name)") }
    }
    private func hasUsableStyleAnalysis(_ item: PhotoItem) -> Bool {
        item.analysisError == nil && item.analysis.map { $0.analysisWarnings.isEmpty } == true
    }
    var adaptiveExampleCount: Int { selectedItems.filter { hasUsableStyleAnalysis($0) && !recipe(for: $0).isIdentity }.count }
    func saveAdaptiveStyle(name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let samples = selectedItems.compactMap { item -> AdaptiveStyleExample? in
            guard hasUsableStyleAnalysis(item), let analysis = item.analysis, !recipe(for: item).isIdentity else { return nil }
            return AdaptiveStyleExample(analysis: analysis, recipe: recipe(for: item))
        }
        do {
            let profile = try AdaptiveStyleProfile(examples: samples)
            styles.append(SavedStyle(name: String(title.prefix(60)), recipe: selectedRecipe, profile: profile))
            scheduleSave()
        } catch { alert = AlertMessage(title: "Could not learn this profile", message: error.localizedDescription) }
    }
    func applyAdaptiveStyle(_ style: SavedStyle, allPicks: Bool = false) {
        guard let profile = style.profile else { return }
        let requested = allPicks ? items.filter { $0.decision == .pick } : selectedItems
        let targets = requested.filter(hasUsableStyleAnalysis)
        guard !targets.isEmpty else { alert = AlertMessage(title: "No complete measurements", message: "Analyze the selected photos before applying an adaptive profile."); return }
        remember("Apply adaptive profile to \(targets.count) photos")
        for item in targets {
            var recipe = profile.recipe(for: item.analysis!)
            recipe.crop = self.recipe(for: item).crop; recipe.rotation = self.recipe(for: item).rotation
            records[item.id]?.recipe = recipe
        }
        editRevision &+= 1
        reconcileSelection(); scheduleSave()
        if requested.count != targets.count {
            alert = AlertMessage(title: "Adaptive profile applied", message: "Updated \(targets.count) photos; skipped \(requested.count - targets.count) with incomplete measurements.")
        }
    }
    func saveStyle(name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        styles.append(SavedStyle(name: String(title.prefix(60)), recipe: selectedRecipe)); scheduleSave()
    }
    func deleteStyle(_ id: UUID) { styles.removeAll { $0.id == id }; scheduleSave() }
    func applyEditToSelection(allPicks: Bool = false) {
        let targets = allPicks ? items.filter { $0.decision == .pick } : selectedItems
        guard !targets.isEmpty else { return }
        let recipe = selectedRecipe
        remember("Apply edits to \(targets.count) photos")
        for item in targets { records[item.id]?.recipe = recipe }
        editRevision &+= 1
        reconcileSelection(); scheduleSave()
    }
    func autoAdjust() {
        guard let item = selectedItem else { return }
        let id = item.id, token = generation, originalRecipe = recipe(for: item), revision = editRevision
        Task {
            let image = await PreviewCache.shared.image(for: item, size: 1600)
            guard generation == token, editRevision == revision, selectedID == id, recipe(for: item) == originalRecipe, let image else { return }
            let tone = PhotoEditor.autoAdjust(image: image)
            var merged = originalRecipe
            merged.exposure = tone.exposure; merged.highlights = tone.highlights; merged.shadows = tone.shadows
            setRecipe(merged, name: "Auto tone")
        }
    }

    // MARK: Durable state and preference adaptation
    private func recordExamples(for ids: [String]) {
        for id in ids {
            guard let i = indexByID[id], var analysis = items[i].analysis, let fingerprint = fingerprints[id] else { continue }
            let key = id + "#" + fingerprint
            guard items[i].decision != .undecided else { examples.removeValue(forKey: key); continue }
            analysis.featurePrint = nil; analysis.layoutSignature = nil
            examples[key] = PreferenceExample(analysis: analysis, decision: items[i].decision, rating: items[i].rating, updated: Date())
        }
        if examples.count > 2000 {
            let retained = examples.sorted { $0.value.updated > $1.value.updated }.prefix(2000)
            examples = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
        }
        rebuildPreference()
    }
    private func rebuildPreference() {
        var profile = PreferenceProfile()
        let chronological = examples.sorted {
            if $0.value.updated != $1.value.updated { return $0.value.updated < $1.value.updated }
            return $0.key < $1.key
        }
        for (key, sample) in chronological.suffix(600) {
            profile.record(analysis: sample.analysis, decision: sample.decision, rating: sample.rating, sampleID: key)
        }
        preference = profile
    }
    func resetPreference() { examples = [:]; rebuildPreference(); reevaluate(); scheduleSave() }
    private func scheduleSave() {
        hasUnsavedChanges = true; saveStatus = "Saving…"
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.saveNow()
        }
    }
    @discardableResult func flushPendingSaves() -> Bool {
        saveTask?.cancel(); saveTask = nil
        guard hasUnsavedChanges else { return true }
        return saveNow()
    }
    @discardableResult private func saveNow() -> Bool {
        do {
            if let store {
                var entries: [String: SessionStore.Entry] = [:], persistedRecords: [String: PhotoWorkspaceRecord] = [:]
                for item in items {
                    let key = store.key(for: item.url)
                    if item.decision != .undecided || item.rating > 0 {
                        entries[key] = SessionStore.Entry(decision: item.decision, rating: item.rating, fingerprint: fingerprints[item.id])
                    }
                    persistedRecords[key] = records[item.id]
                }
                try store.saveDecisions(entries)
                try io.write(WorkspaceDocument(records: persistedRecords), at: store.directory.appendingPathComponent("workspace.json"))
            }
            try io.write(GlobalWorkspaceDocument(recents: recentAlbums, styles: styles, examples: examples), at: io.globalURL)
            hasUnsavedChanges = false; saveStatus = "Saved"; return true
        } catch { reportSaveError(error); return false }
    }
    private func reportSaveError(_ error: Error) {
        saveStatus = "Save failed"; hasUnsavedChanges = true
        alert = AlertMessage(title: "Changes could not be saved", message: error.localizedDescription + "\nYour current work is still in this window. Retry saving before closing.")
    }
    private func saveAnalysisCache() {
        guard let store else { return }
        do { try store.saveAnalysis(analysisCache) }
        catch { alert = AlertMessage(title: "Analysis cache could not be saved", message: error.localizedDescription + "\nYour decisions are saved separately.") }
    }

    // MARK: Navigation
    func selectNext() { move(by: 1) }
    func selectPrevious() { move(by: -1) }
    private func move(by offset: Int) {
        let visible = visibleItems; guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.id == selectedID } ?? 0
        select(visible[max(0, min(visible.count - 1, index + offset))].id)
    }
    func selectNextSection() { moveGroup(by: 1) }
    func selectPreviousSection() { moveGroup(by: -1) }
    private func moveGroup(by offset: Int) {
        let visible = visibleItems
        var groups: [[PhotoItem]] = []
        for item in visible {
            if let last = groups.last?.last, item.groupID != nil, item.groupID == last.groupID { groups[groups.count - 1].append(item) }
            else { groups.append([item]) }
        }
        guard !groups.isEmpty else { return }
        let index = groups.firstIndex { $0.contains { $0.id == selectedID } } ?? 0
        select(groups[max(0, min(groups.count - 1, index + offset))][0].id)
    }

    // MARK: Export
    private func validateExportInputs(_ photos: [PhotoItem]) -> Bool {
        guard let store else { return false }
        let changed = photos.filter { fingerprints[$0.id] != store.fingerprint(for: $0) }
        guard changed.isEmpty else {
            alert = AlertMessage(title: "Photos changed since review", message: "Reopen the album and review these new file versions before exporting: " + changed.map(\.fileName).joined(separator: ", ") + ". Your original files were left untouched.")
            return false
        }
        return true
    }
    func writeSidecars() {
        guard !isExporting, !isAnalyzing, !isImporting else { return }
        let candidates = items.filter { $0.decision != .undecided || $0.rating > 0 || records[$0.id]?.exported == true }
        guard validateExportInputs(candidates), let store else { return }
        let expected = fingerprints
        let aliases = Dictionary(grouping: items) { XMPSidecar.sidecarURL(for: $0.url).standardizedFileURL.path }
        let ambiguous = candidates.filter { (aliases[XMPSidecar.sidecarURL(for: $0.url).standardizedFileURL.path]?.count ?? 0) > 1 }
        let ambiguousIDs = Set(ambiguous.map(\.id))
        let targets = candidates.filter { !ambiguousIDs.contains($0.id) }
        guard !targets.isEmpty else {
            alert = ambiguous.isEmpty
                ? AlertMessage(title: "Nothing to synchronize", message: "Pick, reject or rate photos first.")
                : AlertMessage(title: "Ambiguous sidecar names", message: ambiguous.map(\.fileName).joined(separator: ", ") + " share sidecar names with independent photos. Export rendered copies to preserve separate choices.")
            return
        }
        isExporting = true; exportProgress = "Writing metadata…"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ([String], [String]) in
                var done: [String] = [], errors: [String] = ambiguous.map { "\($0.fileName): multiple independent photos share this XMP name; export rendered copies instead." }
                for item in targets {
                    do {
                        guard expected[item.id] == store.fingerprint(for: item) else { throw CocoaError(.fileReadUnknown) }
                        let outcome = item.decision == .undecided && item.rating == 0
                            ? try XMPSidecar.clear(photo: item.url)
                            : try XMPSidecar.write(photo: item.url, decision: item.decision, rating: item.rating)
                        if outcome == .skippedUnsupportedExisting { errors.append("\(item.fileName): unsupported metadata layout") }
                        else { done.append(item.id) }
                    } catch { errors.append("\(item.fileName): \(error.localizedDescription)") }
                }
                return (done, errors)
            }.value
            for id in result.0 { records[id]?.exported = true }
            isExporting = false; exportProgress = ""; scheduleSave()
            alert = AlertMessage(title: result.1.isEmpty ? "Metadata synchronized" : "Metadata export needs attention", message: "Updated \(result.0.count) photos. Original image bytes were preserved." + (result.1.isEmpty ? "" : "\n\n" + result.1.joined(separator: "\n")))
        }
    }
    func copyPicks() {
        guard !isExporting, !isImporting else { return }
        let picks = items.filter { $0.decision == .pick }
        guard !picks.isEmpty, let destination = chooseDestination(message: "Copy \(picks.count) picked original photo bundles") else { return }
        copy(picks, to: destination)
    }
    func copy(_ photos: [PhotoItem], to destination: URL) {
        guard !isExporting, !isImporting, !photos.isEmpty else { return }
        guard validateExportInputs(photos), let store else { return }
        let expected = fingerprints
        if let folder, destination.resolvingSymlinksInPath().standardizedFileURL == folder.resolvingSymlinksInPath().standardizedFileURL {
            alert = AlertMessage(title: "Choose another folder", message: "Export to a different folder from your originals."); return
        }
        isExporting = true; exportProgress = "Copying originals…"
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Exporter.copy(photos, to: destination, validator: { expected[$0.id] == store.fingerprint(for: $0) })
            }.value
            isExporting = false; exportProgress = ""
            alert = AlertMessage(title: result.failures.isEmpty && result.warnings.isEmpty ? "Originals copied" : "Copy needs attention", message: "Copied \(result.copiedPhotos) complete photo bundles. Skipped \(result.skippedExisting) existing files.\n" + (result.failures + result.warnings).joined(separator: "\n"))
        }
    }
    func chooseDestination(message: String) -> URL? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "Export here"; panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
    func exportEdited(to destination: URL, format: ImageExportFormat, quality: Double, maxPixelSize: Int?, metadata: ExportMetadataPolicy, allPicks: Bool) {
        guard !isExporting, !isImporting else { return }
        let photos = allPicks ? items.filter { $0.decision == .pick } : selectedItems
        guard !photos.isEmpty else { alert = AlertMessage(title: "No photos selected", message: "Select photos or mark picks before exporting."); return }
        guard validateExportInputs(photos), let store else { return }
        let expected = fingerprints
        let jobs = photos.map { ($0, recipe(for: $0)) }
        isExporting = true; exportProgress = "Rendering 0 of \(jobs.count)…"
        Task {
            var outputs: [URL] = [], failures: [String] = [], fallbackNames: [String] = []
            for (index, job) in jobs.enumerated() {
                let result = await Task.detached(priority: .userInitiated) {
                    Result { () -> (URL, Bool) in
                        guard expected[job.0.id] == store.fingerprint(for: job.0) else { throw CocoaError(.fileReadUnknown) }
                        var lastError: Error = CocoaError(.fileReadCorruptFile)
                        for source in job.0.allFiles {
                            do {
                                let output = try PhotoEditor.export(url: source, recipe: job.1, to: destination, format: format, quality: quality, maxPixelSize: maxPixelSize, metadata: metadata)
                                do { try XMPSidecar.writeEmbedded(photo: output, decision: job.0.decision, rating: job.0.rating) }
                                catch { try? FileManager.default.removeItem(at: output); throw error }
                                guard expected[job.0.id] == store.fingerprint(for: job.0) else {
                                    try? FileManager.default.removeItem(at: output)
                                    throw CocoaError(.fileReadUnknown)
                                }
                                return (output, source != job.0.url)
                            } catch { lastError = error }
                        }
                        throw lastError
                    }
                }.value
                switch result {
                case .success(let output):
                    outputs.append(output.0)
                    if output.1 { fallbackNames.append(job.0.fileName) }
                case .failure(let error): failures.append("\(job.0.fileName): \(error.localizedDescription)")
                }
                exportProgress = "Rendering \(index + 1) of \(jobs.count)…"
            }
            isExporting = false; exportProgress = ""
            let fallbackNote = fallbackNames.isEmpty ? "" : "\nUsed companion images because these RAW sources could not render: \(fallbackNames.joined(separator: ", ")). The copies use the companion's resolution.\n"
            alert = AlertMessage(title: failures.isEmpty ? "Edited photos exported" : "Export needs attention", message: "Rendered \(outputs.count) of \(jobs.count) photos to \(destination.path). Originals were preserved.\n" + fallbackNote + failures.joined(separator: "\n"))
        }
    }
}
