import CullCore
import Foundation

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case cull, compare, edit
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String { switch self { case .cull: "checkmark.rectangle.stack"; case .compare: "rectangle.split.2x1"; case .edit: "slider.horizontal.3" } }
}

enum ZoomMode: String, CaseIterable, Identifiable {
    case fit, actual, face
    var id: String { rawValue }
    var title: String { switch self { case .fit: "Fit"; case .actual: "100%"; case .face: "Face" } }
}

struct SavedStyle: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var recipe: EditRecipe
    var profile: AdaptiveStyleProfile? = nil
}

struct RecentAlbum: Identifiable, Codable, Equatable {
    var path: String
    var opened: Date
    var recursive: Bool
    var count: Int
    var id: String { path }
    var title: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct PhotoWorkspaceRecord: Codable, Equatable {
    var fingerprint: String
    var recipe: EditRecipe = .identity
    var manualGroup: String?
    var keyFace: Int?
    var exported = false
}

struct WorkspaceDocument: Codable {
    var version = 1
    var records: [String: PhotoWorkspaceRecord] = [:]
}

struct PreferenceExample: Codable {
    var analysis: PhotoAnalysis
    var decision: Decision
    var rating: Int
    var updated: Date
}

struct GlobalWorkspaceDocument: Codable {
    var version = 1
    var recents: [RecentAlbum] = []
    var styles: [SavedStyle] = []
    var examples: [String: PreferenceExample] = [:]
}

/// Small, atomic JSON documents. A corrupt source is copied aside before any recovery save.
@MainActor final class WorkspaceIO {
    let root: URL
    private var blockedSources: Set<URL> = []
    init(root: URL) { self.root = root }
    var globalURL: URL { root.appendingPathComponent("workspace.json") }

    func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: url))
        } catch {
            let recovery = url.appendingPathExtension("corrupt-\(UUID().uuidString)")
            var recovered: String?
            do { try FileManager.default.copyItem(at: url, to: recovery); recovered = recovery.lastPathComponent }
            catch { blockedSources.insert(url) }
            throw WorkspaceError.unreadable(url.lastPathComponent, recovered, error.localizedDescription)
        }
    }

    func write<T: Encodable>(_ value: T, at url: URL) throws {
        if blockedSources.contains(url), FileManager.default.fileExists(atPath: url.path) {
            // A failed recovery copy is never permission to overwrite the damaged original.
            try FileManager.default.copyItem(at: url, to: url.appendingPathExtension("corrupt-\(UUID().uuidString)"))
            blockedSources.remove(url)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

enum WorkspaceError: Error, LocalizedError {
    case unreadable(String, String?, String)
    var errorDescription: String? {
        switch self {
        case let .unreadable(file, recovery, detail):
            "Could not read \(file). " + (recovery.map { "A recovery copy was preserved as \($0). " } ?? "A recovery copy could not be created; the source remains in place. ") + detail
        }
    }
}

struct DecisionState: Equatable {
    var decision: Decision
    var rating: Int
}

struct WorkspaceSnapshot {
    var name: String
    var decisions: [String: DecisionState]
    var records: [String: PhotoWorkspaceRecord]
    var selected: String?
    var selection: Set<String>
}
