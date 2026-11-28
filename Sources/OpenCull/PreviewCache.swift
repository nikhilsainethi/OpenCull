import AppKit
import CullCore
import SwiftUI

private final class ImageBox {
    let image: CGImage
    let source: PreviewSource
    init(_ image: CGImage, source: PreviewSource) { self.image = image; self.source = source }
}

enum PreviewResult {
    case image(CGImage)
    case failure(String)
}

enum PreviewSource: Equatable {
    case original, embeddedRaw, limitedRaw(Int), companion(String)

    var caption: String? {
        switch self {
        case .original: return nil
        case .embeddedRaw: return "Embedded RAW preview"
        case .limitedRaw(let limit): return "Embedded RAW preview · up to \(limit) px"
        case .companion(let name): return "Companion · " + name
        }
    }
}

struct SourcedPreview {
    let result: PreviewResult
    let source: PreviewSource
}

/// Versioned, bounded, coalesced previews. Edits and full-resolution views share the export renderer.
actor PreviewCache {
    static let shared = PreviewCache()
    private let cache = NSCache<NSString, ImageBox>()
    private var pending: [String: Task<SourcedPreview, Never>] = [:]
    init() { cache.totalCostLimit = 512 * 1024 * 1024 }

    nonisolated static func versionKey(for item: PhotoItem, size: Int, recipe: EditRecipe = .identity) -> String {
        let files = item.allFiles.map { file -> String in
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            return "\(file.path)|\(bytes)|\(date)|\(inode)"
        }.joined(separator: ";")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let edits = (try? encoder.encode(recipe).base64EncodedString()) ?? "invalid"
        return "\(files)#\(size)#\(edits)"
    }

    func image(for item: PhotoItem, size: Int, recipe: EditRecipe = .identity) async -> CGImage? {
        if case .image(let image) = await result(for: item, size: size, recipe: recipe) { return image }
        return nil
    }

    func burstPreview(for item: PhotoItem, size: Int) async -> SourcedPreview {
        await load(item, size: size, recipe: .identity, preferRawPreview: ImageLoader.isRaw(item.url))
    }

    func result(for item: PhotoItem, size: Int, recipe: EditRecipe = .identity) async -> PreviewResult {
        await load(item, size: size, recipe: recipe, preferRawPreview: false).result
    }

    private func load(_ item: PhotoItem, size: Int, recipe: EditRecipe, preferRawPreview: Bool) async -> SourcedPreview {
        let key = Self.versionKey(for: item, size: size, recipe: recipe) + (preferRawPreview ? "#burst" : "")
        if let hit = cache.object(forKey: key as NSString) { return SourcedPreview(result: .image(hit.image), source: hit.source) }
        if let job = pending[key] { return await job.value }
        let job = Task.detached(priority: .userInitiated) { () -> SourcedPreview in
            var files = item.allFiles
            // Vision examines the primary RAW preview first. Using a companion
            // ahead of it could center the face on a different camera crop.
            if preferRawPreview && !ImageLoader.supportsFullRawDecoding(url: item.url) {
                // ImageIO may synthesize a thumbnail when the container has none.
                // Bound simultaneous review decodes and identify a capped representation.
                let limit = size > 0 ? size : 8192
                if let embedded = ImageLoader.loadImage(url: item.url, maxPixelSize: limit) {
                    let source: PreviewSource = size == 0 && max(embedded.width, embedded.height) >= limit
                        ? .limitedRaw(limit) : .embeddedRaw
                    return SourcedPreview(result: .image(embedded), source: source)
                }
                files = item.companions.first { !ImageLoader.isRaw($0) }.map { [$0] } ?? []
            }
            var lastError = "Could not decode this photo."
            for file in files {
                do {
                    let image = try PhotoEditor.render(url: file, recipe: recipe, maxPixelSize: size > 0 ? size : nil)
                    return SourcedPreview(result: .image(image), source: file == item.url ? .original : .companion(file.lastPathComponent))
                } catch { lastError = error.localizedDescription }
            }
            return SourcedPreview(result: .failure(lastError), source: .original)
        }
        pending[key] = job
        let preview = await job.value
        pending.removeValue(forKey: key)
        if case .image(let image) = preview.result {
            cache.setObject(ImageBox(image, source: preview.source), forKey: key as NSString, cost: image.width * image.height * 4)
        }
        return preview
    }
}

struct PhotoImageView: View {
    let item: PhotoItem
    let size: Int
    var showsPlaceholder = true
    var recipe: EditRecipe = .identity
    @State private var image: CGImage?
    @State private var error: String?
    @State private var loadedKey: String?
    private var key: String { PreviewCache.versionKey(for: item, size: size, recipe: recipe) }

    var body: some View {
        ZStack {
            if let image, loadedKey == key {
                Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else if let error, loadedKey == key, showsPlaceholder {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle").font(.title3)
                    Text("Preview unavailable").font(.caption2).lineLimit(1)
                }.foregroundStyle(.secondary).help(error)
            } else if showsPlaceholder {
                Rectangle().fill(.quaternary)
                ProgressView().controlSize(.small)
            }
        }
        .task(id: key) {
            let current = key
            let result = await PreviewCache.shared.result(for: item, size: size, recipe: recipe)
            guard !Task.isCancelled else { return }
            switch result {
            case .image(let loaded): image = loaded; error = nil
            case .failure(let message): image = nil; error = message
            }
            loadedKey = current
        }
    }
}
