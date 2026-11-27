import Darwin
import Foundation
import zlib

/// A deliberately small ZIP reader: ordinary stored/deflated single-disk ZIPs only.
/// Entries are validated together before any file is written. Extraction never follows
/// archive-provided links and never invokes a shell or a separate executable.
enum SafeZIP {
    private struct Entry {
        var name: String
        var directory: Bool
        var method: UInt16
        var checksum: UInt32
        var expanded: Int
        var payload: Range<Int>
        var occupied: Range<Int>
    }

    struct ExtractionSummary { var entryCount: Int; var expandedBytes: Int64 }
    static func extract(_ archive: URL, to destination: URL, limits: PhotoImportLimits,
                        isCancelled: @Sendable () -> Bool) throws -> ExtractionSummary {
        let attributes = try archive.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size >= 22,
              Int64(size) <= limits.maxExpandedBytes + 64 * 1_048_576 else {
            throw PhotoImportError.invalidArchive("The archive is unreadable or exceeds the import size limit.")
        }
        if isCancelled() { throw CancellationError() }
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        let entries = try parse(data, limits: limits, isCancelled: isCancelled)
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for entry in entries {
            if isCancelled() { throw CancellationError() }
            let target = destination.appendingPathComponent(entry.name, isDirectory: entry.directory)
            if entry.directory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else {
                throw PhotoImportError.invalidArchive("An archive file could not be created: \(entry.name)")
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                if entry.method == 0 {
                    var checksum: uLong = 0, offset = entry.payload.lowerBound
                    while offset < entry.payload.upperBound {
                        if isCancelled() { throw CancellationError() }
                        let end = min(offset + 65_536, entry.payload.upperBound)
                        let chunk = data.subdata(in: offset..<end)
                        checksum = chunk.withUnsafeBytes { crc32(checksum, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
                        try handle.write(contentsOf: chunk)
                        offset = end
                    }
                    guard UInt32(checksum) == entry.checksum else { throw PhotoImportError.invalidArchive("ZIP checksum failed: \(entry.name)") }
                } else {
                    try inflate(data, entry: entry, handle: handle, isCancelled: isCancelled)
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        }
        return ExtractionSummary(entryCount: entries.count, expandedBytes: entries.reduce(0) { $0 + Int64($1.expanded) })
    }

    private static func parse(_ data: Data, limits: PhotoImportLimits, isCancelled: @Sendable () -> Bool) throws -> [Entry] {
        func invalid(_ message: String) -> PhotoImportError { .invalidArchive(message) }
        guard data.count >= 22 else { throw invalid("Truncated ZIP archive.") }
        var endRecord: Int?
        for index in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if data.u32(index) == 0x06054b50, let comment = data.u16(index + 20), index + 22 + Int(comment) == data.count {
                endRecord = index; break
            }
        }
        guard let end = endRecord,
              let disk = data.u16(end + 4), disk == 0,
              let centralDisk = data.u16(end + 6), centralDisk == 0,
              let countOnDisk = data.u16(end + 8), let count = data.u16(end + 10), count == countOnDisk,
              count != .max, Int(count) <= limits.maxEntries,
              let centralSize = data.u32(end + 12), centralSize != .max,
              let centralOffset = data.u32(end + 16), centralOffset != .max,
              Int(centralOffset) <= end, Int(centralSize) == end - Int(centralOffset) else {
            throw invalid("Unsupported, truncated, multi-disk, ZIP64, or oversized ZIP archive.")
        }
        // ZIP64 locator/EOCD records cannot occur between the directory and ordinary EOCD.
        var cursor = Int(centralOffset), entries: [Entry] = [], names: [String: Bool] = [:], expandedTotal: Int64 = 0
        var directorySpellings: [String: String] = [:]
        for _ in 0..<Int(count) {
            if isCancelled() { throw CancellationError() }
            guard cursor <= end - 46, data.u32(cursor) == 0x02014b50,
                  let needed = data.u16(cursor + 6), needed <= 20,
                  let flags = data.u16(cursor + 8), flags & ~UInt16(0x080e) == 0,
                  let method = data.u16(cursor + 10), method == 0 || method == 8,
                  let checksum = data.u32(cursor + 16),
                  let compressed = data.u32(cursor + 20), compressed != .max,
                  let expanded = data.u32(cursor + 24), expanded != .max,
                  let nameLength = data.u16(cursor + 28), nameLength > 0,
                  let extraLength = data.u16(cursor + 30), let commentLength = data.u16(cursor + 32),
                  let startDisk = data.u16(cursor + 34), startDisk == 0,
                  let external = data.u32(cursor + 38), let localOffset = data.u32(cursor + 42), localOffset != .max else {
                throw invalid("ZIP contains an encrypted, unsupported, ZIP64, or malformed entry.")
            }
            let recordEnd = cursor + 46 + Int(nameLength) + Int(extraLength) + Int(commentLength)
            guard recordEnd <= end else { throw invalid("Truncated ZIP directory entry.") }
            let nameBytes = data.subdata(in: (cursor + 46)..<(cursor + 46 + Int(nameLength)))
            guard let name = String(data: nameBytes, encoding: .utf8) else { throw invalid("ZIP filenames must be UTF-8.") }
            let directory = name.hasSuffix("/")
            let components = try safeComponents(name)
            try registerDirectorySpellings(components, directory: directory, spellings: &directorySpellings)
            let canonical = components.joined(separator: "/").precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard names[canonical] == nil else { throw invalid("ZIP contains duplicate filenames: \(name)") }
            let mode = (external >> 16) & 0xf000
            guard mode == 0 || mode == (directory ? 0x4000 : 0x8000),
                  external & 0x10 == 0 || directory else { throw invalid("ZIP links and special files are not allowed: \(name)") }
            try checkExtra(data, range: (cursor + 46 + Int(nameLength))..<(cursor + 46 + Int(nameLength) + Int(extraLength)))
            let expandedSize = Int64(expanded)
            guard expandedSize <= limits.maxFileBytes,
                  expandedTotal <= limits.maxExpandedBytes - expandedSize,
                  Double(expanded) <= max(1, Double(compressed)) * limits.maxCompressionRatio,
                  !directory || (compressed == 0 && expanded == 0),
                  method != 0 || compressed == expanded else { throw invalid("ZIP expansion limits or entry sizes are invalid: \(name)") }
            expandedTotal += expandedSize
            let local = Int(localOffset)
            guard local <= Int(centralOffset) - 30, data.u32(local) == 0x04034b50,
                  data.u16(local + 4) == needed, data.u16(local + 6) == flags, data.u16(local + 8) == method,
                  let localNameLength = data.u16(local + 26), localNameLength == nameLength,
                  let localExtraLength = data.u16(local + 28) else { throw invalid("ZIP local header disagrees with its directory: \(name)") }
            let payloadStart = local + 30 + Int(localNameLength) + Int(localExtraLength)
            guard payloadStart <= Int(centralOffset), Int(compressed) <= Int(centralOffset) - payloadStart,
                  data.subdata(in: (local + 30)..<(local + 30 + Int(localNameLength))) == nameBytes else { throw invalid("Truncated ZIP entry: \(name)") }
            try checkExtra(data, range: (local + 30 + Int(localNameLength))..<payloadStart)
            let payloadEnd = payloadStart + Int(compressed)
            var occupiedEnd = payloadEnd
            if flags & 8 == 0 {
                guard data.u32(local + 14) == checksum, data.u32(local + 18) == compressed, data.u32(local + 22) == expanded else {
                    throw invalid("ZIP entry size or checksum disagrees with its directory: \(name)")
                }
            } else {
                // Streaming headers may leave sizes/CRC zero or repeat the directory,
                // but cannot introduce ZIP64 sentinels or contradictory values.
                guard let localCRC = data.u32(local + 14), localCRC == 0 || localCRC == checksum,
                      let localCompressed = data.u32(local + 18), localCompressed == 0 || localCompressed == compressed,
                      let localExpanded = data.u32(local + 22), localExpanded == 0 || localExpanded == expanded else {
                    throw invalid("ZIP streaming header disagrees with its directory: \(name)")
                }
                // Streaming ZIPs use a descriptor; signed and unsigned ordinary descriptors are supported.
                let descriptor = payloadEnd + (data.u32(payloadEnd) == 0x08074b50 ? 4 : 0)
                guard descriptor <= Int(centralOffset) - 12,
                      data.u32(descriptor) == checksum, data.u32(descriptor + 4) == compressed, data.u32(descriptor + 8) == expanded else {
                    throw invalid("ZIP data descriptor is invalid: \(name)")
                }
                occupiedEnd = descriptor + 12
            }
            names[canonical] = directory
            entries.append(Entry(name: components.joined(separator: "/"), directory: directory, method: method,
                                 checksum: checksum, expanded: Int(expanded), payload: payloadStart..<payloadEnd,
                                 occupied: local..<occupiedEnd))
            cursor = recordEnd
        }
        guard cursor == end else { throw invalid("ZIP directory count or size is inconsistent.") }
        for (name, _) in names {
            var components = name.split(separator: "/")
            while components.count > 1 {
                components.removeLast()
                if names[components.joined(separator: "/")] == false { throw invalid("ZIP has a file where a folder is required.") }
            }
        }
        let ranges = entries.map(\.occupied).sorted { $0.lowerBound < $1.lowerBound }
        for index in 1..<max(1, ranges.count) where ranges[index].lowerBound < ranges[index - 1].upperBound {
            throw invalid("ZIP entries overlap.")
        }
        return entries
    }

    /// Even implicit folders must have one spelling: Camera/a and camera/b
    /// must not merge separate camera folders on a case-insensitive Mac volume.
    static func registerDirectorySpellings(_ components: [String], directory: Bool = false, spellings: inout [String: String]) throws {
        for count in 1..<(components.count + (directory ? 1 : 0)) {
            let spelling = components.prefix(count).joined(separator: "/")
            let key = spelling.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            if let existing = spellings[key], existing != spelling {
                throw PhotoImportError.invalidArchive("Folder names differ only in case or Unicode spelling: \(spelling)")
            }
            spellings[key] = spelling
        }
    }

    static func safeComponents(_ path: String) throws -> [String] {
        let body = path.hasSuffix("/") ? String(path.dropLast()) : path
        let components = body.components(separatedBy: "/")
        guard !body.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw PhotoImportError.invalidArchive("Unsafe filename in ZIP: \(path)")
        }
        return components
    }

    private static func checkExtra(_ data: Data, range: Range<Int>) throws {
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            guard cursor <= range.upperBound - 4, let kind = data.u16(cursor), kind != 1,
                  let size = data.u16(cursor + 2), Int(size) <= range.upperBound - cursor - 4 else {
                throw PhotoImportError.invalidArchive("ZIP64 or malformed ZIP extra data is not supported.")
            }
            cursor += 4 + Int(size)
        }
    }

    private static func inflate(_ data: Data, entry: Entry, handle: FileHandle, isCancelled: @Sendable () -> Bool) throws {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw PhotoImportError.invalidArchive("ZIP decompression could not start.")
        }
        defer { inflateEnd(&stream) }
        var buffer = [UInt8](repeating: 0, count: 65_536), checksum: uLong = 0
        try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress!.advanced(by: entry.payload.lowerBound))
            stream.avail_in = uInt(entry.payload.count)
            while true {
                if isCancelled() { throw CancellationError() }
                let status = buffer.withUnsafeMutableBytes { output -> Int32 in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END, stream.total_out <= entry.expanded else {
                    throw PhotoImportError.invalidArchive("ZIP deflate stream is invalid or exceeds its declared size: \(entry.name)")
                }
                let written = buffer.count - Int(stream.avail_out)
                if written > 0 {
                    let chunk = Data(buffer.prefix(written))
                    checksum = chunk.withUnsafeBytes { crc32(checksum, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
                    try handle.write(contentsOf: chunk)
                }
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0, stream.total_out == entry.expanded, UInt32(checksum) == entry.checksum else {
                        throw PhotoImportError.invalidArchive("ZIP size or checksum failed: \(entry.name)")
                    }
                    break
                }
                guard written > 0 || stream.avail_in > 0 else { throw PhotoImportError.invalidArchive("Truncated ZIP deflate stream: \(entry.name)") }
            }
        }
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset <= count - 2 else { return nil }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
    func u32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset <= count - 4 else { return nil }
        return UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}
