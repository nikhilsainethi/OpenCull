import AppKit
import CullCore
import Observation
import SwiftUI

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, undecided, picks, rejects, suggestedPicks, flagged

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .undecided: return "Undecided"
        case .picks: return "Picks"
        case .rejects: return "Rejects"
        case .suggestedPicks: return "Suggested Picks"
        case .flagged: return "Has Issues"
        }
    }

    func matches(_ item: PhotoItem) -> Bool {
        switch self {
        case .all: return true
        case .undecided: return item.decision == .undecided
        case .picks: return item.decision == .pick
        case .rejects: return item.decision == .reject
        case .suggestedPicks: return item.suggestion == .pick
        case .flagged: return !item.issues.isEmpty
        }
    }
}

struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// A run of consecutive photos shown together in the grid.
struct GridSection: Identifiable {
    let id: String
    let title: String?
    let items: [PhotoItem]
}

@MainActor
@Observable
final class LibraryModel {
    var folder: URL?
    private(set) var items: [PhotoItem] = []
    var selectedID: PhotoItem.ID?
    var filter: LibraryFilter = .all
    var showGroups = true
    var showFaceBoxes = false
    var autoAdvance = true { didSet { UserDefaults.standard.set(autoAdvance, forKey: "autoAdvance") } }
    private(set) var isAnalyzing = false
    private(set) var analyzedCount = 0
    private(set) var isExporting = false
    /// Changes whenever grouping/scoring is recomputed, so the grid rebuilds its cells.
    private(set) var layoutVersion = 0
    var alert: AlertMessage?

    var grouping: GroupingOptions { didSet { optionsChanged() } }
    var scoring: ScoringOptions { didSet { optionsChanged() } }

    @ObservationIgnored private var store: SessionStore?
    @ObservationIgnored private var analysisCache: [String: PhotoAnalysis] = [:]
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var indexByID: [PhotoItem.ID: Int] = [:]
    @ObservationIgnored private let saveQueue = DispatchQueue(label: "OpenCull.save", qos: .utility)
    @ObservationIgnored weak var window: NSWindow?

    init() {
        let defaults = UserDefaults.standard
        grouping = defaults.data(forKey: "grouping").flatMap { try? JSONDecoder().decode(GroupingOptions.self, from: $0) } ?? GroupingOptions()
        scoring = defaults.data(forKey: "scoring").flatMap { try? JSONDecoder().decode(ScoringOptions.self, from: $0) } ?? ScoringOptions()
        autoAdvance = defaults.object(forKey: "autoAdvance") as? Bool ?? true
    }

    // MARK: - Derived data

    var visibleItems: [PhotoItem] { items.filter(filter.matches) }

    var selectedItem: PhotoItem? { selectedID.flatMap { indexByID[$0] }.map { items[$0] } }

    var sections: [GridSection] {
        let visible = visibleItems
        guard showGroups else { return [GridSection(id: "all", title: nil, items: visible)] }
        var result: [GridSection] = []
        var run: [PhotoItem] = []
        func flush() {
            guard let first = run.first else { return }
            let isGroup = first.groupSize > 1 && first.groupID != nil
            let title = isGroup ? "Similar shots · \(first.groupSize) photos" : nil
            let id = isGroup ? "group-\(first.groupID ?? -1)" : "singles-\(first.id)"
            result.append(GridSection(id: id, title: title, items: run))
            run = []
        }
        for item in visible {
            if let previous = run.last {
                let previousIsGroup = previous.groupSize > 1
                let itemIsGroup = item.groupSize > 1
                let sameGroup = previousIsGroup && itemIsGroup && previous.groupID == item.groupID
                let bothSingles = !previousIsGroup && !itemIsGroup
                if !(sameGroup || bothSingles) { flush() }
            }
            run.append(item)
        }
        flush()
        return result
    }

    var counts: (total: Int, picks: Int, rejects: Int, undecided: Int) {
        var picks = 0, rejects = 0
        for item in items {
            if item.decision == .pick { picks += 1 } else if item.decision == .reject { rejects += 1 }
        }
        return (items.count, picks, rejects, items.count - picks - rejects)
    }

    func groupMaxSharpness(for item: PhotoItem) -> Float? {
        guard let group = item.groupID, item.groupSize > 1 else { return nil }
        return items.filter { $0.groupID == group }.compactMap { $0.analysis?.subjectSharpness }.max()
    }

    // MARK: - Opening a folder

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder of photos to cull"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        analysisTask?.cancel()
        analysisTask = nil
        isAnalyzing = false

        let store = SessionStore(folder: url)
        let scanned: [PhotoItem]
        do {
            scanned = try PhotoScanner.scan(folder: url)
        } catch {
            alert = AlertMessage(title: "Could not open folder", message: error.localizedDescription)
            return
        }

        folder = url
        self.store = store
        analysisCache = store.loadAnalysis()
        let decisions = store.loadDecisions()

        var loaded = scanned
        for i in loaded.indices {
            if let entry = decisions[store.key(for: loaded[i].url)] {
                loaded[i].decision = entry.decision
                loaded[i].rating = entry.rating
            }
            loaded[i].analysis = analysisCache[store.analysisKey(for: loaded[i])]
        }
        items = loaded
        filter = .all
        reevaluate()
        selectedID = visibleItems.first?.id
        window?.title = url.lastPathComponent

        if items.isEmpty {
            alert = AlertMessage(title: "No photos found",
                                 message: "This folder has no supported photos (RAW, JPEG, HEIC, TIFF or PNG). Subfolders are not scanned.")
        }
        startAnalysis()
    }

    // MARK: - Analysis

    private func startAnalysis() {
        struct Job: Sendable { let id: String; let url: URL; let fallback: URL? }
        let jobs = items.filter { $0.analysis == nil }.map { item in
            Job(id: item.id, url: item.url, fallback: item.companions.first { !ImageLoader.isRaw($0) })
        }
        analyzedCount = items.count - jobs.count
        guard !jobs.isEmpty else { return }
        isAnalyzing = true

        let analyzer = PhotoAnalyzer()
        let concurrency = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
        analysisTask = Task { [weak self] in
            await withTaskGroup(of: (String, Result<PhotoAnalysis, Error>).self) { group in
                var next = 0
                func enqueue() {
                    guard next < jobs.count else { return }
                    let job = jobs[next]
                    next += 1
                    group.addTask(priority: .utility) {
                        (job.id, Result { try analyzer.analyze(url: job.url, fallback: job.fallback) })
                    }
                }
                for _ in 0..<concurrency { enqueue() }

                var sinceUpdate = 0
                for await (id, result) in group {
                    if Task.isCancelled { group.cancelAll(); break }
                    self?.receive(id: id, result: result)
                    sinceUpdate += 1
                    if sinceUpdate >= 40 {
                        sinceUpdate = 0
                        self?.reevaluate()
                        self?.saveAnalysisCache()
                    }
                    enqueue()
                }
            }
            guard !Task.isCancelled else { return }
            self?.finishAnalysis()
        }
    }

    private func receive(id: String, result: Result<PhotoAnalysis, Error>) {
        guard let index = indexByID[id] else { return }
        switch result {
        case .success(let analysis):
            items[index].analysis = analysis
            if let store { analysisCache[store.analysisKey(for: items[index])] = analysis }
        case .failure(let error):
            items[index].analysisError = error.localizedDescription
        }
        analyzedCount += 1
    }

    private func finishAnalysis() {
        isAnalyzing = false
        reevaluate()
        saveAnalysisCache()
    }

    private func reevaluate() {
        Scorer.evaluate(&items, grouping: grouping, scoring: scoring)
        items.sort { a, b in
            let ga = a.groupID ?? Int.max, gb = b.groupID ?? Int.max
            if ga != gb { return ga < gb }
            let da = a.analysis?.captureDate ?? .distantFuture, db = b.analysis?.captureDate ?? .distantFuture
            if da != db { return da < db }
            return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
        }
        indexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        layoutVersion &+= 1
    }

    private func optionsChanged() {
        let encoder = JSONEncoder()
        UserDefaults.standard.set(try? encoder.encode(grouping), forKey: "grouping")
        UserDefaults.standard.set(try? encoder.encode(scoring), forKey: "scoring")
        reevaluate()
    }

    func resetOptions() {
        grouping = GroupingOptions()
        scoring = ScoringOptions()
    }

    // MARK: - Decisions

    func setDecision(_ decision: Decision) {
        guard let id = selectedID, let index = indexByID[id] else { return }
        let following = neighbour(of: id)
        items[index].decision = decision
        saveDecisions()
        if (autoAdvance && decision != .undecided) || !filter.matches(items[index]) {
            selectedID = following ?? (filter.matches(items[index]) ? id : nil)
        }
    }

    func setRating(_ rating: Int) {
        guard let id = selectedID, let index = indexByID[id] else { return }
        items[index].rating = max(0, min(5, rating))
        saveDecisions()
    }

    /// Applies the analyzer's suggestions to every photo that has no decision yet.
    func acceptSuggestions() {
        var changed = 0
        for i in items.indices where items[i].decision == .undecided && items[i].suggestion != .undecided {
            items[i].decision = items[i].suggestion
            changed += 1
        }
        saveDecisions()
        if let id = selectedID, let index = indexByID[id], !filter.matches(items[index]) {
            selectedID = visibleItems.first?.id
        }
        alert = AlertMessage(title: "Suggestions applied",
                             message: "\(changed) undecided photos were marked as pick or reject. You can change any of them.")
    }

    private func saveDecisions() {
        guard let store else { return }
        var entries: [String: SessionStore.Entry] = [:]
        for item in items where item.decision != .undecided || item.rating > 0 {
            entries[store.key(for: item.url)] = SessionStore.Entry(decision: item.decision, rating: item.rating)
        }
        saveQueue.async { try? store.saveDecisions(entries) }
    }

    private func saveAnalysisCache() {
        guard let store else { return }
        let cache = analysisCache
        saveQueue.async { try? store.saveAnalysis(cache) }
    }

    // MARK: - Navigation

    /// The photo to select after `id` leaves the list: the next one, or the previous at the end.
    private func neighbour(of id: PhotoItem.ID) -> PhotoItem.ID? {
        let visible = visibleItems
        guard let position = visible.firstIndex(where: { $0.id == id }) else { return visible.first?.id }
        if position + 1 < visible.count { return visible[position + 1].id }
        return position > 0 ? visible[position - 1].id : nil
    }

    func selectNext() { move(by: 1) }
    func selectPrevious() { move(by: -1) }

    private func move(by offset: Int) {
        let visible = visibleItems
        guard !visible.isEmpty else { return }
        guard let id = selectedID, let position = visible.firstIndex(where: { $0.id == id }) else {
            selectedID = visible.first?.id
            return
        }
        selectedID = visible[max(0, min(visible.count - 1, position + offset))].id
    }

    func selectNextSection() { moveSection(by: 1) }
    func selectPreviousSection() { moveSection(by: -1) }

    private func moveSection(by offset: Int) {
        let sections = sections
        guard !sections.isEmpty else { return }
        let current = sections.firstIndex { $0.items.contains { $0.id == selectedID } } ?? 0
        let target = max(0, min(sections.count - 1, current + offset))
        selectedID = sections[target].items.first?.id
    }

    // MARK: - Export

    func writeSidecars() {
        let targets = items.filter { $0.decision != .undecided || $0.rating > 0 }
        guard !targets.isEmpty else {
            alert = AlertMessage(title: "Nothing to write", message: "Pick, reject or rate some photos first.")
            return
        }
        isExporting = true
        let jobs = targets.map { ($0.url, $0.decision, $0.rating) }
        Task.detached(priority: .userInitiated) {
            var created = 0, updated = 0, skipped: [String] = [], failed: [String] = []
            for (url, decision, rating) in jobs {
                do {
                    switch try XMPSidecar.write(photo: url, decision: decision, rating: rating) {
                    case .created: created += 1
                    case .updated: updated += 1
                    case .skippedUnsupportedExisting: skipped.append(url.lastPathComponent)
                    case .skippedNoDecision: break
                    }
                } catch {
                    failed.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            var message = "Created \(created) and updated \(updated) XMP sidecar files next to your photos. Original photos were not modified."
            if !skipped.isEmpty {
                message += "\n\nSkipped \(skipped.count) existing sidecars with an unusual layout: \(skipped.prefix(5).joined(separator: ", "))"
            }
            if !failed.isEmpty {
                message += "\n\nFailed: \(failed.prefix(5).joined(separator: "\n"))"
            }
            await MainActor.run { [message] in
                self.isExporting = false
                self.alert = AlertMessage(title: "XMP sidecars written", message: message)
            }
        }
    }

    func copyPicks() {
        let picks = items.filter { $0.decision == .pick }
        guard !picks.isEmpty else {
            alert = AlertMessage(title: "No picks", message: "Mark some photos as picks first (press P).")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Copy Here"
        panel.message = "Choose where to copy \(picks.count) picked photos"
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        if let folder, destination.standardizedFileURL == folder.standardizedFileURL {
            alert = AlertMessage(title: "Choose another folder", message: "The destination must be different from the folder being culled.")
            return
        }
        isExporting = true
        Task.detached(priority: .userInitiated) {
            let result = Exporter.copy(picks, to: destination)
            var message = "Copied \(result.copiedPhotos) photos to \(destination.path)."
            if result.skippedExisting > 0 { message += "\n\(result.skippedExisting) files already existed there and were left untouched." }
            if !result.failures.isEmpty { message += "\n\nFailed:\n\(result.failures.prefix(5).joined(separator: "\n"))" }
            await MainActor.run { [message] in
                self.isExporting = false
                self.alert = AlertMessage(title: "Picks copied", message: message)
            }
        }
    }
}
