import CryptoKit
import Foundation

public enum ScanError: LocalizedError {
    case notDirectory(URL)
    case unreadable(URL)
    public var errorDescription: String? {
        switch self {
        case .notDirectory(let url): return "Not a photo folder: \(url.path)"
        case .unreadable(let url): return "The photo folder cannot be read: \(url.path)"
        }
    }
}

/// Imports regular files. Only an unambiguous one-RAW / one-JPEG pair is combined.
public enum PhotoScanner {
    public static func scan(folder: URL, recursive: Bool = false) throws -> [PhotoItem] {
        let fm = FileManager.default
        let root = folder.standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true else { throw ScanError.notDirectory(root) }
        guard fm.isReadableFile(atPath: root.path) else { throw ScanError.unreadable(root) }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        var urls: [URL] = []
        if recursive {
            var traversalError: Error?
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                    traversalError = error; return false
                }) else { throw ScanError.unreadable(root) }
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                urls.append(url)
            }
            if let traversalError { throw traversalError }
        } else {
            urls = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        }
        var photos: [URL] = []
        for url in urls where ImageLoader.isSupported(url) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true && values.isSymbolicLink != true { photos.append(url) }
        }
        let buckets = Dictionary(grouping: photos) { $0.deletingLastPathComponent().path + "/" + $0.deletingPathExtension().lastPathComponent.lowercased() }
        var items: [PhotoItem] = []
        func append(_ primary: URL, companions: [URL] = []) throws {
            let v = try primary.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            items.append(PhotoItem(url: primary, companions: companions, fileSize: Int64(v.fileSize ?? 0),
                                   modificationDate: v.contentModificationDate ?? .distantPast))
        }
        for files in buckets.values {
            let raws = files.filter(ImageLoader.isRaw)
            let jpegs = files.filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            if raws.count == 1 && jpegs.count == 1 {
                try append(raws[0], companions: jpegs)
                for file in files where file != raws[0] && file != jpegs[0] { try append(file) }
            } else {
                for file in files { try append(file) }
            }
        }
        return items.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }
}

/// Byte-identical primary files can be found across a library, independent of time or name.
public enum ExactDuplicateFinder {
    public static func groups(in items: [PhotoItem]) throws -> [[String]] {
        var groups: [String: [String]] = [:]
        var sizes: [Int: [PhotoItem]] = [:]
        for item in items {
            let v = try item.url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            if v.isRegularFile == true && v.isSymbolicLink != true { sizes[v.fileSize ?? -1, default: []].append(item) }
        }
        for bucket in sizes.values where bucket.count > 1 {
            for item in bucket {
                if Task.isCancelled { throw CancellationError() }
                let values = try item.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let handle = try FileHandle(forReadingFrom: item.url)
                defer { try? handle.close() }
                var hash = SHA256()
                while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    if Task.isCancelled { throw CancellationError() }
                    hash.update(data: chunk)
                }
                let key = hash.finalize().map { String(format: "%02x", $0) }.joined()
                groups[key, default: []].append(item.id)
            }
        }
        return groups.values.filter { $0.count > 1 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }
}
