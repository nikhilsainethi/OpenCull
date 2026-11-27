import Darwin
import Foundation

/// Small process-ownership marker for crash recovery. A live process's scratch
/// is never reclaimed, including another OpenCull instance using the same root.
public enum ImportScratchRecovery {
    public static let markerName = ".opencull-import-owner"

    public static func mark(_ directory: URL) throws {
        try Data("OpenCull import scratch v1\n\(getpid())\n".utf8)
            .write(to: directory.appendingPathComponent(markerName), options: .withoutOverwriting)
    }

    public static func unmark(_ directory: URL) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(markerName))
    }

    /// Only known-prefix directories with a valid marker from a dead process
    /// qualify. Missing/invalid markers and symlinks are deliberately retained.
    public static func recover(in parent: URL, prefixes: [String]) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for directory in children where prefixes.contains(where: { directory.lastPathComponent.hasPrefix($0) }) {
            guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let marker = directory.appendingPathComponent(markerName)
            guard let attributes = try? marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  let size = attributes.fileSize, size < 80,
                  let data = try? Data(contentsOf: marker), let text = String(data: data, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n")
            guard lines.count == 2, lines[0] == "OpenCull import scratch v1",
                  let owner = Int32(lines[1]), owner > 1 else { continue }
            if kill(owner, 0) == -1 && errno == ESRCH { try? fm.removeItem(at: directory) }
        }
    }
}
