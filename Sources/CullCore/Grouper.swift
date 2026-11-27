import Foundation

public struct GroupingOptions: Codable, Sendable, Equatable {
    /// Maximum time between two consecutive shots for them to be in the same group.
    public var maxTimeGap: Double = 3.0
    /// Minimum Vision embedding similarity (0...1) between consecutive shots in a group.
    public var minSimilarity: Float = 0.80
    /// Minimum layout similarity (blur-tolerant) between consecutive shots in a group.
    public var minLayoutSimilarity: Float = 0.90
    /// Stricter thresholds used when capture times are missing.
    public var minSimilarityWithoutTime: Float = 0.90
    public var minLayoutSimilarityWithoutTime: Float = 0.95

    public init() {}

    public init(from decoder: Decoder) throws {
        // Tolerate settings saved by older versions that lack newer keys.
        let defaults = GroupingOptions()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxTimeGap = try c.decodeIfPresent(Double.self, forKey: .maxTimeGap) ?? defaults.maxTimeGap
        minSimilarity = try c.decodeIfPresent(Float.self, forKey: .minSimilarity) ?? defaults.minSimilarity
        minLayoutSimilarity = try c.decodeIfPresent(Float.self, forKey: .minLayoutSimilarity) ?? defaults.minLayoutSimilarity
        minSimilarityWithoutTime = try c.decodeIfPresent(Float.self, forKey: .minSimilarityWithoutTime) ?? defaults.minSimilarityWithoutTime
        minLayoutSimilarityWithoutTime = try c.decodeIfPresent(Float.self, forKey: .minLayoutSimilarityWithoutTime)
            ?? defaults.minLayoutSimilarityWithoutTime
    }
}

/// Groups bursts and near-duplicates: consecutive shots (by capture time) that were taken
/// close together and look alike, either to Vision's embedding or by overall layout.
public enum Grouper {
    public struct Input: Sendable {
        public var name: String
        public var date: Date?
        public var embedding: Embedding?
        public var layout: Embedding?

        public init(name: String, date: Date?, embedding: Embedding?, layout: Embedding? = nil) {
            self.name = name
            self.date = date
            self.embedding = embedding
            self.layout = layout
        }
    }

    /// Returns a group number for each input (same order as `inputs`). Group numbers start
    /// at 0 and follow capture order.
    public static func group(_ inputs: [Input], options: GroupingOptions = GroupingOptions()) -> [Int] {
        guard !inputs.isEmpty else { return [] }
        let order = inputs.indices.sorted { a, b in
            let da = inputs[a].date, db = inputs[b].date
            switch (da, db) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return inputs[a].name.localizedStandardCompare(inputs[b].name) == .orderedAscending
            }
        }

        var groups = [Int](repeating: 0, count: inputs.count)
        var current = 0
        groups[order[0]] = current
        for k in 1..<order.count {
            let previous = inputs[order[k - 1]], item = inputs[order[k]]
            if !belongTogether(previous, item, options: options) { current += 1 }
            groups[order[k]] = current
        }
        return groups
    }

    static func belongTogether(_ a: Input, _ b: Input, options: GroupingOptions) -> Bool {
        let semantic = similarity(a.embedding, b.embedding)
        let layout = similarity(a.layout, b.layout)
        if let da = a.date, let db = b.date {
            guard abs(db.timeIntervalSince(da)) <= options.maxTimeGap else { return false }
            return (semantic ?? -1) >= options.minSimilarity || (layout ?? -1) >= options.minLayoutSimilarity
        }
        return (semantic ?? -1) >= options.minSimilarityWithoutTime || (layout ?? -1) >= options.minLayoutSimilarityWithoutTime
    }

    private static func similarity(_ a: Embedding?, _ b: Embedding?) -> Float? {
        guard let a, let b else { return nil }
        return a.similarity(to: b)
    }
}
