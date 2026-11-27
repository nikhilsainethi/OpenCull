import CullCore
import SwiftUI

struct SettingsView: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Grouping similar shots") {
                LabeledSlider(title: "Max time between shots", value: $model.grouping.maxTimeGap, range: 0.5...15, step: 0.5,
                              format: { String(format: "%.1f s", $0) })
                LabeledSlider(title: "Similarity required", value: floatBinding($model.grouping.minSimilarity), range: 0.5...0.98, step: 0.01,
                              format: { String(format: "%.2f", $0) })
                LabeledSlider(title: "Similarity without timestamps", value: floatBinding($model.grouping.minSimilarityWithoutTime),
                              range: 0.5...0.99, step: 0.01, format: { String(format: "%.2f", $0) })
            }
            Section("Problem detection") {
                LabeledSlider(title: "Eyes closed below", value: floatBinding($model.scoring.eyesClosedThreshold), range: 0.05...0.3, step: 0.01,
                              format: { String(format: "%.2f", $0) })
                LabeledSlider(title: "Blurry below (absolute)", value: floatBinding($model.scoring.blurAbsoluteThreshold), range: 5...400, step: 5,
                              format: { String(format: "%.0f", $0) })
                LabeledSlider(title: "Blurry below (% of group's sharpest)", value: floatBinding($model.scoring.blurRelativeThreshold),
                              range: 0.1...0.9, step: 0.05, format: { String(format: "%.0f%%", $0 * 100) })
                Toggle("Suggest rejecting all but the best shot of each group", isOn: $model.scoring.rejectNonBestInGroup)
            }
            Section("Culling") {
                Toggle("Move to the next photo after Pick or Reject", isOn: $model.autoAdvance)
            }
            HStack {
                Spacer()
                Button("Restore Defaults") { model.resetOptions() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func floatBinding(_ binding: Binding<Float>) -> Binding<Double> {
        Binding(get: { Double(binding.wrappedValue) }, set: { binding.wrappedValue = Float($0) })
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step).frame(width: 180)
                Text(format(value)).monospacedDigit().frame(width: 56, alignment: .trailing)
            }
        }
    }
}
