import Foundation
import ImageIO

extension XMPSidecar {
    public enum EmbeddedMetadataError: Error, LocalizedError {
        case unsafeFile, unsupportedImage, invalidMetadata, copyFailed(String)
        public var errorDescription: String? {
            switch self {
            case .unsafeFile: return "Embedded metadata requires a regular, newly rendered image copy."
            case .unsupportedImage: return "Embedded metadata export supports single-image JPEG, PNG and TIFF copies."
            case .invalidMetadata: return "Could not construct the embedded rating metadata."
            case .copyFailed(let detail): return "Could not synchronize embedded metadata: \(detail)"
            }
        }
    }

    /// Synchronizes choices inside a newly rendered JPEG/PNG/TIFF copy.
    /// This intentionally writes the passed file: callers must never pass an original photograph.
    /// PNG uses an XMP text chunk without rewriting image/profile chunks; ImageIO's
    /// metadata-copy path preserves compressed pixels and other metadata for JPEG/TIFF.
    public static func writeEmbedded(photo: URL, decision: Decision, rating: Int) throws {
        let fm = FileManager.default
        guard photo.isFileURL,
              (try fm.attributesOfItem(atPath: photo.path)[.type]) as? FileAttributeType == .typeRegular else {
            throw EmbeddedMetadataError.unsafeFile
        }
        guard let source = CGImageSourceCreateWithURL(photo as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1, let type = CGImageSourceGetType(source),
              ["public.jpeg", "public.png", "public.tiff"].contains(type as String) else {
            throw EmbeddedMetadataError.unsupportedImage
        }
        let png = type as String == "public.png" ? try PNGXMPChunks(data: Data(contentsOf: photo)) : nil
        let originalMetadata: CGImageMetadata?
        if let png {
            if let packet = png.xmp {
                guard let parsed = CGImageMetadataCreateFromXMPData(packet as CFData) else {
                    throw EmbeddedMetadataError.copyFailed("The existing PNG XMP packet could not be safely read.")
                }
                originalMetadata = parsed
            } else { originalMetadata = nil }
        } else { originalMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) }
        let metadata = originalMetadata.flatMap(CGImageMetadataCreateMutableCopy) ?? CGImageMetadataCreateMutable()
        guard CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://ns.adobe.com/xap/1.0/" as CFString, "xmp" as CFString, nil) else {
            throw EmbeddedMetadataError.invalidMetadata
        }
        let current = values(decision: decision, rating: rating)
        CGImageMetadataRemoveTagWithPath(metadata, nil, "xmp:Rating" as CFString)
        CGImageMetadataRemoveTagWithPath(metadata, nil, "xmp:Label" as CFString)
        if let current {
            guard CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, String(current.rating) as CFString) else {
                throw EmbeddedMetadataError.invalidMetadata
            }
            if let label = current.label,
               !CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Label" as CFString, label as CFString) {
                throw EmbeddedMetadataError.invalidMetadata
            }
        }
        let temporary = photo.deletingLastPathComponent().appendingPathComponent(".opencull-metadata-\(UUID().uuidString).\(photo.pathExtension)")
        defer { try? fm.removeItem(at: temporary) }
        if let png {
            // ImageIO can report a successful copy yet omit a newly introduced PNG
            // XMP packet. A standard iTXt packet also keeps palette, alpha, ICC and
            // compressed IDAT data byte-identical, including on later choice clears.
            guard let xmp = CGImageMetadataCreateXMPData(metadata, nil) else {
                throw EmbeddedMetadataError.invalidMetadata
            }
            let encoded = try png.replacingXMP(with: xmp as Data)
            try encoded.write(to: temporary, options: .withoutOverwriting)
        } else {
            guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type, 1, nil) else {
                throw EmbeddedMetadataError.unsupportedImage
            }
            var error: Unmanaged<CFError>?
            // Replace with a full mutable copy: null-tag merge deletion can retain
            // stale choices in some ImageIO writers.
            let options = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: false] as CFDictionary
            guard CGImageDestinationCopyImageSource(destination, source, options, &error) else {
                let detail = error?.takeRetainedValue().localizedDescription ?? "The image format cannot be copied losslessly."
                throw EmbeddedMetadataError.copyFailed(detail)
            }
        }
        // Reopen before replacement so an unsupported writer never damages the generated copy.
        guard let check = CGImageSourceCreateWithURL(temporary as CFURL, nil), CGImageSourceGetCount(check) == 1 else {
            throw EmbeddedMetadataError.copyFailed("The generated metadata copy could not be read.")
        }
        let checkMetadata = CGImageSourceCopyMetadataAtIndex(check, 0, nil)
        let writtenRating = checkMetadata.flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, "xmp:Rating" as CFString) as String? }
        let writtenLabel = checkMetadata.flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, "xmp:Label" as CFString) as String? }
        guard writtenRating == current.map({ String($0.rating) }), writtenLabel == current?.label else {
            throw EmbeddedMetadataError.copyFailed("The image writer did not retain the requested ratings and labels.")
        }
        _ = try fm.replaceItemAt(photo, withItemAt: temporary)
    }
}

/// PNG iTXt layout and CRC follow https://www.w3.org/TR/png-3/#11iTXt.
/// Replaces only Adobe's XMP text chunk; no image data is decoded or re-encoded.
private struct PNGXMPChunks {
    private static let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
    private static let keyword = Data("XML:com.adobe.xmp\0".utf8)
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xedb88320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private let data: Data
    private let chunks: [(name: String, range: Range<Int>)]
    let xmp: Data?

    init(data: Data) throws {
        func invalid() -> XMPSidecar.EmbeddedMetadataError {
            .copyFailed("The PNG chunk structure or checksum is invalid; the copy was left unchanged.")
        }
        guard data.starts(with: Self.signature) else { throw invalid() }
        var offset = Self.signature.count, hasImage = false, ended = false
        var chunks: [(name: String, range: Range<Int>)] = []
        var packet: Data?
        while offset < data.count {
            guard !ended, data.count - offset >= 12 else { throw invalid() }
            let length = Int(Self.readUInt32(data, at: offset))
            guard length <= Int(Int32.max), length <= data.count - offset - 12 else { throw invalid() }
            let typeStart = offset + 4, payloadStart = offset + 8, crcStart = payloadStart + length
            let type = data[typeStart..<payloadStart]
            guard type.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                  (65...90).contains(data[typeStart + 2]),
                  Self.crc(data[typeStart..<crcStart]) == Self.readUInt32(data, at: crcStart) else { throw invalid() }
            let name = String(decoding: type, as: UTF8.self)
            if offset == Self.signature.count {
                guard name == "IHDR", length == 13 else { throw invalid() }
            } else if name == "IHDR" { throw invalid() }
            if name == "IDAT" { hasImage = true }
            if name == "IEND" {
                guard length == 0, hasImage, crcStart + 4 == data.count else { throw invalid() }
                ended = true
            }
            let isXMP = ["iTXt", "tEXt", "zTXt"].contains(name)
                && data[payloadStart..<crcStart].starts(with: Self.keyword)
            if isXMP {
                let header = Self.keyword + Data([0, 0, 0, 0])
                guard packet == nil, name == "iTXt", data[payloadStart..<crcStart].starts(with: header) else {
                    throw XMPSidecar.EmbeddedMetadataError.copyFailed("The PNG has ambiguous or unsupported XMP text packets; its metadata was left unchanged.")
                }
                packet = Data(data[(payloadStart + header.count)..<crcStart])
            } else { chunks.append((name, offset..<(crcStart + 4))) }
            offset = crcStart + 4
        }
        guard ended else { throw invalid() }
        self.data = data; self.chunks = chunks; self.xmp = packet
    }

    func replacingXMP(with xmp: Data) throws -> Data {
        guard xmp.count <= Int(Int32.max) - Self.keyword.count - 4 else {
            throw XMPSidecar.EmbeddedMetadataError.invalidMetadata
        }
        // Keyword terminator, no compression, compression method 0, empty language
        // and translated-keyword fields, followed by UTF-8 XMP.
        let payload = Self.keyword + Data([0, 0, 0, 0]) + xmp
        let packet = Self.chunk(type: Data("iTXt".utf8), payload: payload)
        var output = Self.signature
        output.reserveCapacity(data.count + packet.count)
        var inserted = false
        for chunk in chunks {
            if chunk.name == "IDAT", !inserted { output.append(packet); inserted = true }
            output.append(data[chunk.range])
        }
        return output
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                                 UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    private static func crc(_ data: Data.SubSequence) -> UInt32 {
        var value = UInt32.max
        for byte in data { value = crcTable[Int((value ^ UInt32(byte)) & 255)] ^ (value >> 8) }
        return value ^ UInt32.max
    }
    private static func chunk(type: Data, payload: Data) -> Data {
        var result = Data()
        append(UInt32(payload.count), to: &result)
        result.append(type); result.append(payload)
        append(crc(result[4..<result.count]), to: &result)
        return result
    }
}
