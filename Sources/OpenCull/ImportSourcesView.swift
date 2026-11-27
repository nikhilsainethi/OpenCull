import AppKit
import CullCore
import PhotosUI
import SwiftUI

struct ImportSourcesView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var photoSelection: [PhotosPickerItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Bring your photos to OpenCull").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Import copies into a local album, then cull, compare and edit on your Mac. Your source photos stay untouched.")
                .foregroundStyle(.secondary)
            GroupBox {
                sourceRow("Files, folders and ZIP archives", symbol: "folder") {
                    Text("Keeps filenames, folder structure, RAW + JPEG pairs and sidecars.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Choose files or archives…") { dismiss(); model.showImportPanel() }
                }
            }
            GroupBox {
                sourceRow("Apple Photos", symbol: "photo.on.rectangle") {
                    Text("Select from the system picker, or drag photos from Photos into OpenCull. The supplied representation may be edited or converted; its quality is shown as unverified.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    PhotosPicker(selection: $photoSelection, maxSelectionCount: 5_000, matching: .images, preferredItemEncoding: .current) {
                        Text("Choose from Apple Photos…")
                    }
                }
            }
            GroupBox {
                sourceRow("Google Photos", symbol: "globe") {
                    Text("Open Google Photos, select photos and use Download. Then import the downloaded files or ZIP. For a large library, import Google Takeout ZIPs or an extracted Takeout folder.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open Google Photos ↗") { NSWorkspace.shared.open(URL(string: "https://photos.google.com/")!) }
                        Button("Import downloads…") { dismiss(); model.showImportPanel(source: .googlePhotos) }
                        Button("Import Takeout…") { dismiss(); model.showImportPanel(source: .takeout) }
                    }
                    Text("Web links and thumbnails do not give OpenCull access to your library. Downloads require internet; analysis stays local. Decisions and edits are exported as files.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("You can also drop local photos, folders or ZIP files onto the app.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24).frame(width: 680)
        .onChange(of: photoSelection) { _, selected in if !selected.isEmpty { dismiss() } }
    }

    private func sourceRow<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).frame(width: 32).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 10) { Text(title).font(.headline); content() }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
    }
}
