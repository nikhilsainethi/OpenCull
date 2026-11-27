import CullCore
import SwiftUI

struct DetailView: View {
    @Environment(LibraryModel.self) private var model

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
                    InfoPanel(item: item, groupMaxSharpness: model.groupMaxSharpness(for: item))
                        .padding(14)
                }
                .frame(height: 250)
            }
        } else {
            ContentUnavailableView("No photo selected", systemImage: "photo")
        }
    }
}

/// Draws detected faces: green when eyes are open, red when closed, grey when unknown or too small.
private struct FaceBoxesOverlay: View {
    let analysis: PhotoAnalysis
    let threshold: Float

    var body: some View {
        GeometryReader { geometry in
            let aspect = CGFloat(max(1, analysis.pixelWidth)) / CGFloat(max(1, analysis.pixelHeight))
            let container = geometry.size
            let fitted: CGSize = container.width / container.height > aspect
                ? CGSize(width: container.height * aspect, height: container.height)
                : CGSize(width: container.width, height: container.width / aspect)
            let origin = CGPoint(x: (container.width - fitted.width) / 2, y: (container.height - fitted.height) / 2)

            ForEach(Array(analysis.faces.enumerated()), id: \.offset) { _, face in
                let rect = CGRect(x: origin.x + face.boundingBox.minX * fitted.width,
                                  y: origin.y + face.boundingBox.minY * fitted.height,
                                  width: face.boundingBox.width * fitted.width,
                                  height: face.boundingBox.height * fitted.height)
                Rectangle()
                    .stroke(color(for: face), lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .allowsHitTesting(false)
    }

    private func color(for face: FaceInfo) -> Color {
        guard face.isSignificant, let openness = face.eyeOpenness else { return .gray }
        return openness < threshold ? .red : .green
    }
}

private struct InfoPanel: View {
    @Environment(LibraryModel.self) private var model
    let item: PhotoItem
    let groupMaxSharpness: Float?

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

            HStack {
                ratingControl
                Spacer()
                suggestionText
            }

            if let error = item.analysisError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if let analysis = item.analysis {
                metrics(analysis)
                if !item.reviewReasons.isEmpty {
                    Label(item.reviewReasons.joined(separator: " · "), systemImage: "questionmark.circle")
                        .font(.caption).foregroundStyle(.orange)
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
            Label(item.isBestInGroup ? "Suggested pick · best of \(item.groupSize)" : "Suggested pick", systemImage: "wand.and.stars")
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
        let values = a.significantFaces.compactMap(\.eyeOpenness)
        guard !values.isEmpty else { return "–" }
        let closed = values.filter { $0 < model.scoring.eyesClosedThreshold }.count
        let list = values.map { String(format: "%.2f", $0) }.joined(separator: ", ")
        return closed == 0 ? "open (\(list))" : "\(closed) closed (\(list))"
    }
}
