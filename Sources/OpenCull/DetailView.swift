import CullCore
import SwiftUI

struct DetailView: View {
    @Environment(LibraryModel.self) private var model
    let reviewBurst: (String) -> Void

    var body: some View {
        if let item = model.selectedItem {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    ZoomablePhotoView(item: item, recipe: model.showOriginal ? .identity : model.recipe(for: item),
                                      zoom: model.zoom, showFaceBoxes: model.showFaceBoxes, keyFace: model.keyFace(for: item))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ScrollView {
                    InfoPanel(item: item, groupMaxSharpness: model.groupMaxSharpness(for: item), reviewBurst: reviewBurst)
                        .padding(14)
                }
                .frame(height: 250)
            }
        } else {
            ContentUnavailableView("No photo selected", systemImage: "photo")
        }
    }
}

private struct InfoPanel: View {
    @Environment(LibraryModel.self) private var model
    let item: PhotoItem
    let groupMaxSharpness: Float?
    let reviewBurst: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.fileName).font(.headline).textSelection(.enabled)
                    if !item.companions.isEmpty {
                        Text("+ " + item.companions.map(\.lastPathComponent).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                decisionButtons
            }

            if let source = model.provenance(for: item) {
                Text("\(source.source.title) · \(source.originalFileName)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let quality = source.representationQuality { Text(quality).font(.caption2).foregroundStyle(.secondary) }
            }
            HStack {
                ratingControl
                Spacer()
                suggestionText
                if model.burstRecommendation(for: item.id) != nil {
                    Button("Best available…") { reviewBurst(item.id) }
                        .help("Compare the leading shots and inspect their faces")
                }
            }

            if let error = item.analysisError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if let analysis = item.analysis {
                metrics(analysis)
                if !item.reviewReasons.isEmpty {
                    Label(item.reviewReasons.joined(separator: " · "), systemImage: "questionmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !analysis.faces.isEmpty {
                    DisclosureGroup("People · \(analysis.faces.count) detected") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(analysis.faces.enumerated()), id: \.offset) { index, face in
                                let assessment = PeopleAssessment.assess(face, intent: model.scoring.shootingIntent,
                                    eyesClosedThreshold: model.scoring.eyesClosedThreshold)
                                Text("Face \(index + 1): \(assessment.summary)")
                                    .font(.caption).textSelection(.enabled)
                                Text(assessment.eyeConfidenceDescription + " · " + assessment.attentionConfidenceDescription)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if analysis.faces.count > 1 {
                    HStack {
                        Text("Focus subject").foregroundStyle(.secondary)
                        Menu {
                            Button("Automatic (all significant faces)") { model.setKeyFace(nil) }
                            ForEach(analysis.faces.indices, id: \.self) { index in
                                Button("Face \(index + 1)") { model.setKeyFace(index) }
                            }
                        } label: { Text(model.keyFace(for: item).map { "Face \($0 + 1)" } ?? "Automatic") }
                    }
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Analyzing…").foregroundStyle(.secondary) }
            }
        }
    }

    private var decisionButtons: some View {
        HStack(spacing: 6) {
            Button { model.setDecision(.pick) } label: { Label("Pick", systemImage: "checkmark") }
                .tint(item.decision == .pick ? .green : nil)
                .help("Pick (P)")
            Button { model.setDecision(.reject) } label: { Label("Reject", systemImage: "xmark") }
                .tint(item.decision == .reject ? .red : nil)
                .help("Reject (X)")
            Button { model.setDecision(.undecided) } label: { Label("Clear", systemImage: "circle.dashed") }
                .help("Clear decision (U)")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .focusable(false)
    }

    private var ratingControl: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    model.setRating(star == item.rating ? 0 : star)
                } label: {
                    Image(systemName: star <= item.rating ? "star.fill" : "star")
                        .foregroundStyle(star <= item.rating ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("\(star) star\(star == 1 ? "" : "s") (\(star))")
            }
        }
        .font(.title3)
    }

    @ViewBuilder
    private var suggestionText: some View {
        switch item.suggestion {
        case .pick:
            Label(item.isBestInGroup && model.burstRecommendation(for: item.id) == nil ? "Suggested pick · best of \(item.groupSize)" : "Suggested pick", systemImage: "wand.and.stars")
                .foregroundStyle(.green)
        case .reject:
            Label("Suggested reject", systemImage: "wand.and.stars").foregroundStyle(.red)
        case .undecided:
            EmptyView()
        }
    }

    private func metrics(_ a: PhotoAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !item.issues.isEmpty {
                HStack(spacing: 12) {
                    ForEach(item.issues, id: \.self) { issue in
                        Label(issue.label, systemImage: issue.symbolName).foregroundStyle(.orange)
                    }
                }
                .font(.callout)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    metric("Score", item.score.map { String(format: "%.0f / 100", $0) } ?? "–")
                    metric("Sharpness", sharpnessText(a))
                }
                GridRow {
                    metric("Faces", facesText(a))
                    metric("Eyes", eyesText(a))
                }
                GridRow {
                    metric("Aesthetics", a.aestheticScore.map { String(format: "%+.2f", $0) } ?? "needs macOS 15")
                    metric("Exposure", String(format: "brightness %.0f%% · clipped %.1f%% white, %.1f%% black",
                                              a.meanLuminance * 100, a.highlightClipping * 100, a.shadowClipping * 100))
                }
                GridRow {
                    metric("Size", "\(a.pixelWidth) × \(a.pixelHeight)")
                    metric("Captured", a.captureDate.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "unknown")
                }
            }
            .font(.callout)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }

    private func sharpnessText(_ a: PhotoAnalysis) -> String {
        var text = String(format: "%.0f", a.subjectSharpness)
        if a.significantFaces.isEmpty == false { text += " (face)" }
        if let max = groupMaxSharpness, max > 0 {
            text += String(format: " · %.0f%% of group's sharpest", a.subjectSharpness / max * 100)
        }
        return text
    }

    private func facesText(_ a: PhotoAnalysis) -> String {
        guard !a.faces.isEmpty else { return "none" }
        let qualities = a.significantFaces.compactMap(\.captureQuality)
        let quality = qualities.isEmpty ? "" : String(format: " · quality %.2f", qualities.reduce(0, +) / Float(qualities.count))
        return "\(a.faces.count) (\(a.significantFaces.count) large enough to check)\(quality)"
    }

    private func eyesText(_ a: PhotoAnalysis) -> String {
        let faces = a.significantFaces
        guard !faces.isEmpty else { return a.faces.isEmpty ? "no faces" : "faces too small" }
        let assessments = PeopleAssessment.assessments(for: a, options: model.scoring)
        return assessments.map(\.eyeDescription).joined(separator: "; ")
    }
}
