import CryptoKit
import Foundation

/// Copies picked photos (with RAW+JPEG companions and XMP sidecars) to another folder.
public enum Exporter {
    public struct CopyResult: Sendable, Equatable {
        public var copiedPhotos = 0
        public var skippedExisting = 0
        public var failures: [String] = []
    }

    public static func copy(_ items: [PhotoItem], to destination: URL) -> CopyResult {
        let fileManager = FileManager.default
        var result = CopyResult()
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            result.failures.append("Could not create \(destination.path): \(error.localizedDescription)")
            return result
        }

        for item in items {
            var files = item.allFiles
            let sidecar = XMPSidecar.sidecarURL(for: item.url)
            if fileManager.fileExists(atPath: sidecar.path) { files.append(sidecar) }

            var copiedAny = false
            for file in files {
                let target = destination.appendingPathComponent(file.lastPathComponent)
                if fileManager.fileExists(atPath: target.path) {
                    result.skippedExisting += 1
                    continue
                }
                do {
                    try fileManager.copyItem(at: file, to: target)
                    copiedAny = true
                } catch {
                    result.failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if copiedAny { result.copiedPhotos += 1 }
        }
        return result
    }
}

/// Saves analysis results and decisions per folder in
/// ~/Library/Application Support/OpenCull/Sessions/<hash of folder path>/.
public final class SessionStore: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var decision: Decision
        public var rating: Int

        public init(decision: Decision, rating: Int) {
            self.decision = decision
            self.rating = rating
        }
    }

    public let folder: URL
    public let directory: URL

    public init(folder: URL, baseDirectory: URL? = nil) {
        self.folder = folder.standardizedFileURL
        let base = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenCull/Sessions", isDirectory: true)
        let digest = SHA256.hash(data: Data(self.folder.path.utf8)).map { String(format: "%02x", $0) }.joined()
        directory = base.appendingPathComponent(String(digest.prefix(32)), isDirectory: true)
    }

    private var decisionsURL: URL { directory.appendingPathComponent("decisions.json") }
    private var analysisURL: URL { directory.appendingPathComponent("analysis.plist") }

    /// Path of a photo relative to the session folder, used as a stable key.
    public func key(for url: URL) -> String {
        let root = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    public func analysisKey(for item: PhotoItem) -> String {
        "\(key(for: item.url))|\(item.fileSize)|\(item.modificationDate.timeIntervalSince1970)"
    }

    public func loadDecisions() -> [String: Entry] {
        guard let data = try? Data(contentsOf: decisionsURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    public func saveDecisions(_ entries: [String: Entry]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: decisionsURL, options: .atomic)
    }

    public func loadAnalysis() -> [String: PhotoAnalysis] {
        guard let data = try? Data(contentsOf: analysisURL),
              let cache = try? PropertyListDecoder().decode([String: PhotoAnalysis].self, from: data) else { return [:] }
        return cache.filter { $0.value.version == PhotoAnalysis.currentVersion }
    }

    public func saveAnalysis(_ cache: [String: PhotoAnalysis]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(cache).write(to: analysisURL, options: .atomic)
    }
}
