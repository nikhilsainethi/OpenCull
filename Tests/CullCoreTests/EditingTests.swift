import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import CullCore

final class EditingTests: XCTestCase {
    private func image(width: Int = 80, height: Int = 60, red: UInt8 = 64, green: UInt8 = 80, blue: UInt8 = 96) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) { pixels[i] = red; pixels[i+1] = green; pixels[i+2] = blue }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { p in
            let c = CGContext(data: p.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                              bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-EditingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ image: CGImage, to url: URL, properties: [CFString: Any] = [:]) throws {
        let d = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(d, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(d))
    }

    func testNeutralRecipeIsStableAndCodable() throws {
        let recipe = EditRecipe()
        XCTAssertTrue(recipe.isIdentity)
        XCTAssertEqual(try recipe.validated(), recipe)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe)), recipe)
        let original = image()
        let rendered = try PhotoEditor.render(image: original, recipe: recipe)
        XCTAssertEqual(rendered.width, original.width)
        XCTAssertEqual(rendered.height, original.height)
        XCTAssertEqual(rgba(rendered), rgba(original))
    }

    func testExposureActuallyChangesPixels() throws {
        let original = image(red: 40, green: 40, blue: 40)
        var recipe = EditRecipe(); recipe.exposure = 1
        let rendered = try PhotoEditor.render(image: original, recipe: recipe)
        XCTAssertGreaterThan(Int(rgba(rendered)[0]), Int(rgba(original)[0]) + 10)
    }

    func testWhiteBalanceAndMonochromeAffectColor() throws {
        let original = image(red: 90, green: 70, blue: 50)
        var recipe = EditRecipe(); recipe.temperature = 10000; recipe.tint = 30
        XCTAssertFalse(rgba(try PhotoEditor.render(image: original, recipe: recipe)).elementsEqual(rgba(original)))
        let monochrome = rgba(try PhotoEditor.render(image: original, recipe: EditingPreset.blackAndWhite.recipe))
        XCTAssertLessThanOrEqual(abs(Int(monochrome[0]) - Int(monochrome[1])), 2)
        XCTAssertLessThanOrEqual(abs(Int(monochrome[1]) - Int(monochrome[2])), 2)
    }

    func testNormalizedCropAndQuarterTurnDimensions() throws {
        let original = image(width: 80, height: 60)
        var recipe = EditRecipe(); recipe.crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let crop = try PhotoEditor.render(image: original, recipe: recipe)
        XCTAssertEqual(crop.width, 40); XCTAssertEqual(crop.height, 30)
        recipe = EditRecipe(); recipe.rotation = 90
        let rotated = try PhotoEditor.render(image: original, recipe: recipe)
        XCTAssertEqual(rotated.width, 60); XCTAssertEqual(rotated.height, 80)
    }

    func testCropUsesTopLeftCoordinates() throws {
        // Provider row zero is top. Red occupies the top half, blue the bottom half.
        var pixels = [UInt8](repeating: 255, count: 40 * 40 * 4)
        for y in 0..<40 { for x in 0..<40 {
            let i = (y * 40 + x) * 4
            pixels[i] = y < 20 ? 255 : 0; pixels[i+1] = 0; pixels[i+2] = y < 20 ? 0 : 255
        } }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let original = CGImage(width: 40, height: 40, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 160,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        var recipe = EditRecipe(); recipe.crop = CGRect(x: 0, y: 0, width: 1, height: 0.5)
        let result = rgba(try PhotoEditor.render(image: original, recipe: recipe))
        XCTAssertGreaterThan(result[0], 240); XCTAssertLessThan(result[2], 10)
    }

    func testStraighteningHasNoTransparentWedges() throws {
        var recipe = EditRecipe(); recipe.rotation = 12
        let result = try PhotoEditor.render(image: image(), recipe: recipe)
        XCTAssertLessThan(result.width, 80)
        let pixels = rgba(result)
        XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] >= 250 })
    }

    func testInvalidRecipeAndSizeAreRejected() throws {
        var recipe = EditRecipe(); recipe.exposure = .nan
        XCTAssertThrowsError(try PhotoEditor.render(image: image(), recipe: recipe))
        recipe.exposure = 8
        XCTAssertThrowsError(try recipe.validated())
        XCTAssertEqual(recipe.clamped().exposure, 5)
        recipe = EditRecipe(); recipe.crop = CGRect(x: -0.1, y: 0, width: 0.5, height: 0.5)
        XCTAssertThrowsError(try PhotoEditor.render(image: image(), recipe: recipe))
        XCTAssertThrowsError(try PhotoEditor.render(image: image(), recipe: .identity, maxPixelSize: 0))
    }

    func testPreviewResizesAfterTheSameEditPipeline() throws {
        var recipe = EditRecipe(); recipe.exposure = 0.5; recipe.crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        let full = try PhotoEditor.render(image: image(), recipe: recipe)
        let preview = try PhotoEditor.render(image: image(), recipe: recipe, maxPixelSize: 30)
        XCTAssertEqual(full.width, 40); XCTAssertEqual(full.height, 60)
        XCTAssertEqual(preview.width, 20); XCTAssertEqual(preview.height, 30)
        XCTAssertLessThanOrEqual(abs(Int(rgba(full)[0]) - Int(rgba(preview)[0])), 2)
    }

    func testExportFormatsPreserveSourceAndUseCurrentRecipe() throws {
        let dir = try directory(), source = dir.appendingPathComponent("source.png")
        try write(image(), to: source)
        let before = try Data(contentsOf: source)
        var recipe = EditRecipe(); recipe.exposure = 1; recipe.crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        for format in ImageExportFormat.allCases {
            let output = try PhotoEditor.export(url: source, recipe: recipe, to: dir, format: format)
            XCTAssertNotEqual(output, source)
            XCTAssertEqual(output.pathExtension, format.fileExtension)
            let src = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
            XCTAssertEqual(decoded.width, 40); XCTAssertEqual(decoded.height, 30)
            XCTAssertGreaterThan(rgba(decoded)[0], 70)
            XCTAssertNotNil(decoded.colorSpace)
        }
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testExportCollisionNeverOverwritesAndCreatesValidFiles() throws {
        let dir = try directory(), source = dir.appendingPathComponent("source.png")
        try write(image(), to: source)
        let occupied = dir.appendingPathComponent("source-edited.jpg")
        try Data([1, 2, 3]).write(to: occupied)
        let output = try PhotoEditor.export(url: source, recipe: .identity, to: dir, format: .jpeg)
        XCTAssertNotEqual(output, occupied)
        XCTAssertEqual(try Data(contentsOf: occupied), Data([1, 2, 3]))
        XCTAssertNotNil(CGImageSourceCreateWithURL(output as CFURL, nil))
    }

    func testOrientationIsAppliedOnceAndMetadataRemovalRemovesGPS() throws {
        let dir = try directory(), source = dir.appendingPathComponent("rotated.png")
        try write(image(width: 80, height: 60), to: source, properties: [kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.3, kCGImagePropertyGPSLatitudeRef: "N"]])
        let rendered = try PhotoEditor.render(url: source, recipe: .identity)
        XCTAssertEqual(rendered.width, 60); XCTAssertEqual(rendered.height, 80)
        let output = try PhotoEditor.export(url: source, recipe: .identity, to: dir, format: .jpeg, metadata: .remove)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 60)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 80)
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int ?? 1, 1)
    }

    func testHistogramAndAutoAdjustmentUseImageContent() throws {
        let dark = image(red: 20, green: 20, blue: 20)
        let h = PhotoEditor.histogram(image: dark)
        XCTAssertEqual(h.red.reduce(0, +), h.sampleCount)
        XCTAssertEqual(h.luminance.reduce(0, +), h.sampleCount)
        XCTAssertEqual(h.red.count, 64)
        let adjustment = PhotoEditor.autoAdjust(image: dark)
        XCTAssertGreaterThan(adjustment.exposure, 0.5)
        XCTAssertGreaterThan(rgba(try PhotoEditor.render(image: dark, recipe: adjustment))[0], 20)
    }

    func testEachTonalAndColorControlProducesADifferentImage() throws {
        let original = image(red: 75, green: 105, blue: 140)
        let originalBytes = rgba(original)
        let changes: [(String, WritableKeyPath<EditRecipe, Double>, Double)] = [
            ("Contrast", \.contrast, 1.3), ("Highlights", \.highlights, 0.1),
            ("Shadows", \.shadows, 0.8), ("Saturation", \.saturation, 0.2),
            ("Vibrance", \.vibrance, 0.8), ("Tint", \.tint, 80),
        ]
        for (name, key, value) in changes {
            var recipe = EditRecipe(); recipe[keyPath: key] = value
            XCTAssertFalse(rgba(try PhotoEditor.render(image: original, recipe: recipe)).elementsEqual(originalBytes), name)
        }
    }

    func testDetailControlsChangeTexturedPixels() throws {
        var pixels = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for y in 0..<64 { for x in 0..<64 {
            let n = UInt8(70 + ((x * 13 + y * 17) % 50))
            let i = (y * 64 + x) * 4
            pixels[i] = n; pixels[i+1] = n; pixels[i+2] = n
        } }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let original = CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        var sharp = EditRecipe(); sharp.sharpness = 1
        var denoised = EditRecipe(); denoised.noiseReduction = 1
        XCTAssertFalse(rgba(try PhotoEditor.render(image: original, recipe: sharp)).elementsEqual(rgba(original)))
        XCTAssertFalse(rgba(try PhotoEditor.render(image: original, recipe: denoised)).elementsEqual(rgba(original)))
    }

    func testAllRotationQuadrantsKeepOpaquePixelsAndValidDimensions() throws {
        for dimensions in [(80, 60), (60, 80)] {
            for angle in [-180.0, -135, -90, -45, -12, 12, 45, 90, 135, 180] {
                var recipe = EditRecipe(); recipe.rotation = angle
                let result = try PhotoEditor.render(image: image(width: dimensions.0, height: dimensions.1), recipe: recipe)
                XCTAssertGreaterThan(result.width, 0); XCTAssertGreaterThan(result.height, 0)
                let pixels = rgba(result)
                XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] >= 250 }, "angle \(angle)")
            }
        }
    }

    func testPreservingMetadataKeepsGPSButNormalizesOrientationAndSize() throws {
        let dir = try directory(), source = dir.appendingPathComponent("tagged.png")
        try write(image(), to: source, properties: [kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.3, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:01:02 10:11:12"]])
        let sourceReader = try XCTUnwrap(CGImageSourceCreateWithURL(source as CFURL, nil))
        let sourceProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(sourceReader, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(sourceProperties[kCGImagePropertyGPSDictionary])
        var recipe = EditRecipe(); recipe.crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let exported = try PhotoEditor.export(url: source, recipe: recipe, to: dir, format: .jpeg, metadata: .preserve)
        let reader = try XCTUnwrap(CGImageSourceCreateWithURL(exported as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int ?? 1, 1)
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 30)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 40)
        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2026:01:02 10:11:12")
        XCTAssertEqual(exif[kCGImagePropertyExifPixelXDimension] as? Int, 30)
        XCTAssertEqual(exif[kCGImagePropertyExifPixelYDimension] as? Int, 40)
    }

    func testExportDoesNotFollowExistingDestinationSymlink() throws {
        let dir = try directory(), source = dir.appendingPathComponent("source.png")
        try write(image(), to: source)
        let before = try Data(contentsOf: source)
        let occupied = dir.appendingPathComponent("source-edited.jpg")
        try FileManager.default.createSymbolicLink(at: occupied, withDestinationURL: source)
        let output = try PhotoEditor.export(url: source, recipe: .identity, to: dir, format: .jpeg)
        XCTAssertNotEqual(output, occupied)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: occupied.path), source.path)
    }

    func testConcurrentExportPublishesDistinctCompleteFiles() throws {
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var outputs: [URL] = []
            var errors: [String] = []
            func record(_ result: Result<URL, Error>) {
                lock.lock(); defer { lock.unlock() }
                switch result { case .success(let url): outputs.append(url); case .failure(let error): errors.append(error.localizedDescription) }
            }
        }
        let dir = try directory(), source = dir.appendingPathComponent("source.png")
        try write(image(), to: source)
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            results.record(Result { try PhotoEditor.export(url: source, recipe: EditingPreset.natural.recipe, to: dir, format: .jpeg) })
        }
        XCTAssertTrue(results.errors.isEmpty, results.errors.joined(separator: ", "))
        XCTAssertEqual(results.outputs.count, 8)
        XCTAssertEqual(Set(results.outputs).count, 8)
        for url in results.outputs {
            let reader = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(reader, 0, nil))
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix(".opencull-") })
    }

    func testLosslessExportMatchesTheRenderedPreviewAtSameSize() throws {
        let dir = try directory(), source = dir.appendingPathComponent("source.png")
        try write(image(), to: source)
        var recipe = EditingPreset.vivid.recipe
        recipe.rotation = -90
        recipe.crop = CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6)
        let preview = try PhotoEditor.render(url: source, recipe: recipe, maxPixelSize: 30)
        let exported = try PhotoEditor.export(url: source, recipe: recipe, to: dir, format: .png, maxPixelSize: 30)
        let reader = try XCTUnwrap(CGImageSourceCreateWithURL(exported as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader, 0, nil))
        XCTAssertEqual(decoded.width, preview.width); XCTAssertEqual(decoded.height, preview.height)
        XCTAssertTrue(rgba(decoded).elementsEqual(rgba(preview)))
    }

    func testMalformedInputAndExportOptionsFailWithoutCreatingAnOutput() throws {
        let dir = try directory(), source = dir.appendingPathComponent("broken.jpg")
        try Data("bad image".utf8).write(to: source)
        XCTAssertThrowsError(try PhotoEditor.render(url: source))
        XCTAssertThrowsError(try PhotoEditor.export(url: source, to: dir))
        XCTAssertThrowsError(try PhotoEditor.export(url: source, to: dir, quality: .infinity))
        let regularFile = dir.appendingPathComponent("not-a-folder")
        try Data([1]).write(to: regularFile)
        XCTAssertThrowsError(try PhotoEditor.export(url: source, to: regularFile))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.contains("-edited") })
    }

    func testHigherTemperatureWarmsAndPositiveTintMovesTowardMagenta() throws {
        let original = image(red: 100, green: 100, blue: 100)
        var warm = EditRecipe(); warm.temperature = 10000
        let warmPixels = rgba(try PhotoEditor.render(image: original, recipe: warm))
        XCTAssertGreaterThan(warmPixels[0], warmPixels[2], "Higher photographer white-balance temperature should warm the image")
        var tint = EditRecipe(); tint.tint = 100
        let tintedPixels = rgba(try PhotoEditor.render(image: original, recipe: tint))
        XCTAssertLessThan(tintedPixels[1], max(tintedPixels[0], tintedPixels[2]), "Positive tint should move away from green")
    }
}
