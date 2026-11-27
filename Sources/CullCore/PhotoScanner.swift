import Foundation

/// Finds the photos in a folder and pairs RAW+JPEG files that share a name.
public enum PhotoScanner {
    public static func scan(folder: URL, recursive: Bool = false) throws -> [PhotoItem] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var urls: [URL] = []

        if recursive {
            guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                return []
            }
            for case let url as URL in enumerator { urls.append(url) }
        } else {
            urls = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        }

        let photos = urls.filter { url in
            ImageLoader.isSupported(url) && ((try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false)
        }

        // Group files of the same shot: same folder + same name, ignoring extension and case.
        let shots = Dictionary(grouping: photos) { $0.deletingPathExtension().path.lowercased() }

        var items: [PhotoItem] = []
        for (_, files) in shots {
            let sorted = files.sorted { rank($0) < rank($1) || (rank($0) == rank($1) && $0.lastPathComponent < $1.lastPathComponent) }
            guard let primary = sorted.first else { continue }
            let values = try? primary.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            items.append(PhotoItem(url: primary,
                                   companions: Array(sorted.dropFirst()),
                                   fileSize: Int64(values?.fileSize ?? 0),
                                   modificationDate: values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)))
        }
        return items.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    /// Which file of a shot is the primary one: RAW first, then the best standard format.
    private static func rank(_ url: URL) -> Int {
        if ImageLoader.isRaw(url) { return 0 }
        switch url.pathExtension.lowercased() {
        case "heic", "heif": return 1
        case "jpg", "jpeg": return 2
        case "tif", "tiff": return 3
        default: return 4
        }
    }
}
