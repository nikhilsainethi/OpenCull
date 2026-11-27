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
    /// ImageIO's metadata-copy path preserves compressed pixel data, EXIF/IPTC and the color profile.
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
        let originalMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
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
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type, 1, nil) else {
            throw EmbeddedMetadataError.unsupportedImage
        }
        var error: Unmanaged<CFError>?
        // Replace with a full mutable copy of the existing metadata. ImageIO's null-tag
        // merge deletion is ignored by some PNG/TIFF writers, which can retain stale choices.
        let options = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: false] as CFDictionary
        guard CGImageDestinationCopyImageSource(destination, source, options, &error) else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "The image format cannot be copied losslessly."
            throw EmbeddedMetadataError.copyFailed(detail)
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
