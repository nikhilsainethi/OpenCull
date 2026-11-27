import AppKit
import CullCore
import SwiftUI

/// Wraps a CGImage so it can live in NSCache.
private final class ImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// In-memory cache of decoded previews, shared by the grid and the detail view.
final class PreviewCache: @unchecked Sendable {
    static let shared = PreviewCache()
    private let cache = NSCache<NSString, ImageBox>()

    private init() {
        cache.totalCostLimit = 768 * 1024 * 1024
    }

    func image(for item: PhotoItem, size: Int) async -> CGImage? {
        let key = "\(item.id)#\(size)" as NSString
        if let hit = cache.object(forKey: key) { return hit.image }
        let files = item.allFiles
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            for file in files {
                if let image = ImageLoader.loadImage(url: file, maxPixelSize: size) { return image }
            }
            return nil
        }.value
        if let image {
            cache.setObject(ImageBox(image), forKey: key, cost: image.width * image.height * 4)
        }
        return image
    }
}

/// Shows a photo preview at a given decode size.
struct PhotoImageView: View {
    let item: PhotoItem
    let size: Int
    var showsPlaceholder = true

    @State private var image: CGImage?
    @State private var loadedKey: String?

    private var key: String { "\(item.id)#\(size)" }

    var body: some View {
        ZStack {
            if let image, loadedKey == key {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if showsPlaceholder {
                Rectangle().fill(.quaternary)
                ProgressView().controlSize(.small)
            }
        }
        .task(id: key) {
            let currentKey = key
            let loaded = await PreviewCache.shared.image(for: item, size: size)
            guard !Task.isCancelled else { return }
            image = loaded
            loadedKey = currentKey
        }
    }
}
