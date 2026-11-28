import CullCore
import SwiftUI

struct BurstReviewRequest: Identifiable {
    let id: String
}

struct BurstComparisonSheet: View {
    nonisolated static let initialZoom: ZoomMode = .face
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let anchorID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Best available").font(.title.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let comparison = model.burstRecommendation(for: anchorID),
               let winner = model.item(withID: comparison.winnerID),
               let runner = model.item(withID: comparison.runnerUpID) {
                ScrollView {
                    BurstComparison(comparison: comparison, winner: winner, runner: runner) {
                        model.pickBurstPhoto($0, from: anchorID)
                    }
                    .id([winner.id, runner.id])
                }
            } else {
                ContentUnavailableView("Comparison unavailable", systemImage: "rectangle.split.2x1",
                    description: Text("Open a completed burst with two comparable frames in Posed group."))
            }
        }
        .padding(20)
        .frame(width: 780, height: 550)
    }

    /// Indices come from independent Vision detections in each original. An absent
    /// or unusable box must never silently center on some other person's face.
    nonisolated static func face(at index: Int?, in faces: [FaceInfo]) -> FaceInfo? {
        guard let index, faces.indices.contains(index) else { return nil }
        let face = faces[index]
        let box = face.boundingBox
        guard box.origin.x.isFinite, box.origin.y.isFinite, box.size.width.isFinite, box.size.height.isFinite,
              box.size.width > 0, box.size.height > 0, box.minX >= 0, box.minY >= 0,
              box.maxX <= 1.0001, box.maxY <= 1.0001 else { return nil }
        return face
    }
}

private struct BurstComparison: View {
    let comparison: BurstRecommendation
    let winner: PhotoItem
    let runner: PhotoItem
    let pick: (String) -> Void
    @State private var pairIndex = 0
    @State private var zoom = BurstComparisonSheet.initialZoom

    private var pair: BurstFacePair? {
        comparison.pairs.indices.contains(pairIndex) ? comparison.pairs[pairIndex] : comparison.pairs.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if comparison.isCloseCall {
                Label("Close call · compare both shots", systemImage: "equal.circle")
                    .font(.headline).foregroundStyle(.secondary)
            }
            Text(comparison.reason).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if pair != nil {
                HStack {
                    Picker("Face", selection: $pairIndex) {
                        ForEach(comparison.pairs.indices, id: \.self) { index in
                            Text(comparison.pairs[index].label).tag(index)
                        }
                    }
                    .disabled(zoom == .fit)
                    Spacer()
                    Picker("View", selection: $zoom) {
                        Text("Face detail").tag(ZoomMode.face)
                        Text("100%").tag(ZoomMode.actual)
                        Text("Whole photos").tag(ZoomMode.fit)
                    }.pickerStyle(.segmented).fixedSize()
                }
            } else {
                Text("Face correspondence is uncertain. Compare the whole photos.").foregroundStyle(.secondary)
            }
            Divider()
            HStack(alignment: .top, spacing: 16) {
                BurstFrameColumn(item: winner, title: comparison.isCloseCall ? "First to review" : "Recommended",
                    summary: comparison.winnerSummary, faceIndex: pair?.winnerFaceIndex,
                    zoom: pair == nil ? .fit : zoom, pick: pick)
                BurstFrameColumn(item: runner, title: "Runner-up", summary: comparison.runnerUpSummary,
                    faceIndex: pair?.runnerUpFaceIndex, zoom: pair == nil ? .fit : zoom, pick: pick)
            }
        }
    }
}

private struct BurstFrameColumn: View {
    @Environment(LibraryModel.self) private var model
    let item: PhotoItem
    let title: String
    let summary: String
    let faceIndex: Int?
    let zoom: ZoomMode
    let pick: (String) -> Void

    var body: some View {
        let face = BurstComparisonSheet.face(at: faceIndex, in: item.analysis?.faces ?? [])
        let inspectFace = zoom != .fit && face != nil
        let viewLabel = inspectFace ? (zoom == .actual ? "face at 100 percent" : "face detail") : "whole photo"
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if let number = model.burstShotNumber(for: item.id) {
                    Text("Shot \(number) of \(item.groupSize)").font(.subheadline.monospacedDigit())
                }
            }
            Text(item.fileName).font(.caption).lineLimit(1).truncationMode(.middle).help(item.fileName)
            ZoomablePhotoView(item: item, recipe: .identity, zoom: inspectFace ? zoom : .fit,
                              keyFace: inspectFace ? faceIndex : nil, centerAtActualSize: inspectFace && zoom == .actual, inspectingBurst: true)
                .frame(height: 230)
                .accessibilityLabel("\(title), \(item.fileName), \(viewLabel)")
                .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 4) {
                if inspectFace, let face {
                    let evidence = PeopleAssessment.assess(face, intent: .groupPortrait, eyesClosedThreshold: model.scoring.eyesClosedThreshold)
                    Text(face.leftEyeOpenness == nil && face.rightEyeOpenness == nil && face.eyeOpenness != nil
                         ? "Individual eye states unavailable" : evidence.eyeDescription).font(.subheadline.weight(.medium))
                    Text(evidence.attentionDescription).font(.caption).foregroundStyle(.secondary)
                } else if zoom != .fit {
                    Label("No reliable face match · showing whole photo", systemImage: "questionmark.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    pick(item.id)
                } label: {
                    Label(item.decision == .pick ? "Picked" : "Pick this shot",
                          systemImage: item.decision == .pick ? "checkmark.circle.fill" : "checkmark")
                }
                .disabled(item.decision == .pick)
                .accessibilityLabel(item.decision == .pick ? "\(item.fileName) is picked" : "Pick \(item.fileName)")
                if item.decision == .reject {
                    Text("Currently rejected").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
