import Darwin
import Foundation

public enum ImportSourceKind: String, Codable, Sendable, CaseIterable {
    case files, applePhotos, googlePhotos, browserDrop, takeout
    public var title: String {
        switch self {
        case .files: return "Files"
        case .applePhotos: return "Apple Photos"
        case .googlePhotos: return "Google Photos"
        case .browserDrop: return "Browser drop"
        case .takeout: return "Google Takeout"
        }
    }
}

public struct PhotoImportMetadata: Sendable {
    public var assetIdentifier: String?
    public var representationQuality: String?
    public var originalFileName: String?
    public init(assetIdentifier: String? = nil, representationQuality: String? = nil, originalFileName: String? = nil) {
        self.assetIdentifier = assetIdentifier; self.representationQuality = representationQuality; self.originalFileName = originalFileName
    }
}

public struct PhotoImportLimits: Sendable {
    public var maxEntries: Int
    public var maxExpandedBytes: Int64
    public var maxFileBytes: Int64
    public var maxCompressionRatio: Double
    public static let `default` = PhotoImportLimits()
    public init(maxEntries: Int = 20_000, maxExpandedBytes: Int64 = 2_147_483_648,
                maxFileBytes: Int64 = 536_870_912, maxCompressionRatio: Double = 1000) {
        self.maxEntries = maxEntries; self.maxExpandedBytes = maxExpandedBytes
        self.maxFileBytes = maxFileBytes; self.maxCompressionRatio = maxCompressionRatio
    }
    fileprivate func validate() throws {
        guard maxEntries > 0, maxEntries <= 100_000, maxExpandedBytes > 0,
              maxExpandedBytes <= 1_099_511_627_776, maxFileBytes > 0, maxFileBytes <= maxExpandedBytes,
              maxCompressionRatio.isFinite, maxCompressionRatio >= 1 else { throw PhotoImportError.limitExceeded }
    }
}

public struct PhotoImportProgress: Sendable {
    public var completed: Int
    public var total: Int
    public var currentFileName: String
}

public struct PhotoImportResult: Sendable {
    public var albumURL: URL
    /// Number of image files, before the scanner combines RAW/JPEG pairs.
    public var importedImageCount: Int
    public var manifest: PhotoImportManifest
    public var warnings: [String]
}

public struct PhotoImportManifest: Codable, Sendable {
    public static let fileName = ".opencull-import.json"
    public struct Item: Codable, Sendable {
        public var relativePath: String
        public var originalFileName: String
        public var originalPath: String
        public var source: ImportSourceKind
        public var assetIdentifier: String?
        public var representationQuality: String?
        /// Google Takeout capture time. Consumers apply this only when EXIF is absent.
        public var captureDateOverride: Date?
    }
    public var version: Int
    public var source: ImportSourceKind
    public var createdAt: Date
    public var importedImageCount: Int
    public var items: [Item]
    public var sourceSummary: String { "\(source.title) · \(importedImageCount) photo\(importedImageCount == 1 ? "" : "s")" }

    public static func read(from album: URL) throws -> PhotoImportManifest? {
        let url = album.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              (attributes.fileSize ?? .max) <= 16 * 1_048_576 else { throw PhotoImportError.invalidManifest }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(Self.self, from: Data(contentsOf: url))
        guard value.version == 1, value.items.count <= 100_000, value.importedImageCount > 0,
              value.importedImageCount <= value.items.count else { throw PhotoImportError.invalidManifest }
        var names = Set<String>()
        for item in value.items {
            _ = try SafeZIP.safeComponents(item.relativePath)
            guard names.insert(canonical(item.relativePath)).inserted,
                  item.captureDateOverride.map({ validCaptureDate($0.timeIntervalSince1970) }) ?? true else { throw PhotoImportError.invalidManifest }
        }
        return value
    }
}

public enum PhotoImportError: LocalizedError {
    case localFilesOnly, invalidSource(String), destinationExists, destinationInsideSource, noImages
    case limitExceeded, invalidArchive(String), invalidManifest
    public var errorDescription: String? {
        switch self {
        case .localFilesOnly: return "Download the original photos or a Google Takeout ZIP first, then import those local files. Web links cannot supply original photos."
        case .invalidSource(let name): return "This source is missing, unreadable, a link, or not a regular file or folder: \(name)"
        case .destinationExists: return "Choose a new album folder; importing never overwrites an existing album."
        case .destinationInsideSource: return "The imported album must be outside the source folder."
        case .noImages: return "No readable supported photos were found. No album was created."
        case .limitExceeded: return "The import exceeds the safe file-count or size limits. Split the selection into smaller albums."
        case .invalidArchive(let message): return message
        case .invalidManifest: return "The album's import information is invalid or unsupported."
        }
    }
}

public enum PhotoImporter {
    /// Copies local originals/representations to a new managed album. Work is staged
    /// beside the destination; a failure or cancellation publishes no partial album.
    public static func importFiles(_ sources: [URL], to destination: URL, source: ImportSourceKind,
        metadataByPath: [String: PhotoImportMetadata] = [:], limits: PhotoImportLimits = .default,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled },
        progress: (@Sendable (PhotoImportProgress) -> Void)? = nil) throws -> PhotoImportResult {
        try limits.validate()
        if isCancelled() { throw CancellationError() }
        guard destination.isFileURL, sources.allSatisfy(\.isFileURL) else { throw PhotoImportError.localFilesOnly }
        guard !sources.isEmpty else { throw PhotoImportError.noImages }
        guard sources.count <= limits.maxEntries else { throw PhotoImportError.limitExceeded }
        let fm = FileManager.default, album = destination.standardizedFileURL
        guard !fm.fileExists(atPath: album.path) else { throw PhotoImportError.destinationExists }
        let roots = try prepareRoots(sources, destination: album)
        var metadataByIdentity: [String: PhotoImportMetadata] = [:]
        for (path, metadata) in metadataByPath {
            metadataByIdentity[sourceIdentity(URL(fileURLWithPath: path))] = metadata
        }
        // Inventory before staging prevents accidentally importing the staging directory.
        var candidates: [Candidate] = [], archives: [(URL, String)] = [], inventoryCount = 0
        for root in roots {
            if isCancelled() { throw CancellationError() }
            if root.directory {
                guard inventoryCount < limits.maxEntries else { throw PhotoImportError.limitExceeded }
                var remaining = limits; remaining.maxEntries -= inventoryCount
                let inventory = try regularFiles(in: root.url, limits: remaining, isCancelled: isCancelled)
                inventoryCount += inventory.entryCount
                candidates += inventory.files.map { Candidate(url: $0, relativePath: join(root.prefix, relative($0, to: root.url)), originalPath: root.url.appendingPathComponent(relative($0, to: root.url)).path) }
            } else if root.url.pathExtension.lowercased() == "zip" {
                archives.append((root.url, root.prefix))
            } else {
                let hint = metadataByIdentity[sourceIdentity(root.url)]?.originalFileName
                let name = try safeOriginalName(hint ?? root.url.lastPathComponent)
                inventoryCount += 1
                guard inventoryCount <= limits.maxEntries else { throw PhotoImportError.limitExceeded }
                candidates.append(Candidate(url: root.url, relativePath: join(root.prefix, name), originalPath: root.url.path))
            }
        }
        guard candidates.count <= limits.maxEntries else { throw PhotoImportError.limitExceeded }
        let parent = album.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".opencull-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        try ImportScratchRecovery.mark(stage)
        // Reserve one budget across every source, including ZIP contents that may
        // later be skipped. Many individually small ZIPs cannot bypass the cap.
        var budgetEntries = inventoryCount, budgetBytes: Int64 = 0
        for candidate in candidates {
            let size = try candidate.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard Int64(size) <= limits.maxFileBytes, budgetBytes <= limits.maxExpandedBytes - Int64(size) else { throw PhotoImportError.limitExceeded }
            budgetBytes += Int64(size)
        }
        for (archive, prefix) in archives {
            if isCancelled() { throw CancellationError() }
            let target = prefix.isEmpty ? stage : stage.appendingPathComponent(prefix, isDirectory: true)
            guard budgetEntries < limits.maxEntries, budgetBytes < limits.maxExpandedBytes else { throw PhotoImportError.limitExceeded }
            var remaining = limits
            remaining.maxEntries -= budgetEntries
            remaining.maxExpandedBytes -= budgetBytes
            remaining.maxFileBytes = min(remaining.maxFileBytes, remaining.maxExpandedBytes)
            let summary = try SafeZIP.extract(archive, to: target, limits: remaining, isCancelled: isCancelled)
            budgetEntries += summary.entryCount; budgetBytes += summary.expandedBytes
            let inventory = try regularFiles(in: target, limits: limits, includeHidden: true,
                excluding: [sourceIdentity(stage.appendingPathComponent(ImportScratchRecovery.markerName))], isCancelled: isCancelled)
            candidates += inventory.files.map { Candidate(url: $0, relativePath: join(prefix, relative($0, to: target)), originalPath: archive.path + "!/" + relative($0, to: target), alreadyStaged: true) }
        }
        guard candidates.count <= limits.maxEntries else { throw PhotoImportError.limitExceeded }
        var used = Set<String>(), warnings: [String] = [], items: [PhotoImportManifest.Item] = [], imageCount = 0, expandedBytes: Int64 = 0
        var directorySpellings: [String: String] = [:]
        let ordered = candidates.sorted { $0.relativePath < $1.relativePath }
        for (index, candidate) in ordered.enumerated() {
            if isCancelled() { throw CancellationError() }
            progress?(PhotoImportProgress(completed: index, total: ordered.count, currentFileName: candidate.url.lastPathComponent))
            let components = try SafeZIP.safeComponents(candidate.relativePath)
            try SafeZIP.registerDirectorySpellings(components, spellings: &directorySpellings)
            guard used.insert(canonical(candidate.relativePath)).inserted else { throw PhotoImportError.invalidSource("Duplicate destination: \(candidate.relativePath)") }
            let target = stage.appendingPathComponent(candidate.relativePath)
            let ext = target.pathExtension.lowercased(), supported = ImageLoader.isSupported(target)
            let hidden = candidate.relativePath.split(separator: "/").contains { $0.hasPrefix(".") || $0 == "__MACOSX" }
            guard !hidden, supported || ext == "xmp" || ext == "json" else {
                warnings.append("Skipped unsupported file: \(candidate.relativePath)")
                if candidate.alreadyStaged { try fm.removeItem(at: target) }
                continue
            }
            let values = try candidate.url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else { throw PhotoImportError.invalidSource(candidate.originalPath) }
            guard Int64(size) <= limits.maxFileBytes, expandedBytes <= limits.maxExpandedBytes - Int64(size) else { throw PhotoImportError.limitExceeded }
            expandedBytes += Int64(size)
            if !candidate.alreadyStaged {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try copyRegularFile(candidate.url, to: target, maxBytes: limits.maxFileBytes, isCancelled: isCancelled)
            }
            // Decode only our staged copy, never a mutable or substituted source path.
            if supported, ImageLoader.loadImage(url: target, maxPixelSize: 32) == nil {
                if ImageLoader.isRaw(target) {
                    warnings.append("Imported RAW without a readable preview; this Mac may not support its decoder: \(candidate.relativePath)")
                } else {
                    warnings.append("Skipped unreadable image: \(candidate.relativePath)")
                    try fm.removeItem(at: target)
                    continue
                }
            }
            let metadata = metadataByIdentity[sourceIdentity(candidate.url)]
            items.append(.init(relativePath: candidate.relativePath, originalFileName: metadata?.originalFileName ?? candidate.url.lastPathComponent,
                originalPath: candidate.originalPath, source: source, assetIdentifier: metadata?.assetIdentifier,
                representationQuality: metadata?.representationQuality ?? defaultRepresentation(source), captureDateOverride: nil))
            if supported { imageCount += 1 }
        }
        guard imageCount > 0 else { throw PhotoImportError.noImages }
        // File/drop users may select a Takeout ZIP or an already-extracted folder.
        // Recognize its sidecar schema without changing source provenance.
        try applyTakeoutDates(items: &items, stage: stage, warnings: &warnings, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        let manifest = PhotoImportManifest(version: 1, source: source, createdAt: Date(), importedImageCount: imageCount, items: items)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        guard manifestData.count <= 16 * 1_048_576 else { throw PhotoImportError.limitExceeded }
        try manifestData.write(to: stage.appendingPathComponent(PhotoImportManifest.fileName), options: .withoutOverwriting)
        progress?(PhotoImportProgress(completed: ordered.count, total: ordered.count, currentFileName: "Ready"))
        if isCancelled() { throw CancellationError() }
        // moveItem fails if another import created this path; it never replaces it.
        guard !fm.fileExists(atPath: album.path) else { throw PhotoImportError.destinationExists }
        try fm.moveItem(at: stage, to: album)
        // Keep ownership through the atomic rename so a crash cannot leave an
        // unmarked orphan stage. Published album names are never recovery targets.
        do { try ImportScratchRecovery.unmark(album) }
        catch { warnings.append("The album imported successfully, but its temporary ownership marker could not be removed.") }
        return PhotoImportResult(albumURL: album, importedImageCount: imageCount, manifest: manifest, warnings: warnings)
    }

    private static func defaultRepresentation(_ source: ImportSourceKind) -> String {
        switch source {
        case .googlePhotos, .takeout, .browserDrop: return "Downloaded/exported representation; original quality unverified"
        case .applePhotos: return "Photos picker representation; original quality unverified"
        case .files: return "Provided local file; original quality unverified"
        }
    }

    private struct Candidate {
        var url: URL; var relativePath: String; var originalPath: String; var alreadyStaged = false
    }
    private struct Root { var url: URL; var directory: Bool; var prefix: String }

    private static func prepareRoots(_ sources: [URL], destination: URL) throws -> [Root] {
        var roots: [Root] = [], seen = Set<String>()
        for input in sources {
            let url = input.standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { throw PhotoImportError.invalidSource(url.path) }
            let directory = values.isDirectory == true
            if directory {
                let sourcePath = url.resolvingSymlinksInPath().path
                let destinationPath = destination.resolvingSymlinksInPath().path
                guard destinationPath != sourcePath, !destinationPath.hasPrefix(sourcePath + "/") else { throw PhotoImportError.destinationInsideSource }
            }
            roots.append(Root(url: url, directory: directory, prefix: ""))
        }
        // If both a folder and a child are selected, import the folder just once.
        roots = roots.filter { child in !roots.contains { parent in parent.directory && child.url.path != parent.url.path && child.url.path.hasPrefix(parent.url.path + "/") } }
        let onlyRegularFiles = roots.allSatisfy { !$0.directory && $0.url.pathExtension.lowercased() != "zip" }
        let parents = Set(roots.map { $0.url.deletingLastPathComponent().path })
        var namespaces: [String: String] = [:], used = Set<String>()
        for index in roots.indices {
            if roots.count == 1 || (onlyRegularFiles && parents.count == 1) { continue }
            let looseFile = !roots[index].directory && roots[index].url.pathExtension.lowercased() != "zip"
            let key = looseFile ? roots[index].url.deletingLastPathComponent().path : roots[index].url.path
            if let existing = namespaces[key] { roots[index].prefix = existing; continue }
            let base = looseFile ? roots[index].url.deletingLastPathComponent().lastPathComponent : (roots[index].directory ? roots[index].url.lastPathComponent : roots[index].url.deletingPathExtension().lastPathComponent)
            let safe = try safeOriginalName(base.isEmpty ? "Imported" : base)
            var name = safe, suffix = 2
            while !used.insert(canonical(name)).inserted { name = "\(safe)_\(suffix)"; suffix += 1 }
            namespaces[key] = name; roots[index].prefix = name
        }
        return roots
    }

    private struct Inventory { var files: [URL]; var entryCount: Int }
    private static func regularFiles(in root: URL, limits: PhotoImportLimits, includeHidden: Bool = false, excluding: Set<String> = [], isCancelled: @Sendable () -> Bool) throws -> Inventory {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        var traversalError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
            options: includeHidden ? [] : [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in traversalError = error; return false }) else { throw PhotoImportError.invalidSource(root.path) }
        var files: [URL] = [], count = 0
        for case let url as URL in enumerator {
            if isCancelled() { throw CancellationError() }
            if excluding.contains(sourceIdentity(url)) { continue }
            count += 1
            guard count <= limits.maxEntries else { throw PhotoImportError.limitExceeded }
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else { throw PhotoImportError.invalidSource(url.path) }
            if values.isRegularFile == true { files.append(url) }
            else if values.isDirectory != true { throw PhotoImportError.invalidSource(url.path) }
        }
        if let traversalError { throw traversalError }
        return Inventory(files: files, entryCount: count)
    }

    private static func copyRegularFile(_ input: URL, to output: URL, maxBytes: Int64, isCancelled: @Sendable () -> Bool) throws {
        // O_NOFOLLOW + fstat prevent a substituted leaf symlink/FIFO from being read.
        let descriptor = open(input.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw PhotoImportError.invalidSource(input.path) }
        let reader = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? reader.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maxBytes else { throw PhotoImportError.invalidSource(input.path) }
        let outDescriptor = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard outDescriptor >= 0 else { throw PhotoImportError.invalidSource(output.path) }
        let writer = FileHandle(fileDescriptor: outDescriptor, closeOnDealloc: true)
        defer { try? writer.close() }
        var count: Int64 = 0
        while let data = try reader.read(upToCount: 1_048_576), !data.isEmpty {
            if isCancelled() { throw CancellationError() }
            count += Int64(data.count)
            guard count <= maxBytes, count <= info.st_size else { throw PhotoImportError.invalidSource(input.path) }
            try writer.write(contentsOf: data)
        }
        guard count == info.st_size else { throw PhotoImportError.invalidSource(input.path) }
        // Keep source filesystem capture fallback stable; no source attributes change.
        let date = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: output.path)
    }

    private static func applyTakeoutDates(items: inout [PhotoImportManifest.Item], stage: URL, warnings: inout [String], isCancelled: @Sendable () -> Bool) throws {
        struct Sidecar { var date: Date; var path: String }
        struct TitleKey: Hashable { var directory: String; var title: String }
        var sidecarsByPath: [String: [Sidecar]] = [:], sidecarsByTitle: [TitleKey: [Sidecar]] = [:]
        for item in items where item.relativePath.lowercased().hasSuffix(".json") {
            if isCancelled() { throw CancellationError() }
            let url = stage.appendingPathComponent(item.relativePath)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
                  let data = try? Data(contentsOf: url), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let time = json["photoTakenTime"] as? [String: Any] else { continue }
            let seconds: Double?
            if let value = time["timestamp"] as? String { seconds = Double(value) }
            else if let value = time["timestamp"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { seconds = value.doubleValue }
            else { seconds = nil }
            guard let seconds, validCaptureDate(seconds) else { warnings.append("Ignored invalid Takeout capture time: \(item.relativePath)"); continue }
            let sidecar = Sidecar(date: Date(timeIntervalSince1970: seconds), path: item.relativePath)
            sidecarsByPath[item.relativePath, default: []].append(sidecar)
            if let title = json["title"] as? String {
                let key = TitleKey(directory: (item.relativePath as NSString).deletingLastPathComponent, title: title)
                sidecarsByTitle[key, default: []].append(sidecar)
            }
        }
        for index in items.indices where ImageLoader.isSupported(URL(fileURLWithPath: items[index].relativePath)) {
            if isCancelled() { throw CancellationError() }
            let path = items[index].relativePath, directory = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
            let exact = (sidecarsByPath[path + ".json"] ?? []) + (sidecarsByPath[path + ".supplemental-metadata.json"] ?? [])
            let matches = exact.isEmpty ? (sidecarsByTitle[TitleKey(directory: directory, title: name)] ?? []) : exact
            if matches.count == 1 { items[index].captureDateOverride = matches[0].date }
            else if matches.count > 1 { warnings.append("Ambiguous Takeout metadata; kept the photo's existing date: \(path)") }
        }
    }
}

private func relative(_ file: URL, to root: URL) -> String {
    // Foundation may enumerate /var as /private/var. Resolve both before deriving
    // a relative path; raw character offsets would corrupt names and sidecar matches.
    let base = root.resolvingSymlinksInPath().pathComponents
    let path = file.resolvingSymlinksInPath().pathComponents
    return path.dropFirst(base.count).joined(separator: "/")
}
private func join(_ prefix: String, _ path: String) -> String { prefix.isEmpty ? path : prefix + "/" + path }
private func canonical(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) }
private func safeOriginalName(_ name: String) throws -> String {
    let components = try SafeZIP.safeComponents(name)
    guard components.count == 1 else { throw PhotoImportError.invalidSource(name) }
    return name
}
private func validCaptureDate(_ seconds: Double) -> Bool {
    // Year 0001 through 9999; permits genuine historical scans without accepting NaN/overflow.
    seconds.isFinite && seconds >= -62_135_596_800 && seconds <= 253_402_300_799
}

private func sourceIdentity(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
