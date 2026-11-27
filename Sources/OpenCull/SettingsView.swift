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
                Toggle("Rescue blurred burst frames using layout", isOn: $model.grouping.allowLayoutFallback)
                LabeledSlider(title: "Layout similarity required", value: floatBinding($model.grouping.minLayoutSimilarity), range: 0.8...0.999, step: 0.005,
                              format: { String(format: "%.3f", $0) })
                LabeledSlider(title: "Layout without timestamps", value: floatBinding($model.grouping.minLayoutSimilarityWithoutTime), range: 0.8...0.999, step: 0.005,
                              format: { String(format: "%.3f", $0) })
                LabeledSlider(title: "Semantic floor for layout rescue", value: floatBinding($model.grouping.minimumSemanticForLayout), range: 0.3...0.95, step: 0.01,
                              format: { String(format: "%.2f", $0) })
            }
            Section("Shooting intent") {
                Picker("Photographs", selection: $model.scoring.shootingIntent) {
                    ForEach(ShootingIntent.allCases) { Text($0.title).tag($0) }
                }
                Text(model.scoring.shootingIntent.help).font(.caption).foregroundStyle(.secondary)
                Text("Eye and camera-attention checks are estimates. Review uncertain faces, profiles, occlusions and intentional expressions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Problem detection") {
                LabeledSlider(title: "Eyes closed below", value: floatBinding($model.scoring.eyesClosedThreshold), range: 0.05...0.3, step: 0.01,
                              format: { String(format: "%.2f", $0) })
                LabeledSlider(title: "Blurry below (absolute)", value: floatBinding($model.scoring.blurAbsoluteThreshold), range: 5...400, step: 5,
                              format: { String(format: "%.0f", $0) })
                LabeledSlider(title: "Blurry below (% of group's sharpest)", value: floatBinding($model.scoring.blurRelativeThreshold),
                              range: 0.1...0.9, step: 0.05, format: { String(format: "%.0f%%", $0 * 100) })
                Toggle("Suggest rejecting all but the best shot of each group", isOn: $model.scoring.rejectNonBestInGroup)
                Toggle("Suggest rejecting exposure problems", isOn: $model.scoring.rejectExposureProblems)
                LabeledSlider(title: "Overexposed: white clipping", value: floatBinding($model.scoring.overexposedClipping), range: 0.01...0.8, step: 0.01,
                              format: { String(format: "%.0f%%", $0 * 100) })
                LabeledSlider(title: "Overexposed: mean brightness", value: floatBinding($model.scoring.overexposedMean), range: 0.5...0.99, step: 0.01,
                              format: { String(format: "%.0f%%", $0 * 100) })
                LabeledSlider(title: "Underexposed: mean brightness", value: floatBinding($model.scoring.underexposedMean), range: 0.01...0.4, step: 0.01,
                              format: { String(format: "%.0f%%", $0 * 100) })
                LabeledSlider(title: "Underexposed: black clipping", value: floatBinding($model.scoring.underexposedClipping), range: 0.05...0.95, step: 0.01,
                              format: { String(format: "%.0f%%", $0 * 100) })
            }
            Section("Culling") {
                Toggle("Move to the next photo after Pick or Reject", isOn: $model.autoAdvance)
                Toggle("Include subfolders when opening an album", isOn: $model.recursive)
            }
            Section("Personal ranking") {
                Toggle("Adapt ranking from my explicit choices", isOn: $model.usePreferences)
                Text("\(model.preference.sampleCount) local examples. \(model.preference.isReady ? "Personal ranking is ready." : "More picks and rejects are needed before rankings change.")")
                    .font(.caption).foregroundStyle(.secondary)
                Text("This small local preference model adjusts ranking, while technical checks and your choices stay in control.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset learned preferences", role: .destructive) { model.resetPreference() }
            }
            HStack {
                Spacer()
                Button("Restore Defaults") { model.resetOptions() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 760)
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
