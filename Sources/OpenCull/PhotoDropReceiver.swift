import AppKit
import CullCore
import SwiftUI

/// A received file promise belongs to the receiver until the caller finishes copying it.
/// Call cleanup after the asynchronous import, including cancellation/error paths.
struct PhotoDropPayload: Sendable {
    let urls: [URL]
    let ownedTemporaryDirectory: URL?
    let receiptID: UUID?

    init(urls: [URL], ownedTemporaryDirectory: URL?, receiptID: UUID? = nil) {
        self.urls = urls
        self.ownedTemporaryDirectory = ownedTemporaryDirectory
        self.receiptID = receiptID
    }

    func cleanup() {
        guard let directory = ownedTemporaryDirectory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Shared deletion boundary for potentially large owned promise directories.
final class PhotoDropCleanup: @unchecked Sendable {
    static let shared = PhotoDropCleanup()
    private let remove: @Sendable (URL) -> Void
    private let queue = DispatchQueue(label: "OpenCull owned drop cleanup", qos: .utility)

    init(remove: @escaping @Sendable (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }) {
        self.remove = remove
    }

    func schedule(_ ownedDirectory: URL) {
        queue.async { [remove] in remove(ownedDirectory) }
    }
}

enum PhotoDropClassification: Equatable {
    case promises
    case files([URL])
    case tooManyFiles
    case unsupported
}

enum PhotoDropPolicy {
    static let maximumFiles = 5_000
    static let downloadInstruction = "Drop local photo files, folders, or ZIP archives. For Google Photos, download the selection or a Takeout archive first; website links cannot supply the original photo."

    /// This only examines pasteboard values: it never opens or downloads a source.
    static func classify(hasPromises: Bool, localURLs: [URL], hasRemoteRepresentation: Bool) -> PhotoDropClassification {
        if hasPromises { return .promises }
        var seen = Set<String>()
        let files = localURLs.filter { $0.isFileURL && seen.insert($0.standardizedFileURL.path).inserted }
        if files.count > maximumFiles { return .tooManyFiles }
        if !files.isEmpty { return .files(files) }
        return .unsupported
    }
}

struct PhotoDropError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Callback counts come from fileNames after calling in the promises, rather than
/// fileTypes (legacy sources may promise several files of the same type).
/// The lock also makes late/duplicate provider callbacks harmless.
final class PhotoPromiseBatch: @unchecked Sendable {
    private let lock = NSLock()
    private var expectedCount: Int?
    private let directory: URL
    private let receiptID: UUID?
    private var urls: [URL] = []
    private var seen = Set<String>()
    private var finished = false
    private var abandoned = false

    init(expectedCount: Int? = nil, directory: URL, receiptID: UUID? = nil) {
        self.expectedCount = expectedCount
        self.directory = directory.standardizedFileURL
        self.receiptID = receiptID
    }

    func seal(expectedCount: Int) -> Result<PhotoDropPayload, PhotoDropError>? {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return nil }
        guard expectedCount > 0, expectedCount <= PhotoDropPolicy.maximumFiles else {
            return failLocked("This drop contains too many files or no readable file promises.")
        }
        self.expectedCount = expectedCount
        return completeLocked()
    }

    func accept(_ url: URL, error: Error?) -> Result<PhotoDropPayload, PhotoDropError>? {
        lock.lock()
        guard !finished else {
            let needsCleanup = abandoned
            lock.unlock()
            // A cancelled/failed source may finish writing after the first cleanup.
            // Its callback only owns this batch's destination, never the supplied URL.
            // Successful payloads retain caller ownership until copying completes.
            if needsCleanup { try? FileManager.default.removeItem(at: directory) }
            return nil
        }
        defer { lock.unlock() }
        if let error { return failLocked("The photo source could not provide the dropped files: \(error.localizedDescription)") }
        let path = url.standardizedFileURL.path
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard url.isFileURL, path.hasPrefix(directory.path + "/"), resolvedPath.hasPrefix(resolvedDirectory + "/") else {
            return failLocked("The photo source returned a file outside the temporary import folder.")
        }
        guard seen.insert(path).inserted else { return failLocked("The photo source returned the same promised file more than once.") }
        urls.append(url)
        guard urls.count <= PhotoDropPolicy.maximumFiles else { return failLocked("This drop contains too many files.") }
        return completeLocked()
    }

    func fail(_ message: String) -> Result<PhotoDropPayload, PhotoDropError>? {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return nil }
        return failLocked(message)
    }

    func abandon() {
        lock.lock(); defer { lock.unlock() }
        finished = true
        abandoned = true
    }

    private func completeLocked() -> Result<PhotoDropPayload, PhotoDropError>? {
        guard let expectedCount, urls.count >= expectedCount else { return nil }
        guard urls.count == expectedCount else { return failLocked("The photo source returned an inconsistent file promise.") }
        finished = true
        return .success(PhotoDropPayload(urls: urls, ownedTemporaryDirectory: directory, receiptID: receiptID))
    }

    private func failLocked(_ message: String) -> Result<PhotoDropPayload, PhotoDropError> {
        finished = true
        abandoned = true
        return .failure(PhotoDropError(message: message))
    }
}

/// Wrapping the content leaves SwiftUI controls as the normal mouse/key targets.
/// A transparent overlay with hitTest == nil cannot reliably receive AppKit promises.
struct PhotoDropReceiver<Content: View>: NSViewRepresentable {
    var isEnabled: Bool
    var cancellationID: UUID
    var onFiles: @MainActor (PhotoDropPayload) -> Void
    var onFailure: @MainActor (String) -> Void
    var onTargeted: @MainActor (Bool) -> Void = { _ in }
    var onReceiving: @MainActor (UUID) -> Bool = { _ in true }
    var onReceiptEnded: @MainActor (UUID) -> Void = { _ in }
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> PhotoDropDestinationView {
        let view = PhotoDropDestinationView()
        let host = PhotoDropHostingView(rootView: content())
        host.destination = view
        host.registerForDraggedTypes(PhotoDropDestinationView.acceptedTypes)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor), host.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: PhotoDropDestinationView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.onFiles = onFiles; nsView.onFailure = onFailure; nsView.onTargeted = onTargeted
        nsView.onReceiving = onReceiving; nsView.onReceiptEnded = onReceiptEnded
        nsView.cancellationID = cancellationID
        (nsView.subviews.first as? NSHostingView<Content>)?.rootView = content()
    }

    static func dismantleNSView(_ nsView: PhotoDropDestinationView, coordinator: ()) {
        nsView.cancelPendingDrop()
    }
}

extension View {
    func photoDropDestination(isEnabled: Bool, cancellationID: UUID,
                              onFiles: @escaping @MainActor (PhotoDropPayload) -> Void,
                              onFailure: @escaping @MainActor (String) -> Void,
                              onTargeted: @escaping @MainActor (Bool) -> Void = { _ in },
                              onReceiving: @escaping @MainActor (UUID) -> Bool = { _ in true },
                              onReceiptEnded: @escaping @MainActor (UUID) -> Void = { _ in }) -> some View {
        PhotoDropReceiver(isEnabled: isEnabled, cancellationID: cancellationID, onFiles: onFiles,
                          onFailure: onFailure, onTargeted: onTargeted, onReceiving: onReceiving,
                          onReceiptEnded: onReceiptEnded) { self }
    }
}

@MainActor private final class PhotoDropHostingView<Content: View>: NSHostingView<Content> {
    weak var destination: PhotoDropDestinationView?
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { destination?.draggingEntered(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { destination?.draggingUpdated(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { destination?.draggingExited(sender) }
    override func draggingEnded(_ sender: NSDraggingInfo) { destination?.draggingEnded(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { destination?.prepareForDragOperation(sender) ?? false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { destination?.performDragOperation(sender) ?? false }
}

@MainActor final class PhotoDropDestinationView: NSView {
    var cleanupScheduler = PhotoDropCleanup.shared
    var isEnabled = true
    var cancellationID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")! {
        didSet { if cancellationID != oldValue { cancelPendingDrop() } }
    }
    var onReceiving: @MainActor (UUID) -> Bool = { _ in true }
    var onReceiptEnded: @MainActor (UUID) -> Void = { _ in }
    var onFiles: @MainActor (PhotoDropPayload) -> Void = { $0.cleanup() }
    var onFailure: @MainActor (String) -> Void = { _ in }
    var onTargeted: @MainActor (Bool) -> Void = { _ in }
    private var promiseBatch: PhotoPromiseBatch?
    private var receivers: [NSFilePromiseReceiver] = []
    private var promiseDirectory: URL?
    private var activeReceiptID: UUID?
    private var timeout: DispatchWorkItem?
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "OpenCull dropped photo delivery"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } + [.fileURL, .URL, .string]
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEnabled, promiseBatch == nil else { return [] }
        let kind = classification(sender.draggingPasteboard)
        switch kind {
        case .promises, .files:
            onTargeted(true)
            return .copy
        case .tooManyFiles, .unsupported:
            // Accept the drop gesture so unsupported website drops receive an explanation.
            onTargeted(true)
            return .copy
        }
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEnabled, promiseBatch == nil else { onTargeted(false); return [] }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onTargeted(false) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isEnabled && promiseBatch == nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted(false)
        guard isEnabled, promiseBatch == nil else { return false }
        let board = sender.draggingPasteboard
        switch classification(board) {
        case .files(let urls):
            onFiles(PhotoDropPayload(urls: urls, ownedTemporaryDirectory: nil))
            return true
        case .promises:
            let promises = (board.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
            guard !promises.isEmpty, promises.count <= PhotoDropPolicy.maximumFiles else {
                onFailure("This drop contains too many files or unreadable promises."); return false
            }
            return receive(promises)
        case .tooManyFiles:
            onFailure("Drop at most \(PhotoDropPolicy.maximumFiles) files at a time. For larger sets, import a folder or ZIP archive.")
            return false
        case .unsupported:
            onFailure(PhotoDropPolicy.downloadInstruction)
            return false
        }
    }

    func cancelPendingDrop() {
        guard let batch = promiseBatch else { return }
        // A successful provider callback may already be queued on the main actor.
        // Cancellation must invalidate the reservation even if the batch is sealed.
        batch.abandon()
        finish(.failure(PhotoDropError(message: "The dropped photo import was cancelled.")), for: batch, reportFailure: false)
    }

    private func classification(_ board: NSPasteboard) -> PhotoDropClassification {
        let hasPromises = board.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
        let urls = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return PhotoDropPolicy.classify(hasPromises: hasPromises, localURLs: urls,
                                        hasRemoteRepresentation: board.availableType(from: [.URL, .string]) != nil)
    }

    /// Reserves the model's import intent before any source starts writing files.
    /// This also keeps cancellation ownership separate from the provider's callbacks.
    func beginReceiving(in directory: URL) -> PhotoPromiseBatch? {
        guard isEnabled, promiseBatch == nil else { return nil }
        let receiptID = UUID()
        guard onReceiving(receiptID) else { return nil }
        var createdDirectory = false
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            createdDirectory = true
            try ImportScratchRecovery.mark(directory)
        } catch {
            if createdDirectory { try? FileManager.default.removeItem(at: directory) }
            onReceiptEnded(receiptID)
            onFailure("Could not create a temporary photo import folder: \(error.localizedDescription)")
            return nil
        }
        let batch = PhotoPromiseBatch(directory: directory, receiptID: receiptID)
        promiseBatch = batch; promiseDirectory = directory; activeReceiptID = receiptID
        return batch
    }

    private func receive(_ promises: [NSFilePromiseReceiver]) -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-Drop-\(UUID().uuidString)", isDirectory: true)
        guard let batch = beginReceiving(in: directory) else { return false }
        receivers = promises
        for receiver in promises {
            receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: promiseQueue) { [weak self] url, error in
                guard let result = batch.accept(url, error: error) else { return }
                Task { @MainActor [weak self] in self?.finish(result, for: batch) }
            }
        }
        let filenameCounts = promises.map { $0.fileNames.count }
        if filenameCounts.contains(0) {
            if let result = batch.fail("The photo source did not describe its promised files. Download the photos and import the local files instead.") { finish(result, for: batch) }
        } else if let result = batch.seal(expectedCount: filenameCounts.reduce(0, +)) { finish(result, for: batch) }
        if promiseBatch != nil {
            let timeout = DispatchWorkItem { [weak self] in
                guard let result = batch.fail("The photo source did not finish providing the dropped files. Download the photos and import the local files instead.") else { return }
                self?.finish(result, for: batch)
            }
            self.timeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: timeout)
        }
        return true
    }

    func finish(_ result: Result<PhotoDropPayload, PhotoDropError>, for batch: PhotoPromiseBatch, reportFailure: Bool = true) {
        guard promiseBatch === batch else {
            if case .success(let payload) = result, let directory = payload.ownedTemporaryDirectory { cleanupScheduler.schedule(directory) }
            return
        }
        let directory = promiseDirectory, receiptID = activeReceiptID
        timeout?.cancel(); timeout = nil
        promiseBatch = nil; promiseDirectory = nil; activeReceiptID = nil; receivers = []
        onTargeted(false)
        switch result {
        case .success(let payload): onFiles(payload)
        case .failure(let error):
            if let directory { cleanupScheduler.schedule(directory) }
            if let receiptID { onReceiptEnded(receiptID) }
            if reportFailure { onFailure(error.localizedDescription) }
        }
    }
}
