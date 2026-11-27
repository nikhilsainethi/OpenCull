import CullCore
import Foundation

// opencull-cli: analyze a folder of photos from the terminal.
//
//   opencull-cli <folder> [--recursive] [--json]

let arguments = Array(CommandLine.arguments.dropFirst())
let usage = "usage: opencull-cli <folder> [--recursive] [--json] [--intent general|posedPortrait|groupPortrait|candid|creative]\n"
var recursive = false, json = false
var folderArgument: String?
var intent = ShootingIntent.general
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--recursive": recursive = true
    case "--json": json = true
    case "--intent":
        index += 1
        guard index < arguments.count, let value = ShootingIntent(rawValue: arguments[index]) else {
            FileHandle.standardError.write(Data(usage.utf8)); exit(2)
        }
        intent = value
    case "--help", "-h": print(usage, terminator: ""); exit(0)
    default:
        guard !argument.hasPrefix("-"), folderArgument == nil else {
            FileHandle.standardError.write(Data(usage.utf8)); exit(2)
        }
        folderArgument = argument
    }
    index += 1
}
guard let folderArgument else { FileHandle.standardError.write(Data(usage.utf8)); exit(2) }
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
// Immutable job inputs are separate from the mutable result array. Even disjoint element
// access can race through Swift Array's storage/exclusivity machinery.
let jobs = items
var results: [(Int, Result<PhotoAnalysis, Error>)] = []
DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
    autoreleasepool {
        let item = jobs[i]
        let fallback = item.companions.first { !ImageLoader.isRaw($0) }
        let result = Result { try analyzer.analyze(url: item.url, fallback: fallback) }
        lock.lock()
        results.append((i, result))
        lock.unlock()
    }
}
let manifest = try? PhotoImportManifest.read(from: folder)
let albumComponents = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
let metadataByRelative = Dictionary((manifest?.items ?? []).map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
for (i, result) in results {
    switch result {
    case .success(var analysis):
        if analysis.captureDate == nil {
            let components = items[i].url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            let relative = components.starts(with: albumComponents) ? components.dropFirst(albumComponents.count).joined(separator: "/") : ""
            analysis.captureDate = metadataByRelative[relative]?.captureDateOverride
        }
        items[i].analysis = analysis
    case .failure(let error): items[i].analysisError = error.localizedDescription
    }
}
let elapsed = Date().timeIntervalSince(start)
var options = ScoringOptions(); options.shootingIntent = intent
Scorer.evaluate(&items, scoring: options)

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
        var shootingIntent: String
        var eyeStates: [String]
        var cameraAttention: [String]
        var people: [String]
        var eyeOpenness: [Float?]
        var faceQuality: [Float?]
        var aesthetic: Float?
        var meanLuminance: Float?
        var highlightClipping: Float?
        var captureDate: Date?
        var error: String?
        var warnings: [String]
        var labels: [String]
        var needsReview: Bool
    }
    let rows = items.map { item in
        Row(file: item.fileName, group: item.groupID, groupSize: item.groupSize, best: item.isBestInGroup,
            score: item.score, suggestion: item.suggestion.rawValue, issues: item.issues.map(\.rawValue),
            sharpness: item.analysis?.sharpness, subjectSharpness: item.analysis?.subjectSharpness,
            faces: item.analysis?.faces.count ?? 0,
            shootingIntent: intent.rawValue,
            eyeStates: item.analysis?.faces.map { PeopleAssessment.assess($0, intent: intent).eyeState.rawValue } ?? [],
            cameraAttention: item.analysis?.faces.map { PeopleAssessment.assess($0, intent: intent).cameraAttention.rawValue } ?? [],
            people: item.analysis?.faces.map { PeopleAssessment.assess($0, intent: intent).summary } ?? [],
            eyeOpenness: item.analysis?.faces.map(\.eyeOpenness) ?? [],
            faceQuality: item.analysis?.faces.map(\.captureQuality) ?? [],
            aesthetic: item.analysis?.aestheticScore, meanLuminance: item.analysis?.meanLuminance,
            highlightClipping: item.analysis?.highlightClipping, captureDate: item.analysis?.captureDate,
            error: item.analysisError, warnings: item.reviewReasons, labels: item.analysis?.labels ?? [], needsReview: item.needsReview)
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
let failures = items.filter { $0.analysisError != nil }.count
if failures > 0 {
    FileHandle.standardError.write(Data("\(failures) photo(s) could not be analyzed; see per-photo errors.\n".utf8))
    exit(3)
}
