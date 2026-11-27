import CoreGraphics
import CoreImage
import Darwin
import Foundation
import ImageIO

/// A nondestructive recipe. Crop coordinates are normalized from the top-left of
/// the canvas after rotation. Originals are never modified by this recipe.
public struct EditRecipe: Codable, Equatable, Sendable {
    public var exposure: Double = 0
    public var temperature: Double = 6500
    public var tint: Double = 0
    public var contrast: Double = 1
    public var highlights: Double = 1
    public var shadows: Double = 0
    public var saturation: Double = 1
    public var vibrance: Double = 0
    public var sharpness: Double = 0
    public var noiseReduction: Double = 0
    public var rotation: Double = 0
    public var crop: CGRect?

    public init() {}
    public static let identity = EditRecipe()
    public var isIdentity: Bool { self == .identity }

    public func validated() throws -> EditRecipe {
        let values: [(String, Double, ClosedRange<Double>)] = [
            ("Exposure", exposure, -5...5), ("Temperature", temperature, 2000...12000),
            ("Tint", tint, -150...150), ("Contrast", contrast, 0.5...2),
            ("Highlights", highlights, 0...1), ("Shadows", shadows, 0...1),
            ("Saturation", saturation, 0...2), ("Vibrance", vibrance, -1...1),
            ("Sharpness", sharpness, 0...2), ("Noise reduction", noiseReduction, 0...1),
            ("Rotation", rotation, -180...180),
        ]
        for (name, value, range) in values where !value.isFinite || !range.contains(value) {
            throw EditingError.invalidRecipe(name)
        }
        if let crop {
            guard [crop.minX, crop.minY, crop.width, crop.height].allSatisfy(\.isFinite),
                  crop.minX >= 0, crop.minY >= 0, crop.width >= 0.01, crop.height >= 0.01,
                  crop.maxX <= 1.00000001, crop.maxY <= 1.00000001 else { throw EditingError.invalidRecipe("Crop") }
        }
        return self
    }

    /// Explicit UI sanitization. Rendering rejects invalid recipes instead of
    /// quietly substituting values, so bad saved data cannot change an export.
    public func clamped() -> EditRecipe {
        var r = self
        func limit(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        r.exposure = limit(exposure, -5...5, 0); r.temperature = limit(temperature, 2000...12000, 6500)
        r.tint = limit(tint, -150...150, 0); r.contrast = limit(contrast, 0.5...2, 1)
        r.highlights = limit(highlights, 0...1, 1); r.shadows = limit(shadows, 0...1, 0)
        r.saturation = limit(saturation, 0...2, 1); r.vibrance = limit(vibrance, -1...1, 0)
        r.sharpness = limit(sharpness, 0...2, 0); r.noiseReduction = limit(noiseReduction, 0...1, 0)
        r.rotation = limit(rotation, -180...180, 0)
        if let crop {
            if [crop.minX, crop.minY, crop.width, crop.height].allSatisfy(\.isFinite) {
                let clipped = crop.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                r.crop = !clipped.isNull && clipped.width >= 0.01 && clipped.height >= 0.01 ? clipped : nil
            } else { r.crop = nil }
        }
        return r
    }
}

public enum EditingPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case neutral, natural, vivid, softPortrait, landscape, blackAndWhite
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .neutral: return "Original"
        case .natural: return "Natural"
        case .vivid: return "Vivid"
        case .softPortrait: return "Soft Portrait"
        case .landscape: return "Landscape"
        case .blackAndWhite: return "Black & White"
        }
    }
    public var recipe: EditRecipe {
        var r = EditRecipe()
        switch self {
        case .neutral: break
        case .natural: r.contrast = 1.04; r.saturation = 1.05; r.shadows = 0.05; r.highlights = 0.9
        case .vivid: r.contrast = 1.1; r.saturation = 1.15; r.vibrance = 0.2
        case .softPortrait: r.contrast = 0.95; r.saturation = 0.95; r.shadows = 0.1; r.sharpness = 0.1
        case .landscape: r.highlights = 0.8; r.saturation = 1.1; r.vibrance = 0.25; r.sharpness = 0.4
        case .blackAndWhite: r.saturation = 0; r.contrast = 1.12; r.highlights = 0.9
        }
        return r
    }
}

public enum ImageExportFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case jpeg, png, tiff
    public var id: String { rawValue }
    public var title: String { rawValue.uppercased() }
    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    fileprivate var typeIdentifier: CFString {
        switch self { case .jpeg: return "public.jpeg" as CFString; case .png: return "public.png" as CFString; case .tiff: return "public.tiff" as CFString }
    }
}

public enum ExportMetadataPolicy: String, CaseIterable, Codable, Sendable, Identifiable {
    case preserve, remove
    public var id: String { rawValue }
    public var title: String { self == .preserve ? "Keep camera metadata" : "Remove personal metadata" }
}

public struct ImageHistogram: Equatable, Sendable {
    public var red: [Int]
    public var green: [Int]
    public var blue: [Int]
    public var luminance: [Int]
    public var sampleCount: Int
}

public enum EditingError: Error, LocalizedError {
    case invalidRecipe(String), invalidSize, cannotDecode(String), cannotRender, cannotEncode, invalidDestination
    public var errorDescription: String? {
        switch self {
        case .invalidRecipe(let field): return "The \(field.lowercased()) adjustment is invalid."
        case .invalidSize: return "The requested image size is invalid or exceeds the supported rendering limit."
        case .cannotDecode(let name): return "Could not decode \(name) for editing. This camera format may not be supported by this Mac."
        case .cannotRender: return "Could not render the image adjustments."
        case .cannotEncode: return "Could not encode the edited image."
        case .invalidDestination: return "The export destination must be a writable folder."
        }
    }
}

public enum PhotoEditor {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    // CIContext is thread safe. Individual filters/images are local immutable graphs.
    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                                      .outputColorSpace: sRGB, .cacheIntermediates: false])
    private static let maximumDimension = 32768
    private static let maximumPixels = 150_000_000

    /// Decode real source pixels, including RAW sensor data when supported by the
    /// installed Apple decoder. This deliberately does not use embedded previews.
    public static func render(url: URL, recipe: EditRecipe = .identity, maxPixelSize: Int? = nil) throws -> CGImage {
        _ = try recipe.validated()
        try validate(maxPixelSize: maxPixelSize)
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw EditingError.cannotDecode(url.lastPathComponent)
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        if let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int { try validate(width: width, height: height) }
        if ImageLoader.isRaw(url) {
            guard let raw = CIRAWFilter(imageURL: url), ImageLoader.hasFullRawDecoder(raw) else {
                throw EditingError.cannotDecode(url.lastPathComponent)
            }
            try validate(width: Int(raw.nativeSize.width), height: Int(raw.nativeSize.height))
            raw.isDraftModeEnabled = false
            raw.scaleFactor = 1
            guard let decoded = raw.outputImage else { throw EditingError.cannotDecode(url.lastPathComponent) }
            return try render(ciImage: decoded, recipe: recipe, maxPixelSize: maxPixelSize)
        }
        guard let decoded = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw EditingError.cannotDecode(url.lastPathComponent)
        }
        try validate(width: decoded.width, height: decoded.height)
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        let upright = CIImage(cgImage: decoded).oriented(forExifOrientation: (1...8).contains(orientation) ? orientation : 1)
        return try render(ciImage: upright, recipe: recipe, maxPixelSize: maxPixelSize)
    }

    public static func render(image: CGImage, recipe: EditRecipe = .identity, maxPixelSize: Int? = nil) throws -> CGImage {
        _ = try recipe.validated()
        try validate(width: image.width, height: image.height)
        try validate(maxPixelSize: maxPixelSize)
        if recipe.isIdentity && (maxPixelSize == nil || max(image.width, image.height) <= maxPixelSize!) { return image }
        return try render(ciImage: CIImage(cgImage: image), recipe: recipe, maxPixelSize: maxPixelSize)
    }

    /// A deterministic tonal starting point derived from the actual image
    /// histogram. It is not a learned style or a photographer-quality judgment.
    public static func autoAdjust(image: CGImage) -> EditRecipe {
        let h = histogram(image: image, bins: 256)
        guard h.sampleCount > 0 else { return .identity }
        let weighted = h.luminance.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }
        let mean = weighted / Double(h.sampleCount) / 255
        var recipe = EditRecipe()
        recipe.exposure = min(2, max(-2, log2(0.45 / max(0.02, mean))))
        let white = Double(h.luminance.suffix(8).reduce(0, +)) / Double(h.sampleCount)
        let black = Double(h.luminance.prefix(8).reduce(0, +)) / Double(h.sampleCount)
        recipe.highlights = white > 0.02 ? 0.65 : 0.95
        recipe.shadows = black > 0.05 ? 0.18 : (mean < 0.25 ? 0.08 : 0)
        return recipe
    }

    public static func histogram(image: CGImage, bins: Int = 64) -> ImageHistogram {
        let bins = min(256, max(2, bins))
        let scale = min(1, 512 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var result = ImageHistogram(red: .init(repeating: 0, count: bins), green: .init(repeating: 0, count: bins),
                                    blue: .init(repeating: 0, count: bins), luminance: .init(repeating: 0, count: bins), sampleCount: 0)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let drawing = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                           bytesPerRow: width * 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            drawing.interpolationQuality = .medium
            drawing.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return result }
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i+1]), b = Int(pixels[i+2])
            result.red[min(bins-1, r * bins / 256)] += 1
            result.green[min(bins-1, g * bins / 256)] += 1
            result.blue[min(bins-1, b * bins / 256)] += 1
            let luminance = min(255, max(0, Int((0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)).rounded())))
            result.luminance[min(bins-1, luminance * bins / 256)] += 1
        }
        result.sampleCount = width * height
        return result
    }

    /// Render to a new file. The complete encoded result is staged in the chosen
    /// folder and published with an exclusive atomic rename; an existing file or
    /// symlink is never overwritten, including races with another exporter.
    public static func export(url: URL, recipe: EditRecipe = .identity, to destination: URL,
                              format: ImageExportFormat = .jpeg, quality: Double = 0.92,
                              maxPixelSize: Int? = nil, metadata: ExportMetadataPolicy = .preserve) throws -> URL {
        guard quality.isFinite, (0...1).contains(quality) else { throw EditingError.invalidRecipe("JPEG quality") }
        guard destination.isFileURL else { throw EditingError.invalidDestination }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw EditingError.invalidDestination }
        let image = try render(url: url, recipe: recipe, maxPixelSize: maxPixelSize)
        let encoded = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(encoded, format.typeIdentifier, 1, nil) else { throw EditingError.cannotEncode }
        var properties: [CFString: Any] = [:]
        if metadata == .preserve, let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            properties = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) as? [CFString: Any] ?? [:]
        }
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = image.width
        properties[kCGImagePropertyPixelHeight] = image.height
        properties[kCGImagePropertyColorModel] = kCGImagePropertyColorModelRGB
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = image.width; exif[kCGImagePropertyExifPixelYDimension] = image.height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        properties[kCGImageDestinationLossyCompressionQuality] = quality
        properties[kCGImageDestinationEmbedThumbnail] = false
        // URL rendering creates an 8-bit sRGB CGImage with upright pixels.
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw EditingError.cannotEncode }
        let staging = destination.appendingPathComponent(".opencull-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: staging) }
        try (encoded as Data).write(to: staging, options: .withoutOverwriting)
        let rawStem = url.deletingPathExtension().lastPathComponent
        let stem = rawStem.isEmpty ? "Photo" : rawStem
        for number in 1...10000 {
            let suffix = number == 1 ? "" : "-\(number)"
            let target = destination.appendingPathComponent("\(stem)-edited\(suffix).\(format.fileExtension)")
            if renamex_np(staging.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            if errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        throw EditingError.cannotEncode
    }

    private static func validate(maxPixelSize: Int?) throws {
        if let maxPixelSize, maxPixelSize <= 0 || maxPixelSize > maximumDimension { throw EditingError.invalidSize }
    }

    private static func validate(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension,
              width <= maximumPixels / height else { throw EditingError.invalidSize }
    }

    private static func render(ciImage: CIImage, recipe: EditRecipe, maxPixelSize: Int?) throws -> CGImage {
        var result = ciImage
        let original = result.extent
        guard !original.isInfinite, !original.isNull, original.width.isFinite, original.height.isFinite else { throw EditingError.invalidSize }
        try validate(width: Int(original.width), height: Int(original.height))
        result = result.transformed(by: CGAffineTransform(translationX: -original.minX, y: -original.minY))
        if recipe.temperature != 6500 || recipe.tint != 0 {
            // Photographer-facing WB controls describe the assumed source light:
            // higher Kelvin warms, and positive tint corrects green toward magenta.
            result = result.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: recipe.temperature, y: recipe.tint),
                                                                                 "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        }
        if recipe.exposure != 0 { result = result.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: recipe.exposure]) }
        if recipe.highlights != 1 || recipe.shadows != 0 {
            result = result.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": recipe.highlights, "inputShadowAmount": recipe.shadows])
        }
        if recipe.contrast != 1 || recipe.saturation != 1 {
            result = result.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: recipe.contrast, kCIInputSaturationKey: recipe.saturation])
        }
        if recipe.vibrance != 0 { result = result.applyingFilter("CIVibrance", parameters: ["inputAmount": recipe.vibrance]) }
        if recipe.noiseReduction > 0 {
            let extent = result.extent
            result = result.clampedToExtent().applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": recipe.noiseReduction * 0.08,
                                                                                             kCIInputSharpnessKey: 0]).cropped(to: extent)
        }
        if recipe.sharpness > 0 {
            let extent = result.extent
            result = result.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: recipe.sharpness]).cropped(to: extent)
        }
        if recipe.rotation != 0 {
            let radians = -recipe.rotation * .pi / 180
            let extent = result.extent
            let rotated = result.clampedToExtent().transformed(by: CGAffineTransform(rotationAngle: radians))
            let bounds = extent.applying(CGAffineTransform(rotationAngle: radians))
            let size = inscribedSize(width: extent.width, height: extent.height, radians: radians)
            let width = max(1, floor(size.width + 0.000001)), height = max(1, floor(size.height + 0.000001))
            let crop = CGRect(x: bounds.midX - width/2, y: bounds.midY - height/2, width: width, height: height)
            result = rotated.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        }
        if let crop = recipe.crop {
            let extent = result.extent
            let width = max(1, floor(extent.width * crop.width)), height = max(1, floor(extent.height * crop.height))
            let pixelCrop = CGRect(x: floor(extent.width * crop.minX), y: floor(extent.height * (1 - crop.maxY)), width: width, height: height)
                .intersection(extent)
            guard !pixelCrop.isNull, pixelCrop.width >= 1, pixelCrop.height >= 1 else { throw EditingError.invalidRecipe("Crop") }
            result = result.cropped(to: pixelCrop).transformed(by: CGAffineTransform(translationX: -pixelCrop.minX, y: -pixelCrop.minY))
        }
        var extent = result.extent
        if let maxPixelSize, max(extent.width, extent.height) > CGFloat(maxPixelSize) {
            let scale = CGFloat(maxPixelSize) / max(extent.width, extent.height)
            let width = max(1, (extent.width * scale).rounded()), height = max(1, (extent.height * scale).rounded())
            result = result.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            extent = CGRect(x: 0, y: 0, width: width, height: height)
            result = result.cropped(to: extent)
        }
        guard let rendered = context.createCGImage(result, from: extent, format: .RGBA8, colorSpace: sRGB) else { throw EditingError.cannotRender }
        return rendered
    }

    /// Largest axis-aligned rectangle entirely inside the rotated canvas.
    private static func inscribedSize(width: CGFloat, height: CGFloat, radians: Double) -> CGSize {
        var angle = abs(radians).truncatingRemainder(dividingBy: .pi)
        if angle > .pi / 2 { angle = .pi - angle }
        let sine = CGFloat(sin(angle)), cosine = CGFloat(cos(angle))
        if sine < 0.000001 { return CGSize(width: width, height: height) }
        if cosine < 0.000001 { return CGSize(width: height, height: width) }
        let long = max(width, height), short = min(width, height)
        if short <= 2 * sine * cosine * long || abs(sine - cosine) < 0.000001 {
            let x = short / 2
            return width >= height ? CGSize(width: x / sine, height: x / cosine) : CGSize(width: x / cosine, height: x / sine)
        }
        let cosDouble = cosine * cosine - sine * sine
        return CGSize(width: (width * cosine - height * sine) / cosDouble,
                      height: (height * cosine - width * sine) / cosDouble)
    }
}
