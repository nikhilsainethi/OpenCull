import CryptoKit
import Foundation

/// Copies whole photo bundles without mixing them with an existing destination photograph.
public enum Exporter {
    public struct CopyResult: Sendable, Equatable, Codable {
        public var copiedPhotos = 0
        public var skippedExisting = 0
        public var failures: [String] = []
        public var warnings: [String] = []
    }

    private enum CopyError: Error, LocalizedError {
        case invalidSource(String), invalidSidecar(String), changedSource(String), unsafeDestination
        var errorDescription: String? {
            switch self {
            case .invalidSource(let name): return "Missing, symbolic-link or non-regular source: \(name)."
            case .invalidSidecar(let name): return "Could not safely update metadata in \(name)."
            case .changedSource(let name): return "\(name) changed since it was reviewed. Reopen the album before exporting it."
            case .unsafeDestination: return "The destination must be a real directory different from the source."
            }
        }
    }

    public static func copy(_ items: [PhotoItem], to destination: URL,
                            validator: (@Sendable (PhotoItem) -> Bool)? = nil) -> CopyResult {
        let fm = FileManager.default
        var result = CopyResult()
        do {
            if let attrs = try? fm.attributesOfItem(atPath: destination.path), attrs[.type] as? FileAttributeType != .typeDirectory { throw CopyError.unsafeDestination }
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            result.failures.append("Could not create \(destination.path): \(error.localizedDescription)")
            return result
        }
        for item in items {
            var published: [(url: URL, identity: String)] = []
            let staging = destination.appendingPathComponent(".opencull-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: staging) }
            do {
                guard validator?(item) ?? true else { throw CopyError.changedSource(item.fileName) }
                let sources = item.allFiles
                for source in sources {
                    guard try fm.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType == .typeRegular else { throw CopyError.invalidSource(source.lastPathComponent) }
                    let target = destination.appendingPathComponent(source.lastPathComponent)
                    guard target.resolvingSymlinksInPath().standardizedFileURL != source.resolvingSymlinksInPath().standardizedFileURL else { throw CopyError.unsafeDestination }
                }
                let sidecar = XMPSidecar.sidecarURL(for: item.url)
                let sidecarAttributes = try? fm.attributesOfItem(atPath: sidecar.path)
                let hasSidecar = sidecarAttributes != nil
                if hasSidecar && sidecarAttributes?[.type] as? FileAttributeType != .typeRegular { throw CopyError.invalidSource(sidecar.lastPathComponent) }
                let values = XMPSidecar.values(decision: item.decision, rating: item.rating)
                let exportsSidecar = hasSidecar || values != nil
                let names = sources.map(\.lastPathComponent) + (exportsSidecar ? [sidecar.lastPathComponent] : [])
                guard Set(names.map { $0.lowercased() }).count == names.count else { throw CopyError.invalidSource(item.fileName) }
                let collisions = names.filter { (try? fm.attributesOfItem(atPath: destination.appendingPathComponent($0).path)) != nil }
                if !collisions.isEmpty { result.skippedExisting += collisions.count; continue }
                var sidecarText: String?
                if hasSidecar {
                    let existing = try String(contentsOf: sidecar, encoding: .utf8)
                    if let values {
                        guard let updated = XMPSidecar.update(existing: existing, with: values) else { throw CopyError.invalidSidecar(sidecar.lastPathComponent) }
                        sidecarText = updated
                    } else { sidecarText = existing }
                } else if let values { sidecarText = XMPSidecar.makeDocument(values) }
                try fm.createDirectory(at: staging, withIntermediateDirectories: false)
                var bundleWarnings: [String] = []
                for source in sources {
                    let staged = staging.appendingPathComponent(source.lastPathComponent)
                    try fm.copyItem(at: source, to: staged)
                    if values != nil, !ImageLoader.isRaw(source) {
                        if ["jpg", "jpeg", "png", "tif", "tiff"].contains(source.pathExtension.lowercased()) {
                            // Standard-file editors read embedded choices, not companion XMP.
                            // Only the staged copy is modified; the source stays byte-identical.
                            try XMPSidecar.writeEmbedded(photo: staged, decision: item.decision, rating: item.rating)
                        } else {
                            bundleWarnings.append("\(source.lastPathComponent): current ratings are in XMP only. For embedded metadata handoff, export a rendered JPEG/PNG/TIFF copy.")
                        }
                    }
                }
                if let sidecarText { try sidecarText.write(to: staging.appendingPathComponent(sidecar.lastPathComponent), atomically: true, encoding: .utf8) }
                guard validator?(item) ?? true else { throw CopyError.changedSource(item.fileName) }
                // Exclusive moves fail instead of overwriting a concurrent destination creation.
                for name in names {
                    let target = destination.appendingPathComponent(name)
                    try fm.moveItem(at: staging.appendingPathComponent(name), to: target)
                    published.append((target, fileIdentity(target)))
                }
                result.copiedPhotos += 1
                result.warnings.append(contentsOf: bundleWarnings)
            } catch {
                for file in published where fileIdentity(file.url) == file.identity { try? fm.removeItem(at: file.url) }
                result.failures.append("\(item.fileName): \(error.localizedDescription)")
            }
        }
        return result
    }

    private static func fileIdentity(_ url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "missing" }
        return "\(attrs[.systemNumber] ?? "")|\(attrs[.systemFileNumber] ?? "")"
    }
}

public final class SessionStore: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var decision: Decision
        public var rating: Int
        public var fingerprint: String?
        public init(decision: Decision, rating: Int, fingerprint: String? = nil) {
            self.decision = decision
            self.rating = max(0, min(5, rating))
            self.fingerprint = fingerprint
        }
    }

    public struct ReadError: Error, LocalizedError {
        public let source: URL
        public let recoveryCopy: URL?
        public let detail: String
        public var errorDescription: String? {
            "Could not restore \(source.lastPathComponent): \(detail)" + (recoveryCopy.map { " A recovery copy is saved at \($0.path)." } ?? " The existing file was left untouched.")
        }
    }

    public let folder: URL
    public let directory: URL
    public init(folder: URL, baseDirectory: URL? = nil) {
        self.folder = folder.standardizedFileURL
        let base = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenCull/Sessions", isDirectory: true)
        let digest = SHA256.hash(data: Data(self.folder.path.utf8)).map { String(format: "%02x", $0) }.joined()
        directory = base.appendingPathComponent(String(digest.prefix(32)), isDirectory: true)
    }
    private var decisionsURL: URL { directory.appendingPathComponent("decisions.json") }
    private var analysisURL: URL { directory.appendingPathComponent("analysis.plist") }

    public func key(for url: URL) -> String {
        let root = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    /// A bounded content/version fingerprint of every dependency, including fallback companions.
    /// Compute once at scan time and reuse for per-keystroke decision persistence.
    public func fingerprint(for item: PhotoItem) -> String {
        var hash = SHA256()
        for url in item.allFiles.sorted(by: { $0.path < $1.path }) {
            hash.update(data: Data(key(for: url).utf8))
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeRegular else {
                hash.update(data: Data("|missing-or-nonregular|".utf8)); continue
            }
            let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            hash.update(data: Data("|\(attrs[.size] ?? "")|\(modified)|\(attrs[.systemNumber] ?? "")|\(attrs[.systemFileNumber] ?? "")|".utf8))
            if let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                if let start = try? handle.read(upToCount: 32 * 1024) { hash.update(data: start) }
                if let length = try? handle.seekToEnd(), length > 32 * 1024 {
                    try? handle.seek(toOffset: max(32 * 1024, length - 32 * 1024))
                    if let end = try? handle.read(upToCount: 32 * 1024) { hash.update(data: end) }
                }
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func analysisKey(for item: PhotoItem) -> String { "\(key(for: item.url))|v\(PhotoAnalysis.currentVersion)|\(fingerprint(for: item))" }

    public func readDecisions() throws -> [String: Entry] {
        guard FileManager.default.fileExists(atPath: decisionsURL.path) else { return [:] }
        do { return try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: decisionsURL)) }
        catch { throw recoveryError(for: decisionsURL, error: error) }
    }
    public func loadDecisions() -> [String: Entry] { (try? readDecisions()) ?? [:] }

    public func saveDecisions(_ entries: [String: Entry]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: decisionsURL, options: .atomic)
    }

    public func readAnalysis() throws -> [String: PhotoAnalysis] {
        guard FileManager.default.fileExists(atPath: analysisURL.path) else { return [:] }
        do {
            let cache = try PropertyListDecoder().decode([String: PhotoAnalysis].self, from: Data(contentsOf: analysisURL))
            return cache.filter { $0.value.version == PhotoAnalysis.currentVersion }
        } catch { throw recoveryError(for: analysisURL, error: error) }
    }
    public func loadAnalysis() -> [String: PhotoAnalysis] { (try? readAnalysis()) ?? [:] }

    public func saveAnalysis(_ cache: [String: PhotoAnalysis]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(cache).write(to: analysisURL, options: .atomic)
    }

    private func recoveryError(for source: URL, error: Error) -> ReadError {
        // Every failed read describes this version of the damaged source. An older
        // recovery file is not a backup of later corrupt choices or analysis.
        let backup = source.appendingPathExtension("corrupt-\(UUID().uuidString)")
        let fm = FileManager.default
        var recovery: URL?
        if (try? fm.attributesOfItem(atPath: source.path)[.type]) as? FileAttributeType == .typeRegular {
            do { try fm.copyItem(at: source, to: backup); recovery = backup } catch { }
        }
        return ReadError(source: source, recoveryCopy: recovery, detail: error.localizedDescription)
    }
}
