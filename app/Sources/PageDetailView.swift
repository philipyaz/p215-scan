import SwiftUI
import AppKit

/// Full-size page view with the editing controls CaptureOnTouch Lite puts in
/// its preview panel: rotate, straighten, trim, and colour adjustment, plus
/// zoom / fit-to-window and page-to-page navigation.
struct PageDetailView: View {
    @Bindable var state: AppState
    @Bindable var page: ScannedPage

    @Environment(\.dismiss) private var dismiss
    @State private var rendered: CGImage?
    @State private var zoom: Double = 0          // 0 == fit to window
    @State private var tool: Tool = .none
    @State private var cropDraft: CGRect?

    enum Tool: String, CaseIterable, Identifiable {
        case none, colour, align, trim
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none:   return "View"
            case .colour: return "Colour adjustment"
            case .align:  return "Image alignment"
            case .trim:   return "Trimming"
            }
        }
        var symbol: String {
            switch self {
            case .none:   return "eye"
            case .colour: return "slider.horizontal.3"
            case .align:  return "ruler"
            case .trim:   return "crop"
            }
        }
    }

    private var index: Int { state.pages.firstIndex(where: { $0.id == page.id }) ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                canvas
                if tool != .none {
                    inspector
                        .frame(minWidth: 260, idealWidth: 280, maxWidth: 340)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 600)
        .task(id: signature) { await reload() }
    }

    private var signature: String {
        let a = page.adjustments
        return "\(page.id)|\(a.rotation)|\(a.straighten)|\(a.brightness)|\(a.contrast)"
             + "|\(a.grayscale)|\(a.blackWhite)|\(a.crop)|\(a.autoLevel)"
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Label("Done", systemImage: "chevron.left")
            }
            .keyboardShortcut(.cancelAction)

            Divider().frame(height: 18)

            Picker("", selection: $tool) {
                ForEach(Tool.allCases) { t in
                    Label(t.label, systemImage: t.symbol).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            Text("Page \(index + 1) of \(state.pages.count)")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()

            Spacer()

            Button { zoom = 0 } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Fit to window")
            Button { zoom = max(0.1, (zoom == 0 ? 1 : zoom) - 0.25) } label: {
                Image(systemName: "minus.magnifyingglass")
            }.help("Zoom out")
            Button { zoom = min(6, (zoom == 0 ? 1 : zoom) + 0.25) } label: {
                Image(systemName: "plus.magnifyingglass")
            }.help("Zoom in")
            Text(zoom == 0 ? "Fit" : "\(Int(zoom * 100))%")
                .font(.caption).monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                Group {
                    if let rendered {
                        let fitted = fit(rendered, into: geo.size)
                        Image(decorative: rendered, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: fitted.width, height: fitted.height)
                            .shadow(radius: 3, y: 1)
                    } else {
                        ProgressView().controlSize(.large)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .padding(20)
                .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    /// Size the page for the canvas: fit-to-window at zoom 0, otherwise a
    /// straight percentage of the page's natural size at 72 dpi.
    private func fit(_ image: CGImage, into size: CGSize) -> CGSize {
        let iw = Double(image.width), ih = Double(image.height)
        guard iw > 0, ih > 0 else { return .zero }
        if zoom == 0 {
            let available = CGSize(width: max(80, size.width - 40),
                                   height: max(80, size.height - 40))
            let scale = min(available.width / iw, available.height / ih)
            return CGSize(width: iw * scale, height: ih * scale)
        }
        // The proxy is rendered at up to 1800px; treat that as 100%.
        let base = min(1.0, 900.0 / max(iw, ih))
        return CGSize(width: iw * base * zoom, height: ih * base * zoom)
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        Form {
            switch tool {
            case .colour:
                Section("Colour adjustment") {
                    LabeledContent("Brightness") {
                        Slider(value: $page.adjustments.brightness, in: -0.5...0.5)
                    }
                    LabeledContent("Contrast") {
                        Slider(value: $page.adjustments.contrast, in: -0.5...0.5)
                    }
                    Toggle("Greyscale", isOn: $page.adjustments.grayscale)
                    Toggle("Black and white", isOn: $page.adjustments.blackWhite)
                    Toggle("Auto levels", isOn: $page.adjustments.autoLevel)
                }
                Section {
                    Button("Revert") { page.adjustments = PageAdjustments() }
                }

            case .align:
                Section("Image alignment") {
                    LabeledContent("Straighten") {
                        HStack {
                            Slider(value: $page.adjustments.straighten, in: -10...10)
                            Text(String(format: "%+.1f°", page.adjustments.straighten))
                                .font(.caption).monospacedDigit()
                                .frame(width: 46, alignment: .trailing)
                        }
                    }
                    Button("Detect automatically") {
                        let p = page
                        Task.detached {
                            let a = ImagePipeline.shared.estimateSkew(p.original)
                            await MainActor.run { p.adjustments.straighten = a }
                        }
                    }
                }
                Section("Rotate") {
                    HStack {
                        Button { rotate(-90) } label: {
                            Label("Left", systemImage: "rotate.left")
                        }
                        Button { rotate(90) } label: {
                            Label("Right", systemImage: "rotate.right")
                        }
                        Button { rotate(180) } label: { Text("180°") }
                    }
                    Button("Match text orientation") {
                        let p = page
                        Task.detached {
                            let d = Orientation.detect(p.original)
                            await MainActor.run { p.adjustments.rotation = d }
                        }
                    }
                }

            case .trim:
                Section("Trimming") {
                    let c = page.adjustments.crop
                    LabeledContent("Width", value: String(format: "%.0f%%", c.width * 100))
                    LabeledContent("Height", value: String(format: "%.0f%%", c.height * 100))
                    Button("Trim to contents") {
                        let p = page
                        Task.detached {
                            if let b = ImagePipeline.shared.contentBounds(p.original) {
                                await MainActor.run { p.adjustments.crop = b }
                            }
                        }
                    }
                    Button("Reset trim") {
                        page.adjustments.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
                    }
                }
                Section {
                    Text("Inset the edges to trim the page.")
                        .font(.caption).foregroundStyle(.secondary)
                    inset("Left",   CropEdge.minXInset)
                    inset("Right",  CropEdge.maxXInset)
                    inset("Top",    CropEdge.minYInset)
                    inset("Bottom", CropEdge.maxYInset)
                }

            case .none:
                Section("Page") {
                    LabeledContent("Size",
                        value: "\(Int(page.pixelSize.width)) × \(Int(page.pixelSize.height)) px")
                    LabeledContent("Resolution", value: "\(page.dpi) dpi")
                    LabeledContent("Side", value: page.side == .front ? "Front" : "Back")
                    LabeledContent("Ink coverage",
                        value: String(format: "%.2f%%", page.inkCoverage * 100))
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Crop edges are exposed as four inset sliders -- simpler to drive than a
    /// drag handle and precise enough for trimming a scan.
    private func inset(_ title: String, _ key: CropEdge) -> some View {
        LabeledContent(title) {
            Slider(value: Binding(
                get: { key.get(page.adjustments.crop) },
                set: { page.adjustments.crop = key.set(page.adjustments.crop, $0) }
            ), in: 0...0.45)
        }
    }

    private func rotate(_ d: Int) {
        page.adjustments.rotation = (((page.adjustments.rotation + d) % 360) + 360) % 360
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button { step(-1) } label: { Label("Previous", systemImage: "chevron.left") }
                .disabled(index == 0)
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button { step(1) } label: { Label("Next", systemImage: "chevron.right") }
                .disabled(index >= state.pages.count - 1)
                .keyboardShortcut(.rightArrow, modifiers: [])

            Spacer()

            Button("Revert to Original") { page.adjustments = PageAdjustments() }
            Button(role: .destructive) {
                state.selection = [page.id]
                state.deleteSelected()
                dismiss()
            } label: { Label("Delete Page", systemImage: "trash") }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard state.pages.indices.contains(next) else { return }
        state.editingPage = state.pages[next]
    }

    private func reload() async {
        let p = page
        let img = await Task.detached(priority: .userInitiated) {
            ImagePipeline.shared.thumbnail(for: p, maxPixel: 1800)
        }.value
        await MainActor.run { rendered = img }
    }
}

/// Which edge of the normalised crop rect a slider drives.
struct CropEdge {
    let get: (CGRect) -> Double
    let set: (CGRect, Double) -> CGRect

    static let minXInset = CropEdge(
        get: { $0.minX },
        set: { r, v in CGRect(x: v, y: r.minY, width: max(0.05, r.maxX - v), height: r.height) })
    static let maxXInset = CropEdge(
        get: { 1 - $0.maxX },
        set: { r, v in CGRect(x: r.minX, y: r.minY,
                              width: max(0.05, (1 - v) - r.minX), height: r.height) })
    static let minYInset = CropEdge(
        get: { $0.minY },
        set: { r, v in CGRect(x: r.minX, y: v, width: r.width,
                              height: max(0.05, r.maxY - v)) })
    static let maxYInset = CropEdge(
        get: { 1 - $0.maxY },
        set: { r, v in CGRect(x: r.minX, y: r.minY, width: r.width,
                              height: max(0.05, (1 - v) - r.minY)) })
}
