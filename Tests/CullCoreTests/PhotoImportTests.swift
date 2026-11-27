import CoreGraphics
import Foundation
import ImageIO
import XCTest
import zlib
@testable import CullCore

final class PhotoImportTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-ImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func photo(_ url: URL) throws -> Data {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pixels = Data([50, 80, 100, 255, 100, 80, 50, 255, 25, 55, 75, 255, 75, 55, 25, 255])
        let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        return try Data(contentsOf: url)
    }

    func testFilesAreCopiedWithoutChangingSourcesAndManifestSurvivesReload() throws {
        let root = try directory(), file = root.appendingPathComponent("source/portrait.png")
        let before = try photo(file), album = root.appendingPathComponent("album")
        let result = try PhotoImporter.importFiles([file], to: album, source: .browserDrop,
            metadataByPath: [file.path: PhotoImportMetadata(assetIdentifier: "asset-1", representationQuality: "picker representation", originalFileName: "portrait.png")])
        XCTAssertEqual(result.importedImageCount, 1)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try Data(contentsOf: album.appendingPathComponent("portrait.png")), before)
        let manifest = try XCTUnwrap(PhotoImportManifest.read(from: album))
        XCTAssertEqual(manifest.items.count, 1)
        XCTAssertEqual(manifest.items[0].source, .browserDrop)
        XCTAssertEqual(manifest.items[0].assetIdentifier, "asset-1")
        XCTAssertEqual(manifest.items[0].representationQuality, "picker representation")
        XCTAssertEqual(manifest.items[0].originalPath, file.path)
        XCTAssertFalse(manifest.sourceSummary.isEmpty)
    }

    func testFolderPreservesSubfoldersRawJpegAndXMPBytes() throws {
        let root = try directory(), source = root.appendingPathComponent("session")
        let jpeg = source.appendingPathComponent("camera/DSC001.JPG")
        let original = try photo(jpeg)
        let raw = source.appendingPathComponent("camera/DSC001.ARW")
        let xmp = source.appendingPathComponent("camera/DSC001.xmp")
        try Data("RAW bytes retained even when decoder unavailable".utf8).write(to: raw)
        try Data("<xmp>rating</xmp>".utf8).write(to: xmp)
        let result = try PhotoImporter.importFiles([source], to: root.appendingPathComponent("album"), source: .files)
        XCTAssertEqual(result.importedImageCount, 2)
        XCTAssertEqual(try Data(contentsOf: result.albumURL.appendingPathComponent("camera/DSC001.JPG")), original)
        XCTAssertEqual(try Data(contentsOf: result.albumURL.appendingPathComponent("camera/DSC001.ARW")), try Data(contentsOf: raw))
        XCTAssertEqual(try Data(contentsOf: result.albumURL.appendingPathComponent("camera/DSC001.xmp")), try Data(contentsOf: xmp))
        let scanned = try PhotoScanner.scan(folder: result.albumURL, recursive: true)
        XCTAssertEqual(scanned.count, 1)
        XCTAssertEqual(scanned[0].companions.count, 1)
    }

    func testDifferentSourceFoldersCannotOverwriteOrAccidentallyPairSameNames() throws {
        let root = try directory()
        let first = root.appendingPathComponent("a/same/IMG.png"), second = root.appendingPathComponent("b/same/IMG.png")
        _ = try photo(first); _ = try photo(second)
        let result = try PhotoImporter.importFiles([first, second], to: root.appendingPathComponent("album"), source: .files)
        XCTAssertEqual(result.importedImageCount, 2)
        XCTAssertEqual(Set(result.manifest.items.map(\.relativePath)).count, 2)
        XCTAssertEqual(try PhotoScanner.scan(folder: result.albumURL, recursive: true).count, 2)
    }

    func testLooseRawJpegBundleStaysTogetherWhenZIPIsAlsoSelected() throws {
        let root = try directory(), jpeg = root.appendingPathComponent("camera/DSC001.JPG")
        let bytes = try photo(jpeg), raw = jpeg.deletingPathExtension().appendingPathExtension("ARW"), xmp = jpeg.deletingPathExtension().appendingPathExtension("xmp")
        try Data("opaque camera RAW".utf8).write(to: raw)
        try Data("<xmp/>".utf8).write(to: xmp)
        let archive = root.appendingPathComponent("download.zip")
        try zip([Entry("other.png", bytes)]).write(to: archive)
        let result = try PhotoImporter.importFiles([raw, jpeg, xmp, archive], to: root.appendingPathComponent("album"), source: .files)
        XCTAssertEqual(result.importedImageCount, 3)
        let items = try PhotoScanner.scan(folder: result.albumURL, recursive: true)
        XCTAssertEqual(items.count, 2)
        let pair = try XCTUnwrap(items.first { ImageLoader.isRaw($0.url) })
        XCTAssertEqual(pair.companions.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pair.url.deletingPathExtension().appendingPathExtension("xmp").path))
    }

    func testExistingAlbumRemoteURLAndSymlinkAreRejectedWithoutChanges() throws {
        let root = try directory(), file = root.appendingPathComponent("image.png")
        _ = try photo(file)
        let album = root.appendingPathComponent("album")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let sentinel = album.appendingPathComponent("keep.txt")
        try Data("unchanged".utf8).write(to: sentinel)
        XCTAssertThrowsError(try PhotoImporter.importFiles([file], to: album, source: .files))
        XCTAssertEqual(try String(contentsOf: sentinel), "unchanged")
        XCTAssertThrowsError(try PhotoImporter.importFiles([URL(string: "https://photos.google.com/photo/image.jpg")!], to: root.appendingPathComponent("remote"), source: .googlePhotos))
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try PhotoImporter.importFiles([link], to: root.appendingPathComponent("linked"), source: .files))
    }

    func testCorruptStandardImageIsWarnedAndNoEmptyAlbumIsPublished() throws {
        let root = try directory(), bad = root.appendingPathComponent("bad.jpg")
        try Data("not an image".utf8).write(to: bad)
        let good = root.appendingPathComponent("good.png"); _ = try photo(good)
        let result = try PhotoImporter.importFiles([good, bad], to: root.appendingPathComponent("mixed"), source: .files)
        XCTAssertEqual(result.importedImageCount, 1)
        XCTAssertTrue(result.warnings.contains { $0.contains("bad.jpg") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.albumURL.appendingPathComponent("bad.jpg").path))
        let empty = root.appendingPathComponent("empty")
        XCTAssertThrowsError(try PhotoImporter.importFiles([bad], to: empty, source: .files))
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
    }

    func testCancellationAndLaterFailureRollBackHiddenStagingAndAlbum() throws {
        let root = try directory(), file = root.appendingPathComponent("image.png")
        let before = try photo(file), album = root.appendingPathComponent("cancelled")
        XCTAssertThrowsError(try PhotoImporter.importFiles([file], to: album, source: .files, isCancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: album.path))
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertThrowsError(try PhotoImporter.importFiles([file, root.appendingPathComponent("missing.png")], to: album, source: .files))
        XCTAssertFalse(FileManager.default.fileExists(atPath: album.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".opencull-import-") })
    }

    func testTakeoutStoredAndDeflatedZIPRetainsNamesAndMatchesTimestamps() throws {
        let root = try directory(), sample = root.appendingPathComponent("sample.png")
        let bytes = try photo(sample)
        let metadata = Data(#"{"title":"photo.png","photoTakenTime":{"timestamp":"1700000000"},"creationTime":{"timestamp":"1800000000"}}"#.utf8)
        for compressed in [false, true] {
            let archive = root.appendingPathComponent("takeout-\(compressed).zip")
            try zip([Entry("Takeout/Google Photos/Trip/photo.png", bytes, compressed: compressed), Entry("Takeout/Google Photos/Trip/photo.png.supplemental-metadata.json", metadata)]).write(to: archive)
            let originalZIP = try Data(contentsOf: archive)
            let result = try PhotoImporter.importFiles([archive], to: root.appendingPathComponent("album-\(compressed)"), source: .takeout)
            XCTAssertEqual(result.importedImageCount, 1)
            let item = try XCTUnwrap(result.manifest.items.first { $0.relativePath.hasSuffix("photo.png") })
            XCTAssertEqual(item.relativePath, "Takeout/Google Photos/Trip/photo.png")
            XCTAssertTrue(item.representationQuality?.contains("unverified") == true)
            XCTAssertEqual(item.captureDateOverride?.timeIntervalSince1970, 1_700_000_000)
            XCTAssertEqual(try Data(contentsOf: result.albumURL.appendingPathComponent(item.relativePath)), bytes)
            XCTAssertEqual(try Data(contentsOf: archive), originalZIP)
        }
    }

    func testGenericFileImportRecognizesTakeoutSidecarsWithoutChangingProvenance() throws {
        let root = try directory(), photoURL = root.appendingPathComponent("source/photo.png")
        let bytes = try photo(photoURL)
        let metadata = Data(#"{"title":"photo.png","photoTakenTime":{"timestamp":"1700000000"}}"#.utf8)
        try metadata.write(to: photoURL.appendingPathExtension("json"))
        let archive = root.appendingPathComponent("download.zip")
        try zip([Entry("photo.png", bytes), Entry("photo.png.json", metadata)]).write(to: archive)
        for input in [archive, photoURL.deletingLastPathComponent()] {
            let result = try PhotoImporter.importFiles([input], to: root.appendingPathComponent(UUID().uuidString), source: .files)
            let item = try XCTUnwrap(result.manifest.items.first { $0.relativePath == "photo.png" })
            XCTAssertEqual(item.captureDateOverride?.timeIntervalSince1970, 1_700_000_000)
            XCTAssertEqual(item.source, .files)
        }
    }

    func testTakeoutMetadataCannotRenameOrAttachAcrossFolders() throws {
        let root = try directory(), sample = root.appendingPathComponent("sample.png")
        let bytes = try photo(sample)
        let malicious = Data(#"{"title":"../other/photo.png","photoTakenTime":{"timestamp":"nan"}}"#.utf8)
        let archive = root.appendingPathComponent("takeout.zip")
        try zip([Entry("one/photo.png", bytes), Entry("two/photo.png", bytes), Entry("one/unrelated.json", malicious)]).write(to: archive)
        let result = try PhotoImporter.importFiles([archive], to: root.appendingPathComponent("album"), source: .takeout)
        XCTAssertEqual(result.importedImageCount, 2)
        XCTAssertTrue(result.manifest.items.filter { $0.relativePath.hasSuffix(".png") }.allSatisfy { $0.captureDateOverride == nil })
    }

    func testUnsafeZIPPathsDuplicatesAndSymlinkNeverPublish() throws {
        let root = try directory()
        let cases: [[Entry]] = [
            [Entry("../escape.png", Data([1]))], [Entry("/absolute.png", Data([1]))],
            [Entry("a\\escape.png", Data([1]))], [Entry("C:/escape.png", Data([1]))],
            [Entry("a/../escape.png", Data([1]))], [Entry("same.png", Data([1])), Entry("SAME.PNG", Data([2]))],
            [Entry("link.png", Data("/etc/passwd".utf8), externalAttributes: UInt32(0o120777) << 16)],
            [Entry("a", Data([1])), Entry("a/b.png", Data([2]))],
        ]
        for (index, entries) in cases.enumerated() {
            let archive = root.appendingPathComponent("unsafe-\(index).zip"), album = root.appendingPathComponent("album-\(index)")
            try zip(entries).write(to: archive)
            XCTAssertThrowsError(try PhotoImporter.importFiles([archive], to: album, source: .googlePhotos), "case \(index)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: album.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.png").path))
    }

    func testArchiveFolderAliasesCannotMergeUnrelatedCameraFolders() throws {
        let root = try directory(), sample = root.appendingPathComponent("sample.png")
        let bytes = try photo(sample), archive = root.appendingPathComponent("alias.zip")
        try zip([Entry("Camera/one.png", bytes), Entry("camera/two.png", bytes)]).write(to: archive)
        let album = root.appendingPathComponent("album")
        XCTAssertThrowsError(try PhotoImporter.importFiles([archive], to: album, source: .takeout))
        XCTAssertFalse(FileManager.default.fileExists(atPath: album.path))
    }

    func testCorruptEncryptedZIP64AndTruncatedZIPAreRejected() throws {
        let root = try directory(), sample = root.appendingPathComponent("sample.png")
        let bytes = try photo(sample)
        var corrupt = try zip([Entry("photo.png", bytes)])
        corrupt["photo.png".utf8.count + 30] ^= 0xff // payload CRC no longer matches
        var zip64 = try zip([Entry("photo.png", bytes)])
        zip64.replaceSubrange((zip64.count - 12)..<(zip64.count - 8), with: [255,255,255,255])
        let good = try zip([Entry("photo.png", bytes)])
        var inconsistentStreaming = try zip([Entry("photo.png", bytes, compressed: true, flags: 0x808)])
        inconsistentStreaming.replaceSubrange(18..<22, with: [255, 255, 255, 255])
        let samples = [corrupt, try zip([Entry("photo.png", bytes, flags: 1)]), zip64, Data(good.dropLast(8)), inconsistentStreaming]
        for (index, data) in samples.enumerated() {
            let archive = root.appendingPathComponent("invalid-\(index).zip"), album = root.appendingPathComponent("album-\(index)")
            try data.write(to: archive)
            XCTAssertThrowsError(try PhotoImporter.importFiles([archive], to: album, source: .takeout))
            XCTAssertFalse(FileManager.default.fileExists(atPath: album.path))
        }
    }

    func testZIPExpansionAndEntryLimitsAreEnforcedBeforePublication() throws {
        let root = try directory(), archive = root.appendingPathComponent("bomb.zip")
        try zip([Entry("large.png", Data(repeating: 0, count: 100_000), compressed: true)]).write(to: archive)
        let album = root.appendingPathComponent("album")
        XCTAssertThrowsError(try PhotoImporter.importFiles([archive], to: album, source: .takeout,
            limits: PhotoImportLimits(maxEntries: 10, maxExpandedBytes: 1_000_000, maxFileBytes: 1_000_000, maxCompressionRatio: 2)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: album.path))
        XCTAssertThrowsError(try PhotoImporter.importFiles([archive], to: album, source: .takeout,
            limits: PhotoImportLimits(maxEntries: 0, maxExpandedBytes: 10, maxFileBytes: 10, maxCompressionRatio: 1000)))
    }

    func testPickerTemporaryFileCanUseKnownOriginalImageName() throws {
        let root = try directory(), temporary = root.appendingPathComponent("picker.tmp")
        let before = try photo(temporary)
        let result = try PhotoImporter.importFiles([temporary], to: root.appendingPathComponent("album"), source: .applePhotos,
            metadataByPath: [temporary.path: PhotoImportMetadata(originalFileName: "Original.png")])
        XCTAssertEqual(result.importedImageCount, 1)
        XCTAssertEqual(try Data(contentsOf: result.albumURL.appendingPathComponent("Original.png")), before)
        XCTAssertTrue(result.manifest.items[0].representationQuality?.contains("unverified") == true)
    }

    func testStreamingDescriptorZIPAndAggregateBudget() throws {
        let root = try directory(), image = root.appendingPathComponent("sample.png")
        let bytes = try photo(image)
        let one = root.appendingPathComponent("one.zip"), two = root.appendingPathComponent("two.zip")
        try zip([Entry("photo.png", bytes, compressed: true, flags: 0x808)]).write(to: one)
        try zip([Entry("photo.png", bytes)]).write(to: two)
        XCTAssertEqual(try PhotoImporter.importFiles([one], to: root.appendingPathComponent("streaming"), source: .googlePhotos,
            limits: PhotoImportLimits(maxEntries: 1)).importedImageCount, 1)
        let album = root.appendingPathComponent("too-large")
        XCTAssertThrowsError(try PhotoImporter.importFiles([one, two], to: album, source: .takeout,
            limits: PhotoImportLimits(maxEntries: 10, maxExpandedBytes: Int64(bytes.count + 1), maxFileBytes: Int64(bytes.count), maxCompressionRatio: 1000)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: album.path))
    }

    func testCancellationAfterFirstFileAndNestedSelectionsLeaveNoPublishedAlbum() throws {
        let root = try directory(), source = root.appendingPathComponent("source")
        let one = source.appendingPathComponent("one.png"), two = source.appendingPathComponent("two.png")
        _ = try photo(one); _ = try photo(two)
        let cancelled = ImportCancellationFlag(), album = root.appendingPathComponent("cancelled")
        XCTAssertThrowsError(try PhotoImporter.importFiles([one, two], to: album, source: .files,
            isCancelled: { cancelled.value }, progress: { if $0.completed == 1 { cancelled.cancel() } })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: album.path))
        let result = try PhotoImporter.importFiles([source, one, source], to: root.appendingPathComponent("deduplicated"), source: .files)
        XCTAssertEqual(result.importedImageCount, 2)
        XCTAssertThrowsError(try PhotoImporter.importFiles([source], to: source.appendingPathComponent("inside"), source: .files))
    }

    func testFolderImportKeepsMetadataAcrossVarPrivateVarAliases() throws {
        let root = try directory(), folder = root.appendingPathComponent("source"), file = folder.appendingPathComponent("photo.png")
        _ = try photo(file)
        let physicalFile = file.resolvingSymlinksInPath()
        let aliasedPath = physicalFile.path.hasPrefix("/var/") ? "/private" + physicalFile.path : physicalFile.path.replacingOccurrences(of: "/private/var/", with: "/var/")
        XCTAssertNotEqual(aliasedPath, physicalFile.path)
        let result = try PhotoImporter.importFiles([folder.resolvingSymlinksInPath()], to: root.appendingPathComponent("album"), source: .applePhotos,
            metadataByPath: [aliasedPath: PhotoImportMetadata(assetIdentifier: "photo-library-asset", representationQuality: "picker representation")])
        let item = try XCTUnwrap(result.manifest.items.first)
        XCTAssertEqual(item.assetIdentifier, "photo-library-asset")
        XCTAssertEqual(item.representationQuality, "picker representation")
    }

    func testScratchHasRecoveryOwnerDuringCopyButPublishedAlbumDoesNot() throws {
        let root = try directory(), file = root.appendingPathComponent("photo.png")
        _ = try photo(file)
        let observed = ImportCancellationFlag()
        let result = try PhotoImporter.importFiles([file], to: root.appendingPathComponent("album"), source: .files, progress: { _ in
            let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            if folders.contains(where: { $0.lastPathComponent.hasPrefix(".opencull-import-") && FileManager.default.fileExists(atPath: $0.appendingPathComponent(ImportScratchRecovery.markerName).path) }) { observed.cancel() }
        })
        XCTAssertTrue(observed.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.albumURL.appendingPathComponent(ImportScratchRecovery.markerName).path))
    }

    private struct Entry {
        var name: String; var data: Data; var compressed: Bool; var flags: UInt16; var externalAttributes: UInt32
        init(_ name: String, _ data: Data, compressed: Bool = false, flags: UInt16 = 0x800, externalAttributes: UInt32 = UInt32(0o100644) << 16) {
            self.name = name; self.data = data; self.compressed = compressed; self.flags = flags; self.externalAttributes = externalAttributes
        }
    }

    private func zip(_ entries: [Entry]) throws -> Data {
        var output = Data(), central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8), payload = entry.compressed ? try deflate(entry.data) : entry.data
            let checksum = entry.data.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            let offset = output.count, method: UInt16 = entry.compressed ? 8 : 0
            output.le(UInt32(0x04034b50)); output.le(UInt16(20)); output.le(entry.flags); output.le(method)
            output.le(UInt32(0)); output.le(entry.flags & 8 == 0 ? UInt32(checksum) : 0); output.le(entry.flags & 8 == 0 ? UInt32(payload.count) : 0); output.le(entry.flags & 8 == 0 ? UInt32(entry.data.count) : 0)
            output.le(UInt16(name.count)); output.le(UInt16(0)); output.append(name); output.append(payload)
            if entry.flags & 8 != 0 {
                output.le(UInt32(0x08074b50)); output.le(UInt32(checksum)); output.le(UInt32(payload.count)); output.le(UInt32(entry.data.count))
            }
            central.le(UInt32(0x02014b50)); central.le(UInt16(0x0314)); central.le(UInt16(20)); central.le(entry.flags); central.le(method)
            central.le(UInt32(0)); central.le(UInt32(checksum)); central.le(UInt32(payload.count)); central.le(UInt32(entry.data.count))
            central.le(UInt16(name.count)); central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0))
            central.le(entry.externalAttributes); central.le(UInt32(offset)); central.append(name)
        }
        let offset = output.count
        output.append(central); output.le(UInt32(0x06054b50)); output.le(UInt16(0)); output.le(UInt16(0))
        output.le(UInt16(entries.count)); output.le(UInt16(entries.count)); output.le(UInt32(central.count)); output.le(UInt32(offset)); output.le(UInt16(0))
        return output
    }

    private func deflate(_ data: Data) throws -> Data {
        var stream = z_stream()
        XCTAssertEqual(deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(compressBound(uLong(data.count))) + 16)
        let status = data.withUnsafeBytes { input in output.withUnsafeMutableBytes { buffer in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count); stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(buffer.count)
            return zlib.deflate(&stream, Z_FINISH)
        } }
        XCTAssertEqual(status, Z_STREAM_END)
        output.count = Int(stream.total_out)
        return output
    }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

private final class ImportCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
