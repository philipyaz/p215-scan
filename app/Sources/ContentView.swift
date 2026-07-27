import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var state: AppState

    var body: some View {
        NavigationSplitView {
            ScanSettingsSidebar(state: state)
                .navigationSplitViewColumnWidth(min: 260, ideal: 290, max: 340)
        } detail: {
            PageArea(state: state)
        }
        .toolbar { toolbarContent }
        .task {
            state.load()
            state.refreshDevice()
            state.startMonitoring()
        }
        .onDisappear { state.stopMonitoring(); state.persist() }
        .sheet(isPresented: $state.showSaveSheet) {
            SaveSheet(state: state)
        }
        .sheet(isPresented: $state.showPreferences) {
            PreferencesSheet(state: state)
        }
        .sheet(item: $state.editingPage) { page in
            PageDetailView(state: state, page: page)
        }
        .confirmationDialog("Replace the current batch?",
                            isPresented: $state.pendingReplaceConfirmation) {
            Button("Add to Batch") { state.confirmReplace(appending: true) }
            Button("Replace", role: .destructive) { state.confirmReplace(appending: false) }
            Button("Cancel", role: .cancel) { state.pendingJob = nil }
        } message: {
            Text("There are \(state.pages.count) unsaved page(s). "
                 + "Scanning will discard them unless you add to the batch.")
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { state.errorMessage != nil },
                                    set: { if !$0 { state.errorMessage = nil } })) {
            Button("OK", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                state.isScanning ? state.cancelScan() : state.requestScan()
            } label: {
                Label(state.isScanning ? "Stop" : "Scan",
                      systemImage: state.isScanning ? "stop.fill" : "doc.viewfinder")
            }
            .disabled(!state.device.isReady && !state.isScanning)

            Button {
                state.startScan(appending: true)
            } label: {
                Label("Scan More", systemImage: "plus.rectangle.on.rectangle")
            }
            .disabled(state.isScanning || !state.device.isReady)
        }

        ToolbarItem(placement: .principal) {
            StatusPill(state: state)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { state.presentImportPanel() } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .help("Add existing images as pages")

            Button { state.showSaveSheet = true } label: {
                Label("Save", systemImage: "square.and.arrow.up")
            }
            .disabled(state.pages.isEmpty)
        }
    }

    private func importPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .tiff, .jpeg, .png]
        if panel.runModal() == .OK {
            state.importImages(urls: panel.urls)
        }
    }
}

// MARK: - Status

struct StatusPill: View {
    @Bindable var state: AppState

    private var colour: Color {
        switch state.device {
        case .ready: return .green
        case .checking, .unknown: return .secondary
        default: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(colour).frame(width: 8, height: 8)
            if state.isScanning || state.isExporting {
                ProgressView().controlSize(.small)
            }
            Text(state.isScanning || state.isExporting
                 ? (state.statusText.isEmpty ? "Working…" : state.statusText)
                 : state.device.summary)
                .font(.callout)
                .lineLimit(1)
            switch state.device {
            case .volumeMissing, .notFound, .error:
                Button("Retry") { state.retryNow() }.controlSize(.small)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }
}

// MARK: - Page area

struct PageArea: View {
    @Bindable var state: AppState
    @State private var anchor: Int = 0

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 150 * state.zoom, maximum: 320 * state.zoom), spacing: 16)]
    }

    var body: some View {
        VStack(spacing: 0) {
            if state.visiblePages.isEmpty {
                EmptyState(state: state)
            } else {
                ScrollView {
                    if state.blankCount > 0 && !state.showBlankPages {
                        HStack(spacing: 8) {
                            Image(systemName: "eye.slash").foregroundStyle(.secondary)
                            Text("\(state.blankCount) blank page(s) hidden")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Show") { state.showBlankPages = true }
                                .controlSize(.small)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                        .padding(.top, 14)
                    }
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(Array(state.visiblePages.enumerated()), id: \.element.id) { idx, page in
                            PageThumbnail(page: page, index: idx + 1,
                                          isSelected: state.selection.contains(page.id))
                                .opacity(page.isBlank ? 0.45 : 1)
                                .onTapGesture(count: 2) { state.editingPage = page }
                                .onTapGesture {
                                    let mods = NSEvent.modifierFlags
                                    if mods.contains(.command) {
                                        toggle(page)
                                    } else if mods.contains(.shift) {
                                        extendSelection(to: idx)
                                    } else {
                                        state.selection = [page.id]
                                        anchor = idx
                                    }
                                }
                                .contextMenu { pageMenu(page) }
                                .draggable(page.id.uuidString) {
                                    PageThumbnail(page: page, index: idx + 1,
                                                  isSelected: false)
                                        .frame(width: 90)
                                }
                                .dropDestination(for: String.self) { items, _ in
                                    guard let raw = items.first,
                                          let from = state.pages.firstIndex(where: {
                                              $0.id.uuidString == raw }),
                                          let to = state.pages.firstIndex(where: {
                                              $0.id == page.id })
                                    else { return false }
                                    state.move(from: IndexSet(integer: from),
                                               to: to > from ? to + 1 : to)
                                    return true
                                }
                        }
                    }
                    .padding(20)
                }
            }
            if state.isScanning || state.isExporting {
                ProgressView(value: state.isExporting ? state.progress : nil,
                             total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(height: 2)
            }
            if let done = state.completion {
                CompletionBanner(state: state, completion: done)
            }
            Divider()
            PageToolbar(state: state)
        }
    }

    /// Shift-click selects the run between the last plain click and this one.
    private func extendSelection(to idx: Int) {
        let shown = state.visiblePages
        let lo = min(anchor, idx), hi = max(anchor, idx)
        guard shown.indices.contains(lo), shown.indices.contains(hi) else { return }
        state.selection = Set(shown[lo...hi].map(\.id))
    }

    private func toggle(_ page: ScannedPage) {
        if state.selection.contains(page.id) { state.selection.remove(page.id) }
        else { state.selection.insert(page.id) }
    }

    @ViewBuilder
    private func pageMenu(_ page: ScannedPage) -> some View {
        Button("Open") { state.editingPage = page }
        Divider()
        Button("Rotate Left")  { state.selection = [page.id]; state.rotate(by: -90) }
        Button("Rotate Right") { state.selection = [page.id]; state.rotate(by: 90) }
        Divider()
        Button("Revert to Original") { state.selection = [page.id]; state.revertSelected() }
        Divider()
        Button("Delete", role: .destructive) {
            state.selection = [page.id]; state.deleteSelected()
        }
    }
}

struct EmptyState: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("No pages yet").font(.title3)
            Text(hint).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if case .volumeMissing = state.device {
                Text("Connect the scanner with the rear Auto Start switch set to ON.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hint: String {
        state.device.isReady
            ? "Put a document in the feeder and press Scan."
            : state.device.summary
    }
}

struct PageThumbnail: View {
    let page: ScannedPage
    let index: Int
    let isSelected: Bool

    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .controlBackgroundColor))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(minHeight: 120)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? Color.accentColor : Color.black.opacity(0.15),
                            lineWidth: isSelected ? 3 : 1)
            )
            .shadow(radius: 1, y: 1)

            HStack(spacing: 4) {
                Text("\(index)").font(.caption).foregroundStyle(.secondary)
                if page.side == .back {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .help("Back side")
                }
            }
        }
        .task(id: adjustmentSignature) { await load() }
    }

    private var adjustmentSignature: String {
        let a = page.adjustments
        return "\(a.rotation)|\(a.straighten)|\(a.brightness)|\(a.contrast)|"
             + "\(a.grayscale)|\(a.blackWhite)|\(a.crop)"
    }

    private func load() async {
        let p = page
        let result: CGImage? = await Task.detached(priority: .userInitiated) {
            ImagePipeline.shared.thumbnail(for: p)
        }.value
        await MainActor.run { image = result }
    }
}

// MARK: - Bottom toolbar

struct PageToolbar: View {
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Button("All Pages")  { state.selectAll() }
                Button("Odd Pages")  { state.selectOdd() }
                Button("Even Pages") { state.selectEven() }
                Divider()
                Button("None") { state.selectNone() }
            } label: {
                Label("Select", systemImage: "checklist")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Divider().frame(height: 18)

            Button { state.rotate(by: -90) } label: {
                Image(systemName: "rotate.left")
            }.help("Rotate left").disabled(!state.hasSelection)

            Button { state.rotate(by: 90) } label: {
                Image(systemName: "rotate.right")
            }.help("Rotate right").disabled(!state.hasSelection)

            Button { state.autoStraightenSelected() } label: {
                Image(systemName: "ruler")
            }.help("Straighten").disabled(!state.hasSelection)

            Button { state.autoCropSelected() } label: {
                Image(systemName: "crop")
            }.help("Trim to contents").disabled(!state.hasSelection)

            Button { state.revertSelected() } label: {
                Image(systemName: "arrow.uturn.backward.circle")
            }.help("Revert to original").disabled(!state.hasSelection)

            Button(role: .destructive) { state.deleteSelected() } label: {
                Image(systemName: "trash")
            }
            .help("Delete selected")
            .disabled(state.selection.isEmpty)

            Divider().frame(height: 18)

            AdjustmentControls(state: state)
                .disabled(!state.hasSelection)

            if state.canUndoDelete {
                Button { state.undoDelete() } label: {
                    Image(systemName: "arrow.uturn.backward")
                }.help("Undo delete")
            }

            Spacer()

            Text(countLabel).font(.caption).foregroundStyle(.secondary)

            Slider(value: $state.zoom, in: 0.6...2.0) {
                Image(systemName: "magnifyingglass")
            }
            .frame(width: 110)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .disabled(state.pages.isEmpty)
    }

    private var countLabel: String {
        let total = state.visiblePages.count
        let sel = state.selection.count
        if total == 0 { return "" }
        return sel > 0 ? "\(sel) of \(total) selected" : "\(total) page(s)"
    }
}

struct AdjustmentControls: View {
    @Bindable var state: AppState

    private var targets: [ScannedPage] { state.effectivePages }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.max").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { targets.first?.adjustments.brightness ?? 0 },
                set: { v in for p in targets { p.adjustments.brightness = v } }
            ), in: -0.5...0.5).frame(width: 90)

            Image(systemName: "circle.lefthalf.filled").font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { targets.first?.adjustments.contrast ?? 0 },
                set: { v in for p in targets { p.adjustments.contrast = v } }
            ), in: -0.5...0.5).frame(width: 90)

            Toggle(isOn: Binding(
                get: { targets.first?.adjustments.grayscale ?? false },
                set: { v in for p in targets { p.adjustments.grayscale = v } }
            )) { Text("Grey") }
            .toggleStyle(.button).controlSize(.small)

            Toggle(isOn: Binding(
                get: { targets.first?.adjustments.blackWhite ?? false },
                set: { v in for p in targets { p.adjustments.blackWhite = v } }
            )) { Text("B&W") }
            .toggleStyle(.button).controlSize(.small)
        }
    }
}

/// The original ends a job on a "Process has been completed" screen with a link
/// to the folder. Same idea, without taking over the window.
struct CompletionBanner: View {
    @Bindable var state: AppState
    let completion: AppState.Completion

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Saved \(completion.pages) page(s) to "
                     + "\(completion.files.count) file(s)")
                    .font(.callout)
                Text(completion.files.first?.lastPathComponent ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Open") {
                if let f = completion.files.first { NSWorkspace.shared.open(f) }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(completion.files)
            }
            Button {
                state.completion = nil
            } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.quaternary)
    }
}
