import CullCore
import SwiftUI

struct ExportSheet: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var format: ImageExportFormat = .jpeg
    @State private var quality = 0.92
    @State private var size = 0
    @State private var allPicks = true
    @State private var stripMetadata = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export photographs").font(.title2.weight(.semibold))
            Text("Edits are rendered into new files. Your originals stay untouched.").foregroundStyle(.secondary)
            Form {
                Picker("Photos", selection: $allPicks) {
                    Text("All picks (\(model.counts.picks))").tag(true)
                    Text("Selected (\(model.selectedItems.count))").tag(false)
                }
                Picker("Format", selection: $format) {
                    Text("JPEG").tag(ImageExportFormat.jpeg)
                    Text("PNG").tag(ImageExportFormat.png)
                    Text("TIFF").tag(ImageExportFormat.tiff)
                }
                if format == .jpeg { LabeledContent("Quality") { Slider(value: $quality, in: 0.5...1); Text("\(Int(quality * 100))%") } }
                Picker("Long edge", selection: $size) {
                    Text("Full resolution").tag(0); Text("4096 pixels").tag(4096); Text("2048 pixels").tag(2048); Text("1080 pixels").tag(1080)
                }
                Toggle("Remove camera, location and descriptive metadata", isOn: $stripMetadata)
            }.formStyle(.grouped)
            HStack {
                Menu("Originals & metadata") {
                    Button("Copy picked originals with current ratings…") { dismiss(); model.copyPicks() }
                    Button("Synchronize XMP beside originals") { dismiss(); model.writeSidecars() }.disabled(model.isAnalyzing)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose folder & export…") {
                    guard let destination = model.chooseDestination(message: "Choose a folder for rendered copies") else { return }
                    dismiss()
                    model.exportEdited(to: destination, format: format, quality: quality, maxPixelSize: size == 0 ? nil : size,
                                       metadata: stripMetadata ? .remove : .preserve, allPicks: allPicks)
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(allPicks ? model.counts.picks == 0 : model.selectedItems.isEmpty)
            }
        }.padding(24).frame(width: 570)
        .onAppear { if model.counts.picks == 0 { allPicks = false } }
    }
}
