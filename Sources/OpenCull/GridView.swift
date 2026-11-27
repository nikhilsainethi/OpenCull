import AppKit
import CullCore
import SwiftUI

struct GridView: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 10)],
                          spacing: 10, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                PhotoCell(item: item, isSelected: model.selection.contains(item.id) || item.id == model.selectedID)
                                    .id(item.id)
                                    .onTapGesture { model.select(item.id, extending: !NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty) }
                                    .contextMenu {
                                        Button("Edit photo") { model.select(item.id); model.mode = .edit }
                                        Button("Compare this group") { model.select(item.id); model.mode = .compare; model.prepareComparison() }
                                        Divider()
                                        Button("Pick") { model.select(item.id); model.setDecision(.pick) }
                                        Button("Reject") { model.select(item.id); model.setDecision(.reject) }
                                    }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel(item.fileName)
                            }
                        } header: {
                            if let title = section.title {
                                SectionHeader(title: title)
                            }
                        }
                    }
                }
                .padding(12)
                // Photos move between groups when results arrive; rebuilding the grid then
                // guarantees every cell shows the latest analysis.
            }
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
            .overlay {
                if model.visibleItems.isEmpty {
                    ContentUnavailableView("No photos", systemImage: "photo.on.rectangle",
                                           description: Text("No photos match the “\(model.filter.title)” filter."))
                }
            }
        }
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Image(systemName: "square.stack.3d.up")
            Text(title).font(.headline)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct PhotoCell: View {
    @Environment(LibraryModel.self) private var model
    let item: PhotoItem
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            PhotoImageView(item: item, size: 360, recipe: model.recipe(for: item))
                .frame(height: 130)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .opacity(item.decision == .reject ? 0.4 : 1)
                .overlay(alignment: .topLeading) { DecisionBadge(item: item).padding(4) }
                .overlay(alignment: .topTrailing) {
                    if item.isBestInGroup {
                        Label("Best", systemImage: "crown.fill")
                            .labelStyle(.iconOnly)
                            .font(.caption)
                            .padding(4)
                            .background(.yellow, in: Circle())
                            .foregroundStyle(.black)
                            .padding(4)
                            .help("Best shot of this group")
                    }
                }

            HStack(spacing: 4) {
                Text(item.fileName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                if item.analysis == nil && item.analysisError == nil {
                    ProgressView().controlSize(.mini)
                }
                if item.analysisError != nil {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(item.analysisError ?? "")
                }
                if item.needsReview {
                    Image(systemName: "questionmark.circle").foregroundStyle(.yellow).help(item.reviewReasons.joined(separator: "\n"))
                }
                ForEach(item.issues.filter { $0 != .duplicate }, id: \.self) { issue in
                    Image(systemName: issue.symbolName)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(issue.label)
                }
            }
            StarsView(rating: item.rating).font(.caption2)
        }
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.35) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}

/// Filled icon = the user's decision. Outlined icon = the analyzer's suggestion.
struct DecisionBadge: View {
    let item: PhotoItem

    var body: some View {
        switch item.decision {
        case .pick:
            badge("checkmark.circle.fill", .green, "Picked")
        case .reject:
            badge("xmark.circle.fill", .red, "Rejected")
        case .undecided:
            switch item.suggestion {
            case .pick: badge("checkmark.circle", .green, "Suggested pick")
            case .reject: badge("xmark.circle", .red, "Suggested reject")
            case .undecided: EmptyView()
            }
        }
    }

    private func badge(_ symbol: String, _ color: Color, _ help: String) -> some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(color)
            .background(Circle().fill(.black.opacity(0.55)).padding(1))
            .help(help)
    }
}

struct StarsView: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .foregroundStyle(star <= rating ? Color.yellow : Color.secondary.opacity(0.4))
            }
        }
    }
}
