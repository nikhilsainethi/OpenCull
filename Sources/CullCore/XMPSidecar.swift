import Foundation

/// Namespace-aware XMP updates. Existing files are backed up and original image data is never written.
public enum XMPSidecar {
    public static let toolkitMarker = "x:xmptk=\"OpenCull\""
    public static let backupExtension = "opencull-backup"
    private static let xmpNamespace = "http://ns.adobe.com/xap/1.0/"
    private static let rdfNamespace = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    private static let ownershipNamespace = "https://opencull.app/ns/1.0/"
    private static let writerLock = NSLock()

    public enum Outcome: Equatable, Sendable {
        case created, updated, skippedNoDecision, skippedUnsupportedExisting
    }

    public enum SidecarError: Error, LocalizedError {
        case unsafePath(URL)
        public var errorDescription: String? {
            switch self {
            case .unsafePath(let url): return "Refusing to replace a symbolic link or non-regular sidecar: \(url.lastPathComponent)."
            }
        }
    }

    public struct Values: Equatable, Sendable {
        public var rating: Int
        public var label: String?
    }

    public static func sidecarURL(for photo: URL) -> URL {
        photo.deletingPathExtension().appendingPathExtension("xmp")
    }

    public static func values(decision: Decision, rating: Int) -> Values? {
        let stars = max(0, min(5, rating))
        switch decision {
        case .pick: return Values(rating: max(1, stars), label: "Green")
        case .reject: return Values(rating: -1, label: "Red")
        case .undecided: return stars > 0 ? Values(rating: stars, label: nil) : nil
        }
    }

    public static func makeDocument(_ values: Values) -> String {
        let label = values.label.map { " xmp:Label=\"\(escape($0))\" oc:LastLabel=\"\(escape($0))\"" } ?? ""
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="OpenCull">
          <rdf:RDF xmlns:rdf="\(rdfNamespace)">
            <rdf:Description rdf:about="" xmlns:xmp="\(xmpNamespace)" xmlns:oc="\(ownershipNamespace)" oc:SchemaVersion="2" xmp:Rating="\(values.rating)" oc:LastRating="\(values.rating)"\(label)/>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>

        """
    }

    /// Updates the primary RDF subject, preserving unrelated subjects, comments and develop metadata.
    /// Unsupported complex RDF or unsafe XML is skipped rather than guessed at.
    public static func update(existing: String, with values: Values) -> String? {
        guard let parsed = parse(existing) else { return nil }
        let descriptions = primaryDescriptions(in: parsed)
        guard !descriptions.isEmpty,
              set("Rating", value: String(values.rating), namespace: xmpNamespace, preferredPrefix: "xmp", in: descriptions),
              set("LastRating", value: String(values.rating), namespace: ownershipNamespace, preferredPrefix: "oc", in: descriptions),
              set("SchemaVersion", value: "2", namespace: ownershipNamespace, preferredPrefix: "oc", in: descriptions) else { return nil }
        if let label = values.label {
            guard set("Label", value: label, namespace: xmpNamespace, preferredPrefix: "xmp", in: descriptions),
                  set("LastLabel", value: label, namespace: ownershipNamespace, preferredPrefix: "oc", in: descriptions) else { return nil }
        }
        return validatedSerialization(parsed)
    }

    @discardableResult
    public static func write(photo: URL, decision: Decision, rating: Int) throws -> Outcome {
        guard let values = values(decision: decision, rating: rating) else { return .skippedNoDecision }
        writerLock.lock()
        defer { writerLock.unlock() }
        let url = sidecarURL(for: photo)
        try ensureRegularOrAbsent(url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            try makeDocument(values).write(to: url, atomically: true, encoding: .utf8)
            return .created
        }
        let existing = try String(contentsOf: url, encoding: .utf8)
        guard let updated = update(existing: existing, with: values) else { return .skippedUnsupportedExisting }
        try backUp(url)
        try updated.write(to: url, atomically: true, encoding: .utf8)
        return .updated
    }

    /// Clears only values last written by OpenCull. Later foreign changes are left intact.
    @discardableResult
    public static func clear(photo: URL) throws -> Outcome {
        writerLock.lock()
        defer { writerLock.unlock() }
        let url = sidecarURL(for: photo)
        try ensureRegularOrAbsent(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return .skippedNoDecision }
        let existing = try String(contentsOf: url, encoding: .utf8)
        guard let parsed = parse(existing) else { return .skippedUnsupportedExisting }
        let descriptions = primaryDescriptions(in: parsed)
        guard !descriptions.isEmpty else { return .skippedUnsupportedExisting }
        let modernOwnership = !properties("SchemaVersion", namespace: ownershipNamespace, in: descriptions).isEmpty
        let legacyOwned = !modernOwnership && parsed.rootElement()?.attribute(forLocalName: "xmptk", uri: "adobe:ns:meta/")?.stringValue == "OpenCull"
        if legacyOwned {
            // Retain the migration marker so a repeated clear never claims later foreign values.
            guard set("SchemaVersion", value: "2", namespace: ownershipNamespace, preferredPrefix: "oc", in: descriptions) else { return .skippedUnsupportedExisting }
        }
        var changed = false
        for property in ["Rating", "Label"] {
            let recorded = properties("Last" + property, namespace: ownershipNamespace, in: descriptions).first?.node.stringValue
            let candidates = properties(property, namespace: xmpNamespace, in: descriptions)
            for candidate in candidates where candidate.node.stringValue == recorded || (recorded == nil && legacyOwned) {
                remove(candidate)
                changed = true
            }
            for marker in properties("Last" + property, namespace: ownershipNamespace, in: descriptions) {
                remove(marker)
                changed = true
            }
        }
        guard changed else { return .skippedNoDecision }
        guard let output = validatedSerialization(parsed) else { return .skippedUnsupportedExisting }
        try backUp(url)
        try output.write(to: url, atomically: true, encoding: .utf8)
        return .updated
    }

    private struct Property {
        let owner: XMLElement
        let node: XMLNode
        let isAttribute: Bool
    }

    private static func parse(_ text: String) -> XMLDocument? {
        // Do not let a metadata file resolve network/file entities or amplify an internal DTD.
        guard text.utf8.count <= 16 * 1024 * 1024,
              text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              text.range(of: "<!ENTITY", options: .caseInsensitive) == nil,
              let doc = try? XMLDocument(xmlString: text, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever]),
              doc.dtd == nil, let root = doc.rootElement() else { return nil }
        // Some Foundation XML parsers recover unbound prefixes: reject them explicitly.
        func bound(_ element: XMLElement) -> Bool {
            if element.prefix?.isEmpty == false && element.uri == nil { return false }
            for attribute in element.attributes ?? [] where attribute.prefix?.isEmpty == false {
                if attribute.prefix != "xml" && attribute.uri == nil { return false }
            }
            return (element.children ?? []).compactMap { $0 as? XMLElement }.allSatisfy(bound)
        }
        guard bound(root), !primaryDescriptions(in: doc).isEmpty else { return nil }
        return doc
    }

    private static func primaryDescriptions(in document: XMLDocument) -> [XMLElement] {
        guard let root = document.rootElement() else { return [] }
        var descriptions: [XMLElement] = []
        func visit(_ element: XMLElement) {
            if element.localName == "Description", element.uri == rdfNamespace,
               let parent = element.parent as? XMLElement, parent.localName == "RDF", parent.uri == rdfNamespace {
                descriptions.append(element)
            }
            for child in (element.children ?? []).compactMap({ $0 as? XMLElement }) { visit(child) }
        }
        visit(root)
        let subject: (XMLElement) -> String = { $0.attribute(forLocalName: "about", uri: rdfNamespace)?.stringValue ?? "" }
        guard let primary = descriptions.first(where: { subject($0).isEmpty }) ?? descriptions.first else { return [] }
        return descriptions.filter { subject($0) == subject(primary) }
    }

    private static func properties(_ localName: String, namespace: String, in descriptions: [XMLElement]) -> [Property] {
        descriptions.flatMap { description in
            let attrs = (description.attributes ?? []).filter { $0.localName == localName && $0.uri == namespace }
                .map { Property(owner: description, node: $0, isAttribute: true) }
            let elements = (description.children ?? []).compactMap { $0 as? XMLElement }
                .filter { $0.localName == localName && $0.uri == namespace }
                .map { Property(owner: description, node: $0, isAttribute: false) }
            return attrs + elements
        }
    }

    private static func set(_ name: String, value: String, namespace: String, preferredPrefix: String, in descriptions: [XMLElement]) -> Bool {
        let existing = properties(name, namespace: namespace, in: descriptions)
        if let first = existing.first {
            guard first.isAttribute || !(first.node.children ?? []).contains(where: { $0 is XMLElement }) else { return false }
            first.node.stringValue = value
            for duplicate in existing.dropFirst() { remove(duplicate) }
            return true
        }
        guard let owner = descriptions.first else { return false }
        let prefix = ensureNamespace(namespace, preferred: preferredPrefix, on: owner)
        owner.addAttribute(XMLNode.attribute(withName: prefix + ":" + name, uri: namespace, stringValue: value) as! XMLNode)
        return true
    }

    private static func remove(_ property: Property) {
        if property.isAttribute, let name = property.node.name { property.owner.removeAttribute(forName: name) }
        else { property.node.detach() }
    }

    private static func ensureNamespace(_ uri: String, preferred: String, on element: XMLElement) -> String {
        func binding(_ prefix: String) -> String? {
            var cursor: XMLElement? = element
            while let current = cursor {
                if let found = current.namespaces?.first(where: { $0.name == prefix }) { return found.stringValue }
                cursor = current.parent as? XMLElement
            }
            return nil
        }
        var prefix = preferred, suffix = 0
        while let bound = binding(prefix), bound != uri { suffix += 1; prefix = preferred + String(suffix) }
        if binding(prefix) == nil { element.addNamespace(XMLNode.namespace(withName: prefix, stringValue: uri) as! XMLNode) }
        return prefix
    }

    private static func validatedSerialization(_ document: XMLDocument) -> String? {
        let text = document.xmlString(options: [.nodePreserveAll])
        return parse(text) == nil ? nil : text
    }

    private static func ensureRegularOrAbsent(_ url: URL) throws {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           attributes[.type] as? FileAttributeType != .typeRegular { throw SidecarError.unsafePath(url) }
    }

    private static func backUp(_ url: URL) throws {
        let backup = url.appendingPathExtension(backupExtension)
        try ensureRegularOrAbsent(backup)
        if !FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.copyItem(at: url, to: backup) }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
