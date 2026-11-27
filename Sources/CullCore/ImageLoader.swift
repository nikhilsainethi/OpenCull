import CoreGraphics
import Foundation
import ImageIO

/// Fast image decoding with ImageIO. For RAW files the camera's embedded JPEG preview is
/// used whenever it is large enough, which is far faster than decoding the RAW data.
public enum ImageLoader {
    public static let rawExtensions: Set<String> = [
        "3fr", "ari", "arw", "bay", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff", "iiq", "k25",
        "kdc", "mef", "mos", "mrw", "nef", "nrw", "orf", "pef", "raf", "raw", "rw2", "rwl", "sr2",
        "srf", "srw", "x3f",
    ]
    public static let standardExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]
    public static var supportedExtensions: Set<String> { rawExtensions.union(standardExtensions) }

    public static func isRaw(_ url: URL) -> Bool { rawExtensions.contains(url.pathExtension.lowercased()) }
    public static func isSupported(_ url: URL) -> Bool { supportedExtensions.contains(url.pathExtension.lowercased()) }

    /// Decodes an upright (orientation applied) image whose longest side is at most `maxPixelSize`.
    public static func loadImage(url: URL, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0, maxPixelSize <= 100_000 else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)

        if isRaw(url) {
            // 1. Try the embedded preview (fast).
            if let preview = thumbnail(source: source, index: index, maxPixelSize: maxPixelSize, forceDecode: false) {
                let longSide = max(preview.width, preview.height)
                let fullLongSide = fullSizeLongSide(source: source, index: index) ?? longSide
                // Accept the preview if it is big enough for the requested size.
                if longSide >= min(maxPixelSize, fullLongSide) / 2 {
                    return preview
                }
            }
            // 2. The embedded preview is missing or tiny: decode the RAW itself (slow).
            return thumbnail(source: source, index: index, maxPixelSize: maxPixelSize, forceDecode: true)
        }

        // JPEG/HEIC/TIFF: always decode the real image. The embedded EXIF thumbnail is
        // usually only 160 px, far too small for analysis.
        return thumbnail(source: source, index: index, maxPixelSize: maxPixelSize, forceDecode: true)
    }

    private static func thumbnail(source: CGImageSource, index: Int, maxPixelSize: Int, forceDecode: Bool) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if forceDecode {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        } else {
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        }
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    private static func fullSizeLongSide(source: CGImageSource, index: Int) -> Int? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return max(w, h)
    }

    public struct Metadata: Sendable {
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var captureDate: Date?
    }

    /// Reads dimensions and capture time (including sub-second time, which matters for bursts).
    public static func metadata(url: URL) -> Metadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) as? [CFString: Any]
        else { return nil }

        var width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        // Orientations 5-8 rotate the image by 90 degrees.
        if let orientation = props[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            swap(&width, &height)
        }

        var date: Date?
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            date = parseExifDate(original,
                                 subseconds: exif[kCGImagePropertyExifSubsecTimeOriginal] as? String,
                                 offset: exif["OffsetTimeOriginal" as CFString] as? String)
        } else if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
                  let dateTime = tiff[kCGImagePropertyTIFFDateTime] as? String {
            date = parseExifDate(dateTime, subseconds: nil, offset: nil)
        }
        return Metadata(pixelWidth: width, pixelHeight: height, captureDate: date)
    }

    /// Parses an EXIF date such as "2024:06:01 14:03:22", plus optional sub-seconds ("45")
    /// and UTC offset ("+02:00"). Without an offset the time is interpreted in UTC, which
    /// keeps the relative timing between photos correct.
    public static func parseExifDate(_ string: String, subseconds: String?, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        guard var date = formatter.date(from: String(trimmed.prefix(19))) else { return nil }

        if let sub = subseconds?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))),
           !sub.isEmpty, sub.allSatisfy(\.isNumber), let value = Double("0." + sub) {
            date.addTimeInterval(value)
        }
        if let offset, let seconds = parseOffset(offset) {
            date.addTimeInterval(-TimeInterval(seconds))
        }
        return date
    }

    private static func parseOffset(_ text: String) -> Int? {
        // Format: "+HH:MM" or "-HH:MM"
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        guard t.count == 6, let sign = t.first, sign == "+" || sign == "-" else { return nil }
        let parts = t.dropFirst().split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (sign == "-" ? -1 : 1) * (h * 3600 + m * 60)
    }
}
