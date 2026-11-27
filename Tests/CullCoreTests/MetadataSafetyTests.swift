import Foundation
import XCTest
@testable import CullCore

final class MetadataSafetyTests: XCTestCase {
    private let xmp = "http://ns.adobe.com/xap/1.0/"
    private let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-Metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func property(_ name: String, in text: String) throws -> [String] {
        let doc = try XMLDocument(xmlString: text)
        return try doc.nodes(forXPath: "//@*[local-name()='\(name)'] | //*[local-name()='\(name)']")
            .filter { $0.uri == xmp }.compactMap(\.stringValue)
    }

    func testReexportPreservesDevelopMetadataAndBacksUpAppDocument() throws {
        let dir = try directory(), photo = dir.appendingPathComponent("A.CR3")
        try Data([1]).write(to: photo)
        try XMPSidecar.write(photo: photo, decision: .pick, rating: 2)
        let url = XMPSidecar.sidecarURL(for: photo)
        let original = try String(contentsOf: url, encoding: .utf8)
        let edited = original.replacingOccurrences(of: "rdf:about=\"\"", with: "rdf:about=\"\" xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\" crs:Exposure2012=\"+0.50\"")
        try edited.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try XMPSidecar.write(photo: photo, decision: .pick, rating: 5), .updated)
        let result = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(result.contains("crs:Exposure2012=\"+0.50\""))
        XCTAssertEqual(try String(contentsOf: url.appendingPathExtension(XMPSidecar.backupExtension), encoding: .utf8), edited)
    }

    func testRatingLikeCommentDoesNotMaskActualProperty() throws {
        let input = """
        <rdf:RDF xmlns:rdf="\(rdf)"><!-- xmp:Rating="2" -->
        <rdf:Description rdf:about="" xmlns:xmp="\(xmp)"/></rdf:RDF>
        """
        let result = try XCTUnwrap(XMPSidecar.update(existing: input, with: .init(rating: 5, label: "Green")))
        XCTAssertEqual(try property("Rating", in: result), ["5"])
        XCTAssertTrue(result.contains("xmp:Rating=\"2\""), "Comments are unrelated metadata")
    }

    func testTypedElementRatingIsUpdatedExactlyOnce() throws {
        let input = """
        <rdf:RDF xmlns:rdf="\(rdf)"><rdf:Description rdf:about="" xmlns:xmp="\(xmp)">
        <xmp:Rating rdf:datatype="http://www.w3.org/2001/XMLSchema#integer">2</xmp:Rating>
        </rdf:Description></rdf:RDF>
        """
        let result = try XCTUnwrap(XMPSidecar.update(existing: input, with: .init(rating: 5, label: "Green")))
        XCTAssertEqual(try property("Rating", in: result), ["5"])
    }

    func testLocallyScopedNamespaceRemainsValid() throws {
        let input = """
        <rdf:RDF xmlns:rdf="\(rdf)">
        <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" dc:format="image/raw"/>
        <rdf:Description rdf:about="" xmlns:xmp="\(xmp)" xmp:Rating="2"/>
        </rdf:RDF>
        """
        let result = try XCTUnwrap(XMPSidecar.update(existing: input, with: .init(rating: 5, label: "Green")))
        XCTAssertEqual(try property("Rating", in: result), ["5"])
        XCTAssertEqual(try property("Label", in: result), ["Green"])
        XCTAssertTrue(result.contains("dc:format=\"image/raw\""))
    }

    func testAlternateXMPPrefixIsSupportedByNamespaceURI() throws {
        let input = """
        <rdf:RDF xmlns:rdf="\(rdf)"><rdf:Description rdf:about="" xmlns:xap="\(xmp)" xap:Rating="2"/></rdf:RDF>
        """
        let result = try XCTUnwrap(XMPSidecar.update(existing: input, with: .init(rating: 3, label: nil)))
        XCTAssertEqual(try property("Rating", in: result), ["3"])
    }

    func testExternalEntityDocumentsAreRejectedWithoutResolution() {
        let input = """
        <!DOCTYPE x [<!ENTITY payload SYSTEM "file:///private/etc/passwd">]>
        <rdf:RDF xmlns:rdf="\(rdf)"><rdf:Description rdf:about="" xmlns:xmp="\(xmp)"><xmp:Label>&payload;</xmp:Label></rdf:Description></rdf:RDF>
        """
        XCTAssertNil(XMPSidecar.update(existing: input, with: .init(rating: 3, label: "Green")))
    }

    func testMalformedExistingXMLIsNotUpdated() {
        let input = "<rdf:Description xmlns:xmp=\"\(xmp)\" xmp:Rating=\"2\">"
        XCTAssertNil(XMPSidecar.update(existing: input, with: .init(rating: 3, label: nil)))
    }

    func testDestinationCollisionSkipsWholePhotoBundle() throws {
        let dir = try directory(), photo = dir.appendingPathComponent("A.CR3")
        try Data([1,2,3]).write(to: photo)
        try XMPSidecar.write(photo: photo, decision: .pick, rating: 3)
        let destination = dir.appendingPathComponent("Export")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data([9,9,9]).write(to: destination.appendingPathComponent("A.CR3"))
        var item = PhotoItem(url: photo); item.decision = .pick
        let result = Exporter.copy([item], to: destination)
        XCTAssertEqual(result.copiedPhotos, 0)
        XCTAssertEqual(result.skippedExisting, 1)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("A.CR3")), Data([9,9,9]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("A.xmp").path))
    }

    func testCopyUsesCurrentChoiceAndLeavesSourceSidecarUntouched() throws {
        let dir = try directory(), photo = dir.appendingPathComponent("A.CR3")
        try Data([1]).write(to: photo)
        try XMPSidecar.write(photo: photo, decision: .reject, rating: 0)
        let source = XMPSidecar.sidecarURL(for: photo)
        let original = try Data(contentsOf: source)
        var item = PhotoItem(url: photo); item.decision = .pick; item.rating = 5
        let destination = dir.appendingPathComponent("Export")
        let result = Exporter.copy([item], to: destination)
        XCTAssertEqual(result.copiedPhotos, 1)
        let exported = try String(contentsOf: destination.appendingPathComponent("A.xmp"), encoding: .utf8)
        XCTAssertEqual(try property("Rating", in: exported), ["5"])
        XCTAssertEqual(try property("Label", in: exported), ["Green"])
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testMissingCompanionDoesNotLeavePartialExport() throws {
        let dir = try directory(), photo = dir.appendingPathComponent("A.CR3")
        try Data([1]).write(to: photo)
        let item = PhotoItem(url: photo, companions: [dir.appendingPathComponent("A.JPG")])
        let destination = dir.appendingPathComponent("Export")
        let result = Exporter.copy([item], to: destination)
        XCTAssertEqual(result.copiedPhotos, 0)
        XCTAssertFalse(result.failures.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func testSidecarSymlinkIsRejectedAndTargetUnchanged() throws {
        let dir = try directory(), photo = dir.appendingPathComponent("A.CR3")
        let target = dir.appendingPathComponent("other.xmp")
        let original = XMPSidecar.makeDocument(.init(rating: 2, label: "Red"))
        try original.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: XMPSidecar.sidecarURL(for: photo), withDestinationURL: target)
        XCTAssertThrowsError(try XMPSidecar.write(photo: photo, decision: .pick, rating: 5))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), original)
    }

    func testCompanionReplacementInvalidatesAnalysisKey() throws {
        let dir = try directory(), raw = dir.appendingPathComponent("A.CR3"), jpg = dir.appendingPathComponent("A.JPG")
        try Data([0]).write(to: raw); try Data([1,2,3]).write(to: jpg)
        let item = PhotoItem(url: raw, companions: [jpg])
        let store = SessionStore(folder: dir, baseDirectory: dir.appendingPathComponent("Sessions"))
        let first = store.analysisKey(for: item)
        try Data([8,8,8]).write(to: jpg)
        XCTAssertNotEqual(first, store.analysisKey(for: item))
    }

    func testFingerprintKeepsSubsecondModificationPrecision() throws {
        let dir = try directory(), photo = dir.appendingPathComponent("A.CR3")
        try Data([1,2,3]).write(to: photo)
        let item = PhotoItem(url: photo), store = SessionStore(folder: dir, baseDirectory: dir.appendingPathComponent("Sessions"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000.1)], ofItemAtPath: photo.path)
        let a = store.fingerprint(for: item)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000.2)], ofItemAtPath: photo.path)
        XCTAssertNotEqual(a, store.fingerprint(for: item))
    }

    func testClearPreservesDevelopSettingsAndLaterForeignRatings() throws {
        let dir = try directory(), photo = dir.appendingPathComponent("A.CR3")
        try XMPSidecar.write(photo: photo, decision: .pick, rating: 3)
        let sidecar = XMPSidecar.sidecarURL(for: photo)
        var text = try String(contentsOf: sidecar, encoding: .utf8)
        text = text.replacingOccurrences(of: "rdf:about=\"\"", with: "rdf:about=\"\" xmlns:crs=\"urn:develop\" crs:Exposure=\"1.2\"")
        try text.write(to: sidecar, atomically: true, encoding: .utf8)
        XCTAssertEqual(try XMPSidecar.clear(photo: photo), .updated)
        let cleared = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertEqual(try property("Rating", in: cleared), [])
        XCTAssertEqual(try property("Label", in: cleared), [])
        XCTAssertTrue(cleared.contains("crs:Exposure=\"1.2\""))

        // A later editor owns this value; repeating Clear must not remove it.
        let foreign = cleared.replacingOccurrences(of: "rdf:about=\"\"", with: "rdf:about=\"\" xmp:Rating=\"4\"")
        try foreign.write(to: sidecar, atomically: true, encoding: .utf8)
        XCTAssertEqual(try XMPSidecar.clear(photo: photo), .skippedNoDecision)
        XCTAssertEqual(try property("Rating", in: String(contentsOf: sidecar, encoding: .utf8)), ["4"])
    }

    func testClearDoesNotRemoveAValueChangedByAnotherEditor() throws {
        let dir = try directory(), photo = dir.appendingPathComponent("A.CR3")
        try XMPSidecar.write(photo: photo, decision: .pick, rating: 3)
        let sidecar = XMPSidecar.sidecarURL(for: photo)
        let changed = try String(contentsOf: sidecar, encoding: .utf8).replacingOccurrences(of: "xmp:Rating=\"3\"", with: "xmp:Rating=\"4\"")
        try changed.write(to: sidecar, atomically: true, encoding: .utf8)
        XCTAssertEqual(try XMPSidecar.clear(photo: photo), .updated)
        XCTAssertEqual(try property("Rating", in: String(contentsOf: sidecar, encoding: .utf8)), ["4"])
    }

    func testUpdateDoesNotChangeOtherRDFSubjects() throws {
        let input = """
        <rdf:RDF xmlns:rdf="\(rdf)" xmlns:xmp="\(xmp)">
        <rdf:Description rdf:about="" xmp:Rating="2"/>
        <rdf:Description rdf:about="urn:unrelated" xmp:Rating="1"/>
        </rdf:RDF>
        """
        let result = try XCTUnwrap(XMPSidecar.update(existing: input, with: .init(rating: 5, label: "Green")))
        XCTAssertEqual(try property("Rating", in: result), ["5", "1"])
    }

    func testDuplicateRatingFormsBecomeOneProperty() throws {
        let input = """
        <rdf:RDF xmlns:rdf="\(rdf)" xmlns:xmp="\(xmp)">
        <rdf:Description rdf:about="" xmp:Rating="2"><xmp:Rating>3</xmp:Rating></rdf:Description>
        <rdf:Description rdf:about="" xmp:Rating="4"/>
        </rdf:RDF>
        """
        let result = try XCTUnwrap(XMPSidecar.update(existing: input, with: .init(rating: 5, label: nil)))
        XCTAssertEqual(try property("Rating", in: result), ["5"])
    }

    func testCorruptDecisionsThrowAndKeepRecoverableCopy() throws {
        let dir = try directory(), store = SessionStore(folder: dir.appendingPathComponent("Shoot"), baseDirectory: dir.appendingPathComponent("Sessions"))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let url = store.directory.appendingPathComponent("decisions.json"), bytes = Data("{broken".utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try store.readDecisions())
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("corrupt-backup")), bytes)
    }

    func testEntryFingerprintRoundTripAndLegacyDecode() throws {
        let entry = SessionStore.Entry(decision: .pick, rating: 3, fingerprint: "version-1")
        XCTAssertEqual(try JSONDecoder().decode(SessionStore.Entry.self, from: JSONEncoder().encode(entry)), entry)
        let old = Data("{\"decision\":\"pick\",\"rating\":3}".utf8)
        XCTAssertNil(try JSONDecoder().decode(SessionStore.Entry.self, from: old).fingerprint)
    }

    func testSameStemIndependentExportsCannotShareMetadata() throws {
        let dir = try directory(), a = dir.appendingPathComponent("A.jpg"), b = dir.appendingPathComponent("A.png")
        try Data([1]).write(to: a); try Data([2]).write(to: b)
        var first = PhotoItem(url: a), second = PhotoItem(url: b)
        first.decision = .pick; first.rating = 5
        second.decision = .pick; second.rating = 1
        let dest = dir.appendingPathComponent("Export")
        let result = Exporter.copy([first, second], to: dest)
        XCTAssertEqual(result.copiedPhotos, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("A.png").path))
        XCTAssertEqual(try property("Rating", in: String(contentsOf: dest.appendingPathComponent("A.xmp"), encoding: .utf8)), ["5"])
    }
}
