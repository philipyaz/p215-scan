import SwiftUI
import AppKit

// MARK: - Sidebar

struct ScanSettingsSidebar: View {
    @Bindable var state: AppState
    @State private var newPresetName = ""
    @State private var showNamePrompt = false
    @State private var saveAsJob = false
    @State private var renameTarget: Preset?

    var body: some View {
        Form {
            Section("Presets") {
                Menu {
                    ForEach(state.presets) { preset in
                        Button {
                            state.apply(preset)
                        } label: {
                            if state.activePresetID == preset.id {
                                Label(preset.name, systemImage: "checkmark")
                            } else {
                                Text(preset.name)
                            }
                        }
                    }
                    Divider()
                    Button("Save Current as Preset…") { showNamePrompt = true }
                    if let active = state.presets.first(where: {
                        $0.id == state.activePresetID }), !active.builtIn {
                        Button("Rename…") { renameTarget = active; newPresetName = active.name }
                        Button("Duplicate") { state.duplicatePreset(active) }
                        Button("Delete", role: .destructive) { state.deletePreset(active) }
                    }
                } label: {
                    Text(state.presets.first(where: { $0.id == state.activePresetID })?.name
                         ?? "Custom")
                }

                ForEach(state.presets.filter(\.autoSave)) { job in
                    Button {
                        state.runJob(job)
                    } label: {
                        Label("\(job.name) — scan & save", systemImage: "bolt.fill")
                    }
                    .disabled(state.isScanning || !state.device.isReady)
                }
            }

            Section("Document") {
                Picker("Colour mode", selection: $state.scan.colorMode) {
                    ForEach(ColorMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Resolution", selection: $state.scan.resolution) {
                    ForEach(Resolution.allCases) { Text($0.label).tag($0) }
                }
                Picker("Page size", selection: $state.scan.pageSize) {
                    ForEach(PageSize.allCases) { Text($0.label).tag($0) }
                }
                Picker("Scanning side", selection: $state.scan.side) {
                    ForEach(ScanSide.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("Processing") {
                Toggle("Skip blank pages", isOn: $state.scan.skipBlankPages)
                Picker("Straighten", selection: $state.scan.deskew) {
                    ForEach(DeskewMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Rotate to match text", isOn: $state.scan.rotateToText)
                if state.scan.colorMode.binarize != .none {
                    HStack {
                        Text("Threshold")
                        Slider(value: $state.scan.threshold, in: 0.1...0.9)
                        Text(String(format: "%.0f%%", state.scan.threshold * 100))
                            .font(.caption).monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }

            Section("Output") {
                Picker("File type", selection: $state.output.format) {
                    ForEach(FileFormat.allCases) { Text($0.label).tag($0) }
                }
                if state.output.format == .pdf {
                    Toggle("Searchable text (OCR)", isOn: $state.output.ocrEnabled)
                    if state.output.ocrEnabled {
                        Picker("Language", selection: $state.output.ocrLanguage) {
                            ForEach(OCRLanguage.allCases) { Text($0.label).tag($0) }
                        }
                    }
                }
                LabeledContent("Folder") {
                    Button(state.output.destination.lastPathComponent) { chooseFolder() }
                        .buttonStyle(.link)
                        .lineLimit(1)
                }
                Button("More Output Options…") { state.showSaveSheet = true }
                    .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .alert("Save preset", isPresented: $showNamePrompt) {
            TextField("Name", text: $newPresetName)
            Button("Save") {
                let n = newPresetName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { state.saveCurrentAsPreset(named: n, autoSave: saveAsJob) }
                newPresetName = ""; saveAsJob = false
            }
            Button("Save as one-click job") {
                let n = newPresetName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { state.saveCurrentAsPreset(named: n, autoSave: true) }
                newPresetName = ""; saveAsJob = false
            }
            Button("Cancel", role: .cancel) { newPresetName = ""; saveAsJob = false }
        } message: {
            Text("A one-click job scans and saves straight to the output folder "
                 + "with no dialog.")
        }
        .alert("Rename preset", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $newPresetName)
            Button("Rename") {
                if let t = renameTarget {
                    state.renamePreset(t, to: newPresetName.trimmingCharacters(
                        in: .whitespaces))
                }
                renameTarget = nil; newPresetName = ""
            }
            Button("Cancel", role: .cancel) { renameTarget = nil; newPresetName = "" }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = state.output.destination
        if panel.runModal() == .OK, let url = panel.url {
            state.output.destination = url
            state.persist()
        }
    }
}

// MARK: - Save sheet

struct SaveSheet: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Save \(state.pages.count) page(s)")
                .font(.title3).bold()
                .padding(.horizontal, 20).padding(.top, 20)

            Form {
                Section("Format") {
                    Picker("File type", selection: $state.output.format) {
                        ForEach(FileFormat.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if state.output.format.supportsMultipage {
                        Picker("Pages", selection: $state.output.multipage) {
                            ForEach(MultipageMode.allCases) { Text($0.label).tag($0) }
                        }
                        if state.output.multipage == .everyN {
                            Stepper("Pages per file: \(state.output.pagesPerFile)",
                                    value: $state.output.pagesPerFile, in: 1...100)
                        }
                    }

                    if state.output.format == .pdf {
                        Toggle("Add document metadata", isOn: $state.output.pdfA)
                        Toggle("Searchable text (OCR)", isOn: $state.output.ocrEnabled)
                        if state.output.ocrEnabled {
                            Picker("OCR language", selection: $state.output.ocrLanguage) {
                                ForEach(OCRLanguage.allCases) { Text($0.label).tag($0) }
                            }
                        }
                    }

                    if state.output.format != .png {
                        Picker("Compression", selection: $state.output.compression) {
                            ForEach(CompressionMode.allCases) { Text($0.label).tag($0) }
                        }
                        HStack {
                            Text("Quality")
                            Slider(value: Binding(
                                get: { Double(state.output.compressionRate) },
                                set: { state.output.compressionRate = Int($0.rounded()) }
                            ), in: 1...5, step: 1)
                            Text(rateLabel).font(.caption).foregroundStyle(.secondary)
                                .frame(width: 96, alignment: .trailing)
                        }
                    }
                }

                Section("File name") {
                    TextField("Base name", text: $state.output.baseName)
                    Picker("Date", selection: $state.output.dateStyle) {
                        ForEach(DateFormatStyle.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Add time", isOn: $state.output.addTime)
                    Toggle("Add counter", isOn: $state.output.addCounter)
                    if state.output.addCounter {
                        Stepper("Digits: \(state.output.counterDigits)",
                                value: $state.output.counterDigits, in: 1...6)
                        Stepper("Start at: \(state.output.counterStart)",
                                value: $state.output.counterStart, in: 0...99999)
                    }
                    LabeledContent("Preview") {
                        Text("\(state.output.fileName(index: 0)).\(state.output.format.fileExtension)")
                            .font(.callout).monospaced()
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if let problem = state.output.nameProblem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }

                Section("Destination") {
                    LabeledContent("Folder") {
                        HStack {
                            Text(state.output.destination.path)
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Button("Choose…") { chooseFolder() }.controlSize(.small)
                        }
                    }
                    HStack(spacing: 8) {
                        ForEach(quickFolders, id: \.0) { name, url in
                            Button(name) { state.output.destination = url }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if state.isExporting {
                ProgressView(value: state.progress) {
                    Text(state.statusText).font(.caption)
                }
                .padding(.horizontal, 20)
            }

            HStack {
                if let first = state.lastSaved.first {
                    Button("Reveal Last") {
                        NSWorkspace.shared.activateFileViewerSelecting([first])
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { state.save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isExporting || state.pages.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 560, height: 620)
    }

    private var rateLabel: String {
        switch state.output.compressionRate {
        case 1: return "Best quality"
        case 2: return "Better quality"
        case 3: return "Standard"
        case 4: return "Smaller file"
        default: return "Smallest file"
        }
    }

    private var quickFolders: [(String, URL)] {
        let fm = FileManager.default
        return [
            ("Desktop", fm.urls(for: .desktopDirectory, in: .userDomainMask).first),
            ("Documents", fm.urls(for: .documentDirectory, in: .userDomainMask).first),
            ("Pictures", fm.urls(for: .picturesDirectory, in: .userDomainMask).first),
        ].compactMap { name, url in url.map { (name, $0) } }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = state.output.destination
        if panel.runModal() == .OK, let url = panel.url {
            state.output.destination = url
        }
    }
}

// MARK: - Preferences

struct PreferencesSheet: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var maintenance: String = "Reading…"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Preferences").font(.title3).bold()
                .padding(.horizontal, 20).padding(.top, 20)

            Form {
                Section("Scanner") {
                    LabeledContent("Status", value: state.device.summary)
                    Button("Check Again") { state.refreshDevice() }
                        .controlSize(.small)
                    LabeledContent("Maintenance", value: maintenance)
                        .font(.callout)
                }

                Section("Blank page detection") {
                    HStack {
                        Text("Sensitivity")
                        Slider(value: $state.scan.blankThreshold, in: 0.0005...0.05)
                        Text(String(format: "%.2f%%", state.scan.blankThreshold * 100))
                            .font(.caption).monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                    }
                    Text("A page with less ink coverage than this is treated as blank.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Settings") {
                    Button("Reset All Settings") {
                        state.scan = ScanSettings()
                        state.output = OutputSettings()
                        state.presets = Preset.builtIns
                        state.persist()
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { state.persist(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 480, height: 460)
        .task { await loadMaintenance() }
    }

    private func loadMaintenance() async {
        let text: String = await Task.detached {
            let t = Tunnel()
            do {
                try t.open()
                defer { t.close() }
                // READ, datatype 0x8c = counters.
                let raw = try t.execute(
                    [0x28, 0x00, 0x8C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00],
                    inLength: 32)
                guard raw.count >= 12 else { return "Not reported" }
                func be32(_ i: Int) -> Int {
                    Int(raw[i]) << 24 | Int(raw[i+1]) << 16 | Int(raw[i+2]) << 8 | Int(raw[i+3])
                }
                return "Total \(be32(0)) · Roller \(be32(4)) · Pad \(be32(8))"
            } catch {
                return "Unavailable"
            }
        }.value
        maintenance = text
    }
}
