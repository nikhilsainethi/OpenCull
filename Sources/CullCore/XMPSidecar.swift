import Foundation

/// Writes star ratings and color labels to Adobe-style XMP sidecar files (`IMG_0001.xmp`
/// next to `IMG_0001.CR3`), as read by Lightroom Classic, Adobe Bridge and Capture One.
/// Original photo files are never modified.
public enum XMPSidecar {
    public static let toolkitMarker = "x:xmptk=\"OpenCull\""
    public static let backupExtension = "opencull-backup"

    public enum Outcome: Equatable, Sendable {
        case created
        case updated
        case skippedNoDecision
        case skippedUnsupportedExisting
    }

    public struct Values: Equatable, Sendable {
        public var rating: Int
        public var label: String?
    }

    public static func sidecarURL(for photo: URL) -> URL {
        photo.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// Picks get at least 1 star and a Green label; rejects get rating -1 (Adobe's
    /// "rejected" value) and a Red label; undecided photos keep only their stars.
    public static func values(decision: Decision, rating: Int) -> Values? {
        let stars = max(0, min(5, rating))
        switch decision {
        case .pick: return Values(rating: max(1, stars), label: "Green")
        case .reject: return Values(rating: -1, label: "Red")
        case .undecided: return stars > 0 ? Values(rating: stars, label: nil) : nil
        }
    }

    public static func makeDocument(_ values: Values) -> String {
        var attributes = "    xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"\n    xmp:Rating=\"\(values.rating)\""
        if let label = values.label {
            attributes += "\n    xmp:Label=\"\(escape(label))\""
        }
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="OpenCull">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
        \(attributes)/>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>

        """
    }

    /// Updates rating/label inside an existing sidecar while keeping everything else
    /// (develop settings, keywords...). Returns nil when the file's layout is not understood.
    public static func update(existing: String, with values: Values) -> String? {
        var text = existing
        let namespace = "http://ns.adobe.com/xap/1.0/"
        // If the xap namespace is bound to a prefix other than "xmp", editing would risk
        // writing duplicate properties, so leave the file alone.
        if text.contains(namespace) && !text.contains("xmlns:xmp=\"\(namespace)\"") && !text.contains("xmlns:xmp='\(namespace)'") {
            return nil
        }
        guard text.range(of: "<rdf:Description") != nil else { return nil }

        guard let withRating = set(property: "Rating", value: String(values.rating), in: text) else { return nil }
        text = withRating
        if let label = values.label {
            guard let withLabel = set(property: "Label", value: escape(label), in: text) else { return nil }
            text = withLabel
        }
        if !text.contains("xmlns:xmp=") {
            text = insertIntoDescription(" xmlns:xmp=\"\(namespace)\"", in: text) ?? text
        }
        return text
    }

    /// Writes the sidecar for one photo. Existing sidecars from other apps are backed up
    /// once (`.xmp.opencull-backup`) before the first edit.
    @discardableResult
    public static func write(photo: URL, decision: Decision, rating: Int) throws -> Outcome {
        guard let values = values(decision: decision, rating: rating) else { return .skippedNoDecision }
        let url = sidecarURL(for: photo)
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: url.path) else {
            try makeDocument(values).write(to: url, atomically: true, encoding: .utf8)
            return .created
        }

        let existing = try String(contentsOf: url, encoding: .utf8)
        if existing.contains(toolkitMarker) {
            try makeDocument(values).write(to: url, atomically: true, encoding: .utf8)
            return .updated
        }
        guard let updated = update(existing: existing, with: values) else { return .skippedUnsupportedExisting }
        let backup = url.appendingPathExtension(backupExtension)
        if !fileManager.fileExists(atPath: backup.path) {
            try fileManager.copyItem(at: url, to: backup)
        }
        try updated.write(to: url, atomically: true, encoding: .utf8)
        return .updated
    }

    // MARK: - Helpers

    /// Replaces `xmp:<property>` given as an attribute or element, or inserts it as an
    /// attribute of the first rdf:Description.
    private static func set(property: String, value: String, in text: String) -> String? {
        let attribute = try! NSRegularExpression(pattern: "xmp:\(property)\\s*=\\s*(\"[^\"]*\"|'[^']*')")
        let range = NSRange(text.startIndex..., in: text)
        if attribute.firstMatch(in: text, range: range) != nil {
            return attribute.stringByReplacingMatches(in: text, range: range, withTemplate: "xmp:\(property)=\"\(value)\"")
        }
        let element = try! NSRegularExpression(pattern: "<xmp:\(property)>[^<]*</xmp:\(property)>")
        if element.firstMatch(in: text, range: range) != nil {
            return element.stringByReplacingMatches(in: text, range: range, withTemplate: "<xmp:\(property)>\(value)</xmp:\(property)>")
        }
        return insertIntoDescription(" xmp:\(property)=\"\(value)\"", in: text)
    }

    private static func insertIntoDescription(_ attribute: String, in text: String) -> String? {
        var searchStart = text.startIndex
        while let range = text.range(of: "<rdf:Description", range: searchStart..<text.endIndex) {
            // Make sure this is the whole tag name, not e.g. "<rdf:DescriptionX".
            if range.upperBound < text.endIndex, let next = text[range.upperBound...].first,
               next.isWhitespace || next == ">" || next == "/" {
                var result = text
                result.insert(contentsOf: attribute, at: range.upperBound)
                return result
            }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
