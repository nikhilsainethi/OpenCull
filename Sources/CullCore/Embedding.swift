import Foundation

/// A float vector stored compactly (raw bytes) when encoded.
public struct Embedding: Codable, Sendable, Equatable {
    public var values: [Float]

    public init(_ values: [Float]) { self.values = values }

    /// Returns a copy scaled to unit length (or nil for an all-zero vector).
    public static func normalized(_ values: [Float]) -> Embedding? {
        let norm = values.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return Embedding(values.map { $0 / norm })
    }

    /// Cosine similarity (1 = identical direction). Assumes both vectors are normalized.
    public func similarity(to other: Embedding) -> Float {
        guard values.count == other.values.count, !values.isEmpty else { return 0 }
        var dot: Float = 0
        for i in values.indices { dot += values[i] * other.values[i] }
        return dot
    }

    public init(from decoder: Decoder) throws {
        let data = try decoder.singleValueContainer().decode(Data.self)
        values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}
