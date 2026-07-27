import Foundation
import SwiftUI
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Which route to the scanner is in use.
enum Transport: Equatable {
    /// SANE's canon_dr backend, when the rear Auto Start switch is OFF and the
    /// scanner enumerates as a scanner. Better images -- the sensor is
    /// calibrated properly.
    case sane
    /// The CaptureOnTouch Lite file tunnel, when Auto Start is ON and the
    /// scanner pretends to be a flash drive.
    case tunnel
    case none

    var label: String {
        switch self {
        case .sane: return "SANE"
        case .tunnel: return "CaptureOnTouch tunnel"
        case .none: return "—"
        }
    }
}

enum DeviceStatus: Equatable {
    case unknown
    case checking
    case ready(model: String, detail: String, transport: Transport, paper: Bool?)
    /// Attached in CaptureOnTouch Lite mode but the control volume is missing.
    case volumeMissing
    case notFound
    case error(String)

    var isReady: Bool { if case .ready = self { return true }; return false }

    var transport: Transport {
        if case .ready(_, _, let t, _) = self { return t }
        return .none
    }

    var summary: String {
        switch self {
        case .unknown, .checking: return "Looking for the scanner…"
        case .ready(let m, _, let t, let paper):
            var s = m
            if let paper { s += paper ? " — paper ready" : " — no paper in feeder" }
            if t == .tunnel { s += " (tunnel)" }
            return s
        case .volumeMissing:
            return "Scanner found, but its control volume is not mounted"
        case .notFound: return "No scanner found"
        case .error(let m): return m
        }
    }
}

@MainActor
@Observable
final class AppState {

    var pages: [ScannedPage] = []
    var scan = ScanSettings()
    var output = OutputSettings()
    var presets: [Preset] = Preset.builtIns
    var device: DeviceStatus = .unknown

    var isScanning = false
    var isExporting = false
    var statusText = ""
    var progress: Double = 0

    var selection: Set<UUID> = []
    /// Blank pages are kept but hidden. This reveals them.
    var showBlankPages = false
    var errorMessage: String?
    var lastSaved: [URL] = []
    /// Set when a batch finishes saving, so the UI can show the original's
    /// "Process has been completed" / "Open storage folder" affordance.
    var completion: Completion?

    struct Completion: Equatable {
        var files: [URL]
        var pages: Int
        var folder: URL
    }
    var showSaveSheet = false
    var showPreferences = false
    var zoom: Double = 1.0
    var editingPage: ScannedPage?

    private let engine = ScanEngine()
    private let sane = SaneBackend()
    private var monitorTask: Task<Void, Never>?
    private var lastPresence: USBPresence.Mode = .absent
    /// When the last SANE probe ran, and how many have failed in a row.
    /// Probing opens the USB device; doing it on a short timer is what makes a
    /// healthy scanner start dropping out.
    private var lastProbe = Date.distantPast
    private var consecutiveProbeFailures = 0
    /// Set while a device check is in flight, so overlapping polls don't pile up.
    private var checking = false

    // MARK: - Device

    /// Prefer SANE when it can see the scanner -- it calibrates the sensor, so
    /// the images are far better than the tunnel can currently manage. Fall
    /// back to the tunnel when the scanner is in CaptureOnTouch Lite mode.
    /// Watch for the scanner being plugged in, unplugged, or switched between
    /// modes.
    ///
    /// The presence check reads the IOKit registry, which is free and touches
    /// nothing on the USB bus. `scanimage -L` is only run when presence
    /// actually changes -- running it on a timer opens the device every few
    /// seconds and makes a perfectly healthy scanner flap between found and
    /// not-found.
    func startMonitoring() {
        guard monitorTask == nil else { return }
        lastPresence = USBPresence.scannerMode()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.isScanning || self.isExporting { continue }

                let now = USBPresence.scannerMode()
                let changed = now != self.lastPresence
                self.lastPresence = now

                if !now.isAttached {
                    if self.device.isReady || changed {
                        self.device = .notFound
                        self.consecutiveProbeFailures = 0
                    }
                    continue
                }

                // A presence change is always worth a probe -- the user just
                // plugged something in or flipped the switch.
                if changed {
                    self.consecutiveProbeFailures = 0
                    self.probeNow()
                    continue
                }

                // Otherwise only retry on a long backoff. Repeatedly opening
                // the device while it is unhappy is what wedges it, and no
                // amount of retrying will revive a scanner that has stopped
                // answering control transfers -- that needs a replug.
                guard !self.device.isReady else { continue }
                let backoff = min(300.0, 30.0 * pow(2.0,
                                   Double(min(self.consecutiveProbeFailures, 4))))
                if Date().timeIntervalSince(self.lastProbe) >= backoff {
                    self.probeNow()
                }
            }
        }
    }

    /// Run a SANE probe, recording when it happened so the backoff can pace it.
    private func probeNow() {
        lastProbe = Date()
        let before = device.isReady
        refreshDevice(quiet: true)
        _ = before
    }

    /// Called by the Retry button -- the user asking explicitly bypasses the
    /// backoff, but still cannot stack overlapping probes.
    func retryNow() {
        consecutiveProbeFailures = 0
        lastProbe = Date()
        refreshDevice()
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func refreshDevice(quiet: Bool = false) {
        guard !checking else { return }
        checking = true
        if !quiet { device = .checking }
        Task.detached { [engine, sane] in
            if let d = try? await sane.detect() {
                await MainActor.run {
                    self.device = .ready(model: d.model, detail: d.name,
                                         transport: .sane, paper: nil)
                    self.consecutiveProbeFailures = 0
                    self.checking = false
                }
                return
            }
            await MainActor.run { self.consecutiveProbeFailures += 1 }
            do {
                let d = try await engine.probe()
                let model = "\(d.identity.vendor) \(d.identity.product)"
                    .trimmingCharacters(in: .whitespaces)
                await MainActor.run {
                    self.device = .ready(model: model, detail: d.identity.revision,
                                         transport: .tunnel,
                                         paper: d.sensors.paperInFeeder)
                    self.checking = false
                }
            } catch let e as Tunnel.Failure {
                await MainActor.run {
                    if case .volumeMissing = e {
                        // The scanner may be attached but in a mode this build
                        // cannot reach, or scanimage may be missing entirely.
                        switch USBPresence.scannerMode() {
                        case .scanner:
                            self.device = SaneBackend.isInstalled
                                ? .error("Scanner attached but SANE cannot open it. "
                                       + "Try unplugging and reconnecting it.")
                                : .error("Scanner attached, but scanimage is not "
                                       + "installed. Run: brew install sane-backends")
                        case .storage:
                            self.device = .volumeMissing
                        case .unknown(let pid):
                            self.device = .error(String(format:
                                "Unrecognised Canon device (0x%04x)", pid))
                        case .absent:
                            self.device = .notFound
                        }
                    } else {
                        self.device = .error(e.description)
                    }
                    self.checking = false
                }
            } catch {
                await MainActor.run {
                    self.device = .error(describe(error))
                    self.checking = false
                }
            }
        }
    }

    // MARK: - Scanning

    /// Set when a fresh scan would discard an existing batch, so the UI can ask
    /// first. Scanning is not cheap to redo -- the paper has already gone
    /// through the feeder.
    var pendingReplaceConfirmation = false

    func requestScan(appending: Bool = false) {
        guard !isScanning else { return }
        pendingJob = nil
        if !appending && !pages.isEmpty {
            pendingReplaceConfirmation = true
            return
        }
        startScan(appending: appending)
    }

    /// Resolve the "replace the batch?" dialog.
    func confirmReplace(appending: Bool) {
        let job = pendingJob
        pendingJob = nil
        pendingReplaceConfirmation = false
        startScan(appending: appending, thenSaveWith: appending ? nil : job)
    }

    func startScan(appending: Bool = false, thenSaveWith job: Preset? = nil) {
        guard !isScanning else { return }
        pendingReplaceConfirmation = false
        if !appending { pages.removeAll(); selection.removeAll() }
        isScanning = true
        progress = 0
        statusText = "Starting…"
        errorMessage = nil
        completion = nil

        let settings = scan
        let transport = device.transport

        // Pages are delivered through a stream consumed in order on the main
        // actor. Spawning an unstructured Task per page, as this used to, has
        // no ordering guarantee -- page 3 could land before page 2 and silently
        // reorder the PDF.
        let (stream, continuation) = AsyncStream<ScannedPage>.makeStream()
        let consumer = Task { @MainActor [weak self] in
            for await page in stream {
                guard let self else { return }
                self.pages.append(page)
                let shown = self.visiblePages.count
                self.statusText = "\(shown) page(s)"
            }
        }

        Task.detached { [engine, sane] in
            do {
                let scanBatch = transport == .sane
                    ? sane.scanBatch(settings:onPage:onStatus:)
                    : engine.scanBatch(settings:onPage:onStatus:)
                let n = try await scanBatch(
                    settings,
                    { page in continuation.yield(page) },
                    { s in Task { @MainActor in self.statusText = s } })
                continuation.finish()
                await consumer.value

                let warning = transport == .sane ? await sane.lastWarning : nil
                await MainActor.run {
                    self.isScanning = false
                    let shown = self.visiblePages.count
                    let hidden = self.blankCount
                    self.statusText = n == 0 && shown == 0
                        ? "No pages captured"
                        : "\(shown) page(s)" + (hidden > 0 ? " · \(hidden) blank" : "")
                    if let warning { self.errorMessage = warning }
                }
                if let job, !(await MainActor.run { self.pages.isEmpty }) {
                    await MainActor.run { self.output = job.output }
                    await MainActor.run { self.save() }
                }
            } catch {
                continuation.finish()
                await consumer.value
                await MainActor.run {
                    self.isScanning = false
                    if isCancellation(error) {
                        self.statusText = self.pages.isEmpty
                            ? "Scan cancelled"
                            : "\(self.visiblePages.count) page(s) — cancelled"
                    } else {
                        self.errorMessage = describe(error)
                        self.statusText = ""
                    }
                }
            }
        }
    }

    /// One click: apply the preset, scan, and save straight to its folder.
    func runJob(_ preset: Preset) {
        apply(preset)
        guard !isScanning else { return }
        if !pages.isEmpty {
            pendingJob = preset
            pendingReplaceConfirmation = true
            return
        }
        startScan(thenSaveWith: preset)
    }

    var pendingJob: Preset?

    func cancelScan() {
        Task {
            await engine.requestCancel()
            await sane.requestCancel()
            statusText = "Cancelling…"
        }
    }

    // MARK: - Page operations

    /// Pages shown in the grid and written on export.
    var visiblePages: [ScannedPage] {
        showBlankPages ? pages : pages.filter { !$0.isBlank }
    }

    var blankCount: Int { pages.filter(\.isBlank).count }

    var selectedPages: [ScannedPage] {
        pages.filter { selection.contains($0.id) }
    }

    /// Page mutations act on the selection, never implicitly on everything --
    /// an accidental Rotate with nothing selected used to spin the whole batch.
    var effectivePages: [ScannedPage] { selectedPages }

    var hasSelection: Bool { !selection.isEmpty }

    func selectAll() { selection = Set(visiblePages.map(\.id)) }
    func selectNone() { selection.removeAll() }
    func selectOdd() {
        selection = Set(visiblePages.enumerated()
            .filter { $0.offset % 2 == 0 }.map { $0.element.id })
    }
    func selectEven() {
        selection = Set(visiblePages.enumerated()
            .filter { $0.offset % 2 == 1 }.map { $0.element.id })
    }

    func rotate(by degrees: Int) {
        for p in effectivePages {
            p.adjustments.rotation = (((p.adjustments.rotation + degrees) % 360) + 360) % 360
        }
    }

    /// Last deletion, so it can be put back. Pages are expensive to re-acquire
    /// -- deleting one by mistake should not mean re-feeding the sheet.
    private var deletedPages: [(index: Int, page: ScannedPage)] = []

    var canUndoDelete: Bool { !deletedPages.isEmpty }

    func deleteSelected() {
        guard !selection.isEmpty else { return }
        let doomed = selection
        deletedPages = pages.enumerated()
            .filter { doomed.contains($0.element.id) }
            .map { (index: $0.offset, page: $0.element) }
        pages.removeAll { doomed.contains($0.id) }
        selection.removeAll()
    }

    func undoDelete() {
        guard !deletedPages.isEmpty else { return }
        for entry in deletedPages.sorted(by: { $0.index < $1.index }) {
            let at = min(entry.index, pages.count)
            pages.insert(entry.page, at: at)
        }
        selection = Set(deletedPages.map { $0.page.id })
        deletedPages.removeAll()
    }

    func revertSelected() {
        for p in effectivePages { p.adjustments = PageAdjustments() }
    }

    func autoStraightenSelected() {
        let targets = effectivePages
        Task.detached {
            for p in targets {
                let angle = ImagePipeline.shared.estimateSkew(p.original)
                await MainActor.run { p.adjustments.straighten = angle }
            }
        }
    }

    func autoCropSelected() {
        let targets = effectivePages
        Task.detached {
            for p in targets {
                if let b = ImagePipeline.shared.contentBounds(p.original) {
                    await MainActor.run { p.adjustments.crop = b }
                }
            }
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        pages.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - Import (works without a scanner)

    /// Import lives on the model so it can be driven from the menu as well as
    /// the toolbar.
    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .tiff, .jpeg, .png]
        panel.message = "Choose images to add as pages"
        if panel.runModal() == .OK { importImages(urls: panel.urls) }
    }

    func importImages(urls: [URL]) {
        for url in urls {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { continue }
            let count = CGImageSourceGetCount(src)
            for i in 0..<count {
                guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
                var dpi = 300
                if let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
                   let x = props[kCGImagePropertyDPIWidth] as? Double, x > 1 {
                    dpi = Int(x)
                }
                let page = ScannedPage(original: cg, dpi: dpi)
                page.inkCoverage = ImagePipeline.shared.inkCoverage(cg)
                pages.append(page)
            }
        }
        statusText = "\(pages.count) page(s)"
    }

    // MARK: - Export

    func save() {
        let snapshot = visiblePages
        guard !snapshot.isEmpty else {
            errorMessage = pages.isEmpty
                ? "There are no pages to save."
                : "Every page was detected as blank. Turn on Show Blank Pages to include them."
            return
        }
        isExporting = true
        progress = 0
        let settings = output

        Task.detached {
            do {
                let result = try await Exporter.export(
                    pages: snapshot, settings: settings,
                    progress: { frac, text in
                        Task { @MainActor in
                            self.progress = frac
                            self.statusText = text
                        }
                    })
                await MainActor.run {
                    self.isExporting = false
                    self.lastSaved = result.files
                    self.statusText = "Saved \(result.files.count) file(s)"
                    self.showSaveSheet = false
                    self.completion = Completion(files: result.files,
                                                 pages: result.pagesWritten,
                                                 folder: settings.destination)
                }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    self.errorMessage = describe(error)
                }
            }
        }
    }

    // MARK: - Presets

    func apply(_ preset: Preset) {
        let folder = output.destination
        scan = preset.scan
        output = preset.output
        // A preset describes how to scan and what format to write, not where
        // the user keeps their files.
        if !preset.autoSave { output.destination = folder }
        activePresetID = preset.id
    }

    var activePresetID: UUID?

    func renamePreset(_ preset: Preset, to name: String) {
        guard let i = presets.firstIndex(where: { $0.id == preset.id }), !preset.builtIn
        else { return }
        presets[i].name = name
        persist()
    }

    func duplicatePreset(_ preset: Preset) {
        var copy = preset
        copy.id = UUID()
        copy.name = preset.name + " copy"
        copy.builtIn = false
        presets.append(copy)
        persist()
    }

    func saveCurrentAsPreset(named name: String, autoSave: Bool = false) {
        var p = Preset(name: name, scan: scan, output: output)
        p.autoSave = autoSave
        presets.append(p)
        activePresetID = p.id
        persistPresets()
    }

    func deletePreset(_ preset: Preset) {
        guard !preset.builtIn else { return }
        presets.removeAll { $0.id == preset.id }
        persistPresets()
    }

    // MARK: - Persistence

    private var settingsURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("P215Scan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    private struct Persisted: Codable {
        var scan: ScanSettings
        var output: OutputSettings
        var presets: [Preset]
    }

    func load() {
        guard let data = try? Data(contentsOf: settingsURL),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        scan = p.scan
        output = p.output
        let custom = p.presets.filter { !$0.builtIn }
        presets = Preset.builtIns + custom
    }

    func persist() {
        let p = Persisted(scan: scan, output: output,
                          presets: presets.filter { !$0.builtIn })
        if let data = try? JSONEncoder().encode(p) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }

    private func persistPresets() { persist() }

}

/// Errors in this app carry human-readable descriptions; surface those rather
/// than Swift's default reflection output.
func describe(_ error: Error) -> String {
    switch error {
    case let e as Tunnel.Failure: return e.description
    case let e as ScanEngine.Failure: return e.description
    case let e as Exporter.Failure: return e.description
    case let e as SaneBackend.Failure: return e.description
    default: return error.localizedDescription
    }
}

/// True for the various ways "the user pressed Stop" reaches us.
func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if case SaneBackend.Failure.cancelled = error { return true }
    if case ScanEngine.Failure.cancelled = error { return true }
    return false
}
