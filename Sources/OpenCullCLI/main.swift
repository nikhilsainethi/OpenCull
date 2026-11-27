import CullCore
import Foundation

// opencull-cli: analyze a folder of photos from the terminal.
//
//   opencull-cli <folder> [--recursive] [--json]

let arguments = Array(CommandLine.arguments.dropFirst())
guard let folderArgument = arguments.first(where: { !$0.hasPrefix("--") }) else {
    FileHandle.standardError.write(Data("usage: opencull-cli <folder> [--recursive] [--json]\n".utf8))
    exit(2)
}
let recursive = arguments.contains("--recursive")
let json = arguments.contains("--json")
let folder = URL(fileURLWithPath: (folderArgument as NSString).expandingTildeInPath)

var items: [PhotoItem]
do {
    items = try PhotoScanner.scan(folder: folder, recursive: recursive)
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}

let analyzer = PhotoAnalyzer()
let start = Date()
let lock = NSLock()
DispatchQueue.concurrentPerform(iterations: items.count) { i in
    let item = items[i]
    let fallback = item.companions.first { !ImageLoader.isRaw($0) }
    let result = Result { try analyzer.analyze(url: item.url, fallback: fallback) }
    lock.lock()
    switch result {
    case .success(let analysis): items[i].analysis = analysis
    case .failure(let error): items[i].analysisError = error.localizedDescription
    }
    lock.unlock()
}
let elapsed = Date().timeIntervalSince(start)
Scorer.evaluate(&items)

func format(_ value: Float?, _ digits: Int = 2) -> String {
    guard let value else { return "-" }
    return String(format: "%.\(digits)f", value)
}

func zipSimilarity(_ a: Embedding?, _ b: Embedding?) -> Float? {
    guard let a, let b else { return nil }
    return a.similarity(to: b)
}

if json {
    struct Row: Encodable {
        var file: String
        var group: Int?
        var groupSize: Int
        var best: Bool
        var score: Float?
        var suggestion: String
        var issues: [String]
        var sharpness: Float?
        var subjectSharpness: Float?
        var faces: Int
        var eyeOpenness: [Float?]
        var faceQuality: [Float?]
        var aesthetic: Float?
        var meanLuminance: Float?
        var highlightClipping: Float?
        var captureDate: Date?
        var error: String?
    }
    let rows = items.map { item in
        Row(file: item.fileName, group: item.groupID, groupSize: item.groupSize, best: item.isBestInGroup,
            score: item.score, suggestion: item.suggestion.rawValue, issues: item.issues.map(\.rawValue),
            sharpness: item.analysis?.sharpness, subjectSharpness: item.analysis?.subjectSharpness,
            faces: item.analysis?.faces.count ?? 0,
            eyeOpenness: item.analysis?.faces.map(\.eyeOpenness) ?? [],
            faceQuality: item.analysis?.faces.map(\.captureQuality) ?? [],
            aesthetic: item.analysis?.aestheticScore, meanLuminance: item.analysis?.meanLuminance,
            highlightClipping: item.analysis?.highlightClipping, captureDate: item.analysis?.captureDate,
            error: item.analysisError)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    FileHandle.standardOutput.write(try encoder.encode(rows))
    print()
} else {
    print("Analyzed \(items.count) photos in \(String(format: "%.1f", elapsed)) s\n")
    // SimPrev = similarity to the previous row: Vision embedding / blur-tolerant layout.
    // Useful when tuning the grouping thresholds.
    let header = ["File", "Grp", "Best", "Score", "Sharp", "Subj", "Faces", "Eyes", "Aesth", "SimPrev", "Suggest", "Issues"]
    print(header.joined(separator: "\t"))
    var previous: PhotoAnalysis?
    for item in items.sorted(by: { ($0.groupID ?? .max, $0.fileName) < ($1.groupID ?? .max, $1.fileName) }) {
        guard let a = item.analysis else {
            print("\(item.fileName)\tERROR: \(item.analysisError ?? "unknown")")
            continue
        }
        let eyes = a.faces.map { format($0.eyeOpenness) }.joined(separator: ",")
        var similarity = "-"
        if let p = previous {
            let semantic = zipSimilarity(p.featurePrint, a.featurePrint)
            let layout = zipSimilarity(p.layoutSignature, a.layoutSignature)
            similarity = "\(format(semantic))/\(format(layout))"
        }
        previous = a
        print([item.fileName, item.groupID.map(String.init) ?? "-", item.isBestInGroup ? "*" : "",
               format(item.score, 1), format(a.sharpness, 0), format(a.subjectSharpness, 0),
               String(a.faces.count), eyes.isEmpty ? "-" : eyes, format(a.aestheticScore), similarity,
               item.suggestion.rawValue, item.issues.map(\.rawValue).joined(separator: ",")].joined(separator: "\t"))
    }
}
