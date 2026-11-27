import Foundation

/// An explicit photographer edit paired with technical measurements, never pixels.
public struct AdaptiveStyleExample: Equatable, Sendable {
    public var analysis: PhotoAnalysis
    public var recipe: EditRecipe
    public init(analysis: PhotoAnalysis, recipe: EditRecipe) { self.analysis = analysis; self.recipe = recipe }
}

/// A small, local editing baseline. It learns photometric controls from explicit
/// examples. Composition is excluded, and it does not model photographic intent.
public struct AdaptiveStyleProfile: Codable, Equatable, Sendable {
    public static let minimumExamples = 6
    public private(set) var sampleCount: Int
    private var coefficients: [[Double]]
    private var featureMeans: [Double]
    private var featureScales: [Double]
    private var featureMinimums: [Double]
    private var featureMaximums: [Double]
    private var targetMeans: [Double]
    private var targetMinimums: [Double]
    private var targetMaximums: [Double]
    private var version = 1
    private enum CodingKeys: String, CodingKey {
        case version, sampleCount, coefficients, featureMeans, featureScales, featureMinimums, featureMaximums
        case targetMeans, targetMinimums, targetMaximums
    }

    public init(examples: [AdaptiveStyleExample]) throws {
        guard examples.count >= Self.minimumExamples else { throw AdaptiveStyleError.notEnoughExamples }
        let x = try examples.map { try Self.features($0.analysis) }
        let y = try examples.map { example -> [Double] in _ = try example.recipe.validated(); return Self.targets(example.recipe) }
        guard let minimum = x.map({ $0[0] }).min(), let maximum = x.map({ $0[0] }).max(), maximum-minimum >= 0.05 else {
            throw AdaptiveStyleError.insufficientDiversity
        }
        guard examples.contains(where: {
            var photometric = $0.recipe; photometric.crop = nil; photometric.rotation = 0
            return !photometric.isIdentity
        }) else { throw AdaptiveStyleError.noAdjustments }
        sampleCount = examples.count
        let means = Self.means(x)
        featureMeans = means
        featureMinimums = (0..<7).map { i in x.map { $0[i] }.min()! }
        featureMaximums = (0..<7).map { i in x.map { $0[i] }.max()! }
        let scales = (0..<7).map { i in
            let mean = means[i]
            return max(0.03, sqrt(x.reduce(0) { $0 + pow($1[i]-mean, 2) } / Double(x.count)))
        }
        featureScales = scales
        targetMeans = Self.means(y)
        targetMinimums = (0..<10).map { i in y.map { $0[i] }.min()! }
        targetMaximums = (0..<10).map { i in y.map { $0[i] }.max()! }
        let standardized = x.map { row in (0..<7).map { (row[$0]-means[$0])/scales[$0] } }
        // Mean-centered targets supply the unpenalized intercept. Ridge on the
        // standardized features controls collinearity and small-sample variance.
        var gram = Array(repeating: Array(repeating: 0.0, count: 7), count: 7)
        for i in 0..<7 {
            for j in 0..<7 { gram[i][j] = standardized.reduce(0) { $0 + $1[i] * $1[j] } / Double(x.count) }
            gram[i][i] += 0.12
        }
        coefficients = []
        for target in 0..<10 {
            let rhs = (0..<7).map { column in
                x.indices.reduce(0.0) { $0 + standardized[$1][column] * (y[$1][target]-targetMeans[target]) } / Double(x.count)
            }
            coefficients.append(try Self.solvePositiveDefinite(gram, rhs))
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        sampleCount = try c.decode(Int.self, forKey: .sampleCount)
        coefficients = try c.decode([[Double]].self, forKey: .coefficients)
        featureMeans = try c.decode([Double].self, forKey: .featureMeans)
        featureScales = try c.decode([Double].self, forKey: .featureScales)
        featureMinimums = try c.decode([Double].self, forKey: .featureMinimums)
        featureMaximums = try c.decode([Double].self, forKey: .featureMaximums)
        targetMeans = try c.decode([Double].self, forKey: .targetMeans)
        targetMinimums = try c.decode([Double].self, forKey: .targetMinimums)
        targetMaximums = try c.decode([Double].self, forKey: .targetMaximums)
        let features = [featureMeans, featureScales, featureMinimums, featureMaximums]
        let targets = [targetMeans, targetMinimums, targetMaximums]
        guard version == 1, sampleCount >= Self.minimumExamples,
              features.allSatisfy({ $0.count == 7 && $0.allSatisfy(\.isFinite) }),
              targets.allSatisfy({ $0.count == 10 && $0.allSatisfy(\.isFinite) }),
              coefficients.count == 10, coefficients.allSatisfy({ $0.count == 7 && $0.allSatisfy { $0.isFinite && abs($0) < 1000 } }),
              featureScales.allSatisfy({ $0 >= 0.03 }),
              (0..<7).allSatisfy({ featureMinimums[$0]-1e-9 <= featureMeans[$0] && featureMeans[$0] <= featureMaximums[$0]+1e-9 }),
              (0..<10).allSatisfy({ targetMinimums[$0]-1e-9 <= targetMeans[$0] && targetMeans[$0] <= targetMaximums[$0]+1e-9
                  && Self.targetBounds[$0].contains(targetMinimums[$0]) && Self.targetBounds[$0].contains(targetMaximums[$0]) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid adaptive editing profile dimensions or values."))
        }
    }

    public func recipe(for analysis: PhotoAnalysis) -> EditRecipe {
        guard let features = try? Self.features(analysis) else { return Self.recipe(targetMeans) }
        let standardized = (0..<7).map { min(3, max(-3, (features[$0]-featureMeans[$0])/featureScales[$0])) }
        var outsideDistance = 0.0
        for i in 0..<7 where featureMaximums[i]-featureMinimums[i] >= 0.02 {
            let outside = max(0, featureMinimums[i]-features[i], features[i]-featureMaximums[i]) / featureScales[i]
            outsideDistance += outside * outside
        }
        // Outside observed lighting/content, shrink toward the learned fixed
        // component rather than extrapolating large tonal/color corrections.
        let reliability = 1 / (1 + 0.2 * outsideDistance)
        let prediction = (0..<10).map { target -> Double in
            let change = zip(coefficients[target], standardized).reduce(0.0) { $0 + $1.0 * $1.1 }
            let margin = 0.02 + 0.1 * (targetMaximums[target]-targetMinimums[target])
            return min(targetMaximums[target]+margin, max(targetMinimums[target]-margin, targetMeans[target]+reliability*change))
        }
        return Self.recipe(prediction)
    }

    private static let targetBounds: [ClosedRange<Double>] = [-5...5, (-4500.0/5500)...1, -1...1, -0.5...1,
                                                               -1...0, 0...1, -1...1, -1...1, 0...1, 0...1]
    private static func targets(_ r: EditRecipe) -> [Double] {
        [r.exposure, (r.temperature-6500)/5500, r.tint/150, r.contrast-1, r.highlights-1,
         r.shadows, r.saturation-1, r.vibrance, r.sharpness/2, r.noiseReduction]
    }
    private static func recipe(_ values: [Double]) -> EditRecipe {
        var r = EditRecipe()
        r.exposure = values[0]; r.temperature = 6500 + values[1] * 5500; r.tint = values[2] * 150
        r.contrast = 1 + values[3]; r.highlights = 1 + values[4]; r.shadows = values[5]
        r.saturation = 1 + values[6]; r.vibrance = values[7]; r.sharpness = values[8] * 2; r.noiseReduction = values[9]
        return r.clamped()
    }

    private static func features(_ a: PhotoAnalysis) throws -> [Double] {
        guard a.pixelWidth > 0, a.pixelHeight > 0, a.analysisWarnings.isEmpty,
              [a.meanLuminance, a.highlightClipping, a.shadowClipping].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              a.aestheticScore.map({ $0.isFinite && (-1...1).contains($0) }) ?? true else { throw AdaptiveStyleError.invalidExample }
        var area = 0.0, qualities: [Double] = []
        for face in a.faces {
            let box = face.boundingBox
            guard [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite), box.width > 0, box.height > 0,
                  box.minX >= 0, box.minY >= 0, box.maxX <= 1.00001, box.maxY <= 1.00001 else { throw AdaptiveStyleError.invalidExample }
            area += Double(box.width * box.height)
            if let quality = face.captureQuality {
                guard quality.isFinite, (0...1).contains(quality) else { throw AdaptiveStyleError.invalidExample }
                qualities.append(Double(quality))
            }
        }
        let brightness = Double(a.meanLuminance)
        return [brightness, log(max(0.005, brightness)), Double(a.highlightClipping), Double(a.shadowClipping),
                min(1, area), qualities.isEmpty ? 0.5 : qualities.reduce(0,+)/Double(qualities.count), Double((a.aestheticScore ?? 0)+1)/2]
    }
    private static func means(_ rows: [[Double]]) -> [Double] {
        rows[0].indices.map { i in rows.reduce(0.0) { $0 + $1[i] } / Double(rows.count) }
    }
    private static func solvePositiveDefinite(_ a: [[Double]], _ b: [Double]) throws -> [Double] {
        let n = b.count
        var l = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        for i in 0..<n {
            for j in 0...i {
                var value = a[i][j]
                for k in 0..<j { value -= l[i][k] * l[j][k] }
                if i == j {
                    guard value.isFinite, value > 1e-12 else { throw AdaptiveStyleError.cannotFit }
                    l[i][j] = sqrt(value)
                } else { l[i][j] = value / l[j][j] }
            }
        }
        var y = Array(repeating: 0.0, count: n), result = y
        for i in 0..<n {
            var value = b[i]
            for j in 0..<i { value -= l[i][j] * y[j] }
            y[i] = value / l[i][i]
        }
        for i in stride(from: n-1, through: 0, by: -1) {
            var value = y[i]
            for j in (i+1)..<n { value -= l[j][i] * result[j] }
            result[i] = value / l[i][i]
        }
        guard result.allSatisfy(\.isFinite) else { throw AdaptiveStyleError.cannotFit }
        return result
    }
}

public enum AdaptiveStyleError: Error, LocalizedError {
    case notEnoughExamples, insufficientDiversity, invalidExample, noAdjustments, cannotFit
    public var errorDescription: String? {
        switch self {
        case .notEnoughExamples: return "Select at least six edited photos with completed analysis to learn a local profile."
        case .insufficientDiversity: return "The examples need more varied brightness. Include photographs from different lighting, or save a fixed style instead."
        case .invalidExample: return "Some examples have invalid or incomplete measurements. Finish or retry analysis before learning a profile."
        case .noAdjustments: return "Adjust light, color or detail in the examples first. Crop and rotation are not learned."
        case .cannotFit: return "Could not fit a stable editing profile from these examples."
        }
    }
}
