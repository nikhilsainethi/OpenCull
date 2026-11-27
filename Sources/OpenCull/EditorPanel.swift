import CullCore
import SwiftUI

/// Native controls edit a persisted recipe; preview and export use the same
/// Core Image renderer. Sliders coalesce into one undoable adjustment gesture.
struct EditorPanel: View {
    @Environment(LibraryModel.self) private var model
    @State private var histogram: ImageHistogram?
    @State private var histogramKey: String?
    @State private var showingSaveStyle = false
    @State private var styleName = ""
    @State private var toneExpanded = true
    @State private var colorExpanded = true
    @State private var detailExpanded = false
    @State private var cropExpanded = false

    private var histogramRecipe: EditRecipe { model.showOriginal ? .identity : model.selectedRecipe }
    private var renderKey: String { model.selectedItem.map { PreviewCache.versionKey(for: $0, size: 1000, recipe: histogramRecipe) } ?? "none" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                title
                if model.selectedItem != nil {
                    histogramView
                    quickActions
                    presets
                    Divider()
                    DisclosureGroup("Light", isExpanded: $toneExpanded) { toneControls.padding(.top, 8) }
                    Divider()
                    DisclosureGroup("Color", isExpanded: $colorExpanded) { colorControls.padding(.top, 8) }
                    Divider()
                    DisclosureGroup("Detail", isExpanded: $detailExpanded) { detailControls.padding(.top, 8) }
                    Divider()
                    DisclosureGroup("Crop & Rotate", isExpanded: $cropExpanded) { cropControls.padding(.top, 8) }
                    Divider()
                    batchControls
                    Text("Adjustments are saved separately. Your original photo stays intact.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("Select a photo", systemImage: "slider.horizontal.3")
                }
            }
            .padding(16)
        }
        .frame(minWidth: 270, idealWidth: 300, maxWidth: 340)
        .background(.background)
        .task(id: renderKey) {
            let key = renderKey
            guard let item = model.selectedItem else { histogram = nil; histogramKey = nil; return }
            let result = await PreviewCache.shared.result(for: item, size: 1000, recipe: histogramRecipe)
            guard !Task.isCancelled else { return }
            if case .image(let image) = result {
                let computed = await Task.detached(priority: .utility) { PhotoEditor.histogram(image: image) }.value
                guard !Task.isCancelled else { return }
                histogram = computed
            } else { histogram = nil }
            histogramKey = key
        }
        .alert("Save local style", isPresented: $showingSaveStyle) {
            TextField("Style name", text: $styleName)
            Button("Save") { model.saveStyle(name: styleName) }.disabled(styleName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: { Text("Save the current adjustments as a reusable style on this Mac.") }
    }

    private var title: some View {
        HStack {
            Label("Develop", systemImage: "slider.horizontal.3").font(.headline)
            Spacer()
            Button("Reset") { model.setRecipe(.identity, name: "Reset edits") }
                .disabled(model.selectedRecipe.isIdentity || model.selectedItem == nil)
                .help("Restore the original appearance; Undo restores your edits")
        }
    }

    private var histogramView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(model.showOriginal ? "Histogram · Original" : "Histogram"); Spacer(); Text("sRGB").foregroundStyle(.secondary) }.font(.caption)
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.9))
                if let histogram, histogramKey == renderKey { HistogramPlot(histogram: histogram).padding(6) }
                else { Text("Updating preview…").font(.caption2).foregroundStyle(.white.opacity(0.7)) }
            }
            .frame(height: 74)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("RGB image histogram")
        }
    }

    private var quickActions: some View {
        HStack {
            Button { model.autoAdjust() } label: { Label("Auto Tone", systemImage: "wand.and.stars") }
                .help("Choose a tonal starting point from the photo's brightness histogram")
            Spacer()
            Button { model.showOriginal.toggle() } label: {
                Label(model.showOriginal ? "Original" : "Before", systemImage: "circle.lefthalf.filled")
            }
            .tint(model.showOriginal ? .orange : nil)
            .help("Toggle the original appearance without changing the saved edits")
        }
        .controlSize(.small)
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu("Presets") { ForEach(EditingPreset.allCases) { preset in Button(preset.title) { model.applyPreset(preset) } } }
                Menu("Saved Styles") {
                    if model.styles.isEmpty { Text("No saved styles yet") }
                    ForEach(model.styles) { style in
                        Menu(style.name) {
                            Button("Apply") { model.applyStyle(style) }
                            Button("Delete Style", role: .destructive) { model.deleteStyle(style.id) }
                        }
                    }
                }
            }
            Button { styleName = ""; showingSaveStyle = true } label: { Label("Save Current Style…", systemImage: "plus.circle") }
                .buttonStyle(.link).font(.caption)
        }
    }

    private var toneControls: some View {
        VStack(spacing: 12) {
            adjustment("Exposure", key: \.exposure, range: -5...5, step: 0.05, suffix: "EV")
            adjustment("Contrast", key: \.contrast, range: 0.5...2, step: 0.02)
            adjustment("Highlights", key: \.highlights, range: 0...1, step: 0.01)
            adjustment("Shadows", key: \.shadows, range: 0...1, step: 0.01)
        }
    }
    private var colorControls: some View {
        VStack(spacing: 12) {
            adjustment("Temperature", key: \.temperature, range: 2000...12000, step: 100, decimals: 0, suffix: "K")
            adjustment("Tint", key: \.tint, range: -150...150, step: 1, decimals: 0)
            adjustment("Saturation", key: \.saturation, range: 0...2, step: 0.02)
            adjustment("Vibrance", key: \.vibrance, range: -1...1, step: 0.02)
        }
    }
    private var detailControls: some View {
        VStack(spacing: 12) {
            adjustment("Sharpness", key: \.sharpness, range: 0...2, step: 0.05)
            adjustment("Noise Reduction", key: \.noiseReduction, range: 0...1, step: 0.02)
        }
    }

    private func adjustment(_ title: String, key: WritableKeyPath<EditRecipe, Double>, range: ClosedRange<Double>,
                            step: Double, decimals: Int = 2, suffix: String = "") -> some View {
        let value = Binding<Double>(get: { model.selectedRecipe[keyPath: key] }, set: { new in
            var recipe = model.selectedRecipe; recipe[keyPath: key] = new
            model.setRecipe(recipe, name: "Adjust \(title)", coalescing: title)
        })
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                TextField(title, value: value, format: .number.precision(.fractionLength(decimals)))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: decimals == 0 ? 66 : 58)
                    .font(.caption.monospacedDigit())
                if !suffix.isEmpty { Text(suffix).font(.caption2).foregroundStyle(.secondary) }
            }
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
        }
    }

    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { rotate(-90) } label: { Image(systemName: "rotate.left") }.help("Rotate 90° left")
                Button { rotate(90) } label: { Image(systemName: "rotate.right") }.help("Rotate 90° right")
                Spacer()
                Menu("Aspect") {
                    Button("Original") { var recipe = model.selectedRecipe; recipe.crop = nil; model.setRecipe(recipe, name: "Remove crop") }
                    Button("1:1 Square") { cropToAspect(1) }
                    Button("3:2 Photo") { cropToAspect(1.5) }
                    Button("4:3") { cropToAspect(4.0/3) }
                    Button("16:9 Wide") { cropToAspect(16.0/9) }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text("Straighten"); Spacer(); Text(straighten.wrappedValue, format: .number.precision(.fractionLength(1))).monospacedDigit(); Text("°") }.font(.caption)
                Slider(value: straighten, in: -45...45, step: 0.1).accessibilityLabel("Straighten")
            }
            Toggle("Crop", isOn: Binding(get: { model.selectedRecipe.crop != nil }, set: { enabled in
                var recipe = model.selectedRecipe
                recipe.crop = enabled ? CGRect(x: 0, y: 0, width: 1, height: 1) : nil
                model.setRecipe(recipe, name: enabled ? "Enable crop" : "Remove crop")
            }))
            if model.selectedRecipe.crop != nil {
                cropAdjustment("Left", component: .left, range: 0...0.99)
                cropAdjustment("Top", component: .top, range: 0...0.99)
                cropAdjustment("Width", component: .width, range: 0.01...1)
                cropAdjustment("Height", component: .height, range: 0.01...1)
                Text("Percentages refer to the rotated image. Straightening trims empty edges.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
    }

    private var straighten: Binding<Double> {
        Binding(get: {
            tiltComponent(model.selectedRecipe.rotation)
        }, set: { tilt in
            var recipe = model.selectedRecipe
            recipe.rotation = wrapped(recipe.rotation - tiltComponent(recipe.rotation) + tilt)
            model.setRecipe(recipe, name: "Straighten", coalescing: "straighten")
        })
    }
    private func tiltComponent(_ angle: Double) -> Double {
        var value = angle.truncatingRemainder(dividingBy: 90)
        if value > 45 { value -= 90 }; if value < -45 { value += 90 }
        return value
    }
    private func rotate(_ degrees: Double) {
        var recipe = model.selectedRecipe; recipe.rotation = wrapped(recipe.rotation + degrees)
        model.setRecipe(recipe, name: "Rotate photo")
    }
    private func wrapped(_ angle: Double) -> Double {
        var angle = angle
        while angle > 180 { angle -= 360 }; while angle < -180 { angle += 360 }
        return angle
    }
    private enum CropComponent { case left, top, width, height }
    private func cropAdjustment(_ title: String, component: CropComponent, range: ClosedRange<Double>) -> some View {
        let binding = Binding<Double>(get: {
            let rect = model.selectedRecipe.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            switch component { case .left: return rect.minX; case .top: return rect.minY; case .width: return rect.width; case .height: return rect.height }
        }, set: { value in
            var recipe = model.selectedRecipe
            var rect = recipe.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            switch component {
            case .left: rect.origin.x = min(0.99, max(0, value)); rect.size.width = min(rect.width, 1 - rect.minX)
            case .top: rect.origin.y = min(0.99, max(0, value)); rect.size.height = min(rect.height, 1 - rect.minY)
            case .width: rect.size.width = min(1 - rect.minX, max(0.01, value))
            case .height: rect.size.height = min(1 - rect.minY, max(0.01, value))
            }
            recipe.crop = rect
            model.setRecipe(recipe, name: "Crop photo", coalescing: "crop-\(title)")
        })
        return VStack(alignment: .leading, spacing: 3) {
            HStack { Text(title); Spacer(); Text(binding.wrappedValue, format: .percent.precision(.fractionLength(0))).monospacedDigit() }.font(.caption)
            Slider(value: binding, in: range, step: 0.01).accessibilityLabel("Crop \(title)")
        }
    }
    private func cropToAspect(_ ratio: Double) {
        guard let item = model.selectedItem else { return }
        var base = model.selectedRecipe; base.crop = nil
        Task {
            let result = await PreviewCache.shared.result(for: item, size: 1600, recipe: base)
            guard model.selectedID == item.id, case .image(let image) = result else { return }
            var current = model.selectedRecipe; current.crop = nil
            guard current == base else { return }
            let aspect = Double(image.width) / Double(image.height)
            let width = min(1, ratio / aspect), height = min(1, aspect / ratio)
            var recipe = model.selectedRecipe
            recipe.crop = CGRect(x: (1-width)/2, y: (1-height)/2, width: width, height: height)
            model.setRecipe(recipe, name: "Crop to aspect ratio")
        }
    }

    private var batchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Batch Apply").font(.headline)
            Text("\(model.selectedItems.count) selected · \(model.counts.picks) picked").font(.caption).foregroundStyle(.secondary)
            Button("Apply to Selected Photos") { model.applyEditToSelection() }.disabled(model.selectedItems.count < 2)
            Button("Apply to All Picks") { model.applyEditToSelection(allPicks: true) }.disabled(model.counts.picks == 0)
            Text("Includes crop and rotation. Undo restores the entire batch.").font(.caption2).foregroundStyle(.secondary)
        }
        .controlSize(.small)
    }
}

private struct HistogramPlot: View {
    let histogram: ImageHistogram
    var body: some View {
        Canvas { context, size in
            let channels: [([Int], Color)] = [(histogram.red, .red), (histogram.green, .green), (histogram.blue, .blue)]
            let peak = max(1, channels.flatMap { $0.0 }.max() ?? 1)
            for (values, color) in channels {
                guard values.count > 1 else { continue }
                var path = Path(); path.move(to: CGPoint(x: 0, y: size.height))
                for (index, value) in values.enumerated() {
                    let x = CGFloat(index) / CGFloat(values.count-1) * size.width
                    let y = size.height * (1 - CGFloat(log1p(Double(value)) / log1p(Double(peak))))
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height)); path.closeSubpath()
                context.fill(path, with: .color(color.opacity(0.45)))
            }
        }
    }
}
