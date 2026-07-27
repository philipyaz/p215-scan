import Foundation
import CoreGraphics
import ImageIO

/// Drives the scanner through SANE's `canon_dr` backend, by running
/// `scanimage`.
///
/// This is the preferred path when the scanner's rear Auto Start switch is OFF
/// and it enumerates as a real scanner (USB 1083:165b). `canon_dr` programs the
/// analogue front end properly, so images come out clean -- unlike the file
/// tunnel, where calibration is unsolved and pages arrive pale and banded.
///
/// Options are discovered from `scanimage --help` at run time rather than
/// hardcoded, so anything this backend build does not advertise is simply
/// skipped instead of aborting the scan.
actor SaneBackend {

    enum Failure: Error, CustomStringConvertible {
        case notInstalled
        case noDevice
        case failed(Int32, String)
        case cancelled

        var description: String {
            switch self {
            case .notInstalled:
                return "scanimage was not found. Install it with: brew install sane-backends"
            case .noDevice:
                return "SANE cannot see the scanner."
            case .failed(let code, let text):
                return text.isEmpty ? "scanimage failed (exit \(code))" : text
            case .cancelled:
                return "Scanning was cancelled."
            }
        }
    }

    static let searchPaths = [
        "/opt/homebrew/bin/scanimage",
        "/usr/local/bin/scanimage",
        "/usr/bin/scanimage",
    ]

    static var executable: String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool { executable != nil }

    private var currentProcess: Process?
    private var cancelRequested = false
    /// Option discovery costs a second scanimage invocation, so it is fetched
    /// once per device and reused. Detection itself only needs `-L`.
    private var cachedOptions: (device: String, options: Set<String>, help: String)?

    func requestCancel() {
        cancelRequested = true
        guard let p = currentProcess, p.isRunning else { return }
        p.terminate()                       // SIGTERM
        // scanimage can sit in a blocking USB read and ignore SIGTERM, which
        // leaves the batch running and the UI stuck on "Cancelling…".
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }

    // MARK: - Discovery

    struct Device {
        var name: String          // SANE device name, e.g. canon_dr:libusb:002:004
        var model: String
        var options: Set<String>
        var helpText: String

        /// The allowed-values blob scanimage prints after an option name.
        func values(for option: String) -> String {
            let escaped = NSRegularExpression.escapedPattern(for: option)
            guard let re = try? NSRegularExpression(
                pattern: "^\\s+\(escaped)\\s+(.*)$", options: [.anchorsMatchLines])
            else { return "" }
            let ns = helpText as NSString
            guard let m = re.firstMatch(in: helpText, range: NSRange(location: 0,
                                                                    length: ns.length)),
                  m.numberOfRanges > 1 else { return "" }
            return ns.substring(with: m.range(at: 1))
        }
    }

    private static func run(_ path: String, _ args: [String],
                            timeout: TimeInterval = 60) -> (Int32, String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (-1, "", "\(error)") }

        let watchdog = DispatchWorkItem {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let oData = out.fileHandleForReading.readDataToEndOfFile()
        let eData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        return (p.terminationStatus,
                String(decoding: oData, as: UTF8.self),
                String(decoding: eData, as: UTF8.self))
    }

    /// Cheap detection: one `scanimage -L`, no option probe. This is what the
    /// status indicator polls, so it must stay fast.
    func detect() throws -> (name: String, model: String) {
        guard let exe = SaneBackend.executable else { throw Failure.notInstalled }
        let (_, listOut, _) = SaneBackend.run(exe, ["-L"], timeout: 20)
        guard let r = listOut.range(of: "device `([^']+)'", options: .regularExpression) else {
            throw Failure.noDevice
        }
        let name = String(listOut[r]).replacingOccurrences(of: "device `", with: "")
                                     .replacingOccurrences(of: "'", with: "")
        var model = "Scanner"
        if let mr = listOut.range(of: "is a .+", options: .regularExpression) {
            model = String(listOut[mr]).replacingOccurrences(of: "is a ", with: "")
                                       .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (name, model)
    }

    func discover() throws -> Device {
        guard let exe = SaneBackend.executable else { throw Failure.notInstalled }
        let (_, listOut, _) = SaneBackend.run(exe, ["-L"])
        guard let r = listOut.range(of: "device `([^']+)'", options: .regularExpression) else {
            throw Failure.noDevice
        }
        let name = String(listOut[r]).replacingOccurrences(of: "device `", with: "")
                                     .replacingOccurrences(of: "'", with: "")
        var model = "Scanner"
        if let mr = listOut.range(of: "is a .+", options: .regularExpression) {
            model = String(listOut[mr]).replacingOccurrences(of: "is a ", with: "")
                                       .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let cached = cachedOptions, cached.device == name {
            return Device(name: name, model: model,
                          options: cached.options, helpText: cached.help)
        }

        let (_, helpOut, _) = SaneBackend.run(exe, ["-d", name, "--help"])
        var opts = Set<String>()
        if let re = try? NSRegularExpression(pattern: "^\\s+(--[a-zA-Z0-9-]+)",
                                             options: [.anchorsMatchLines]) {
            let ns = helpOut as NSString
            for m in re.matches(in: helpOut, range: NSRange(location: 0, length: ns.length))
            where m.numberOfRanges > 1 {
                opts.insert(ns.substring(with: m.range(at: 1)))
            }
        }
        cachedOptions = (name, opts, helpOut)
        return Device(name: name, model: model, options: opts, helpText: helpOut)
    }

    // MARK: - Argument construction

    private func arguments(for settings: ScanSettings, device: Device,
                           pattern: String) -> [String] {
        var a = ["-d", device.name]

        if device.options.contains("--source") {
            let available = device.values(for: "--source")
            let wanted = settings.side == .simplex
                ? ["ADF Front", "ADF", "ADF Duplex"]
                : ["ADF Duplex", "ADF Front", "ADF"]
            if let pick = wanted.first(where: {
                available.localizedCaseInsensitiveContains($0)
            }) { a += ["--source", pick] }
        }

        if device.options.contains("--mode") {
            let available = device.values(for: "--mode")
            let wanted: [String]
            switch settings.colorMode.wireMode {
            case .color: wanted = ["Color", "Gray", "Lineart"]
            case .gray:
                wanted = settings.colorMode.binarize == .none
                    ? ["Gray", "Color", "Lineart"]
                    : ["Lineart", "Gray", "Color"]
            }
            if let pick = wanted.first(where: {
                available.localizedCaseInsensitiveContains($0)
            }) { a += ["--mode", pick] }
        }

        if device.options.contains("--resolution") {
            a += ["--resolution", String(settings.resolution.effective)]
        }

        // Page geometry. "Match original size" is handled by software cropping
        // rather than by asking for a specific size.
        if settings.pageSize != .auto && settings.pageSize != .max {
            let (w, h) = settings.pageSize.millimetres
            if device.options.contains("--page-width") {
                a += ["--page-width", String(format: "%.2f", w)]
            }
            if device.options.contains("--page-height") {
                a += ["--page-height", String(format: "%.2f", h)]
            }
            if device.options.contains("-x") { a += ["-x", String(format: "%.2f", w)] }
            if device.options.contains("-y") { a += ["-y", String(format: "%.2f", h)] }
        }

        // Boolean options are declared as --name[=(yes|no)] and are only
        // accepted joined with '=', never as two arguments.
        if settings.deskew != .off, device.options.contains("--swdeskew") {
            a += ["--swdeskew=yes"]
        }
        // Deliberately NOT sending --swcrop. canon_dr's software crop cannot
        // find the paper edges on this scanner (its calibration is too poor)
        // and crops to the ink instead: a full 2544x3300 page came back as
        // 494x440, losing everything but the handwriting. "Match original
        // size" is handled by the scanner's own page-length detection, which
        // is accurate, plus optional trimming in the page editor.
        if device.options.contains("--brightness"), settings.brightness != 0 {
            a += ["--brightness", String(Int(settings.brightness * 127))]
        }
        if device.options.contains("--contrast"), settings.contrast != 0 {
            a += ["--contrast", String(Int(settings.contrast * 127))]
        }
        if device.options.contains("--threshold"),
           settings.colorMode.binarize != .none {
            a += ["--threshold", String(Int(settings.threshold * 255))]
        }

        // Blank-page removal is done here rather than with the backend's
        // --swskip, which does not reliably drop pages in batch mode.
        a += ["--format", "tiff", "--batch=" + pattern]
        return a
    }

    // MARK: - Scanning

    /// Run a batch. Pages are delivered as they finish, so the UI fills in
    /// while the feeder is still running.
    /// Human text for the SANE exit codes worth naming.
    static func describe(exit code: Int32) -> String {
        switch code {
        case 3: return "The scanner was busy."
        case 6: return "Paper jam — clear the feeder and try again."
        case 8: return "The scanner cover is open."
        case 9: return "Lost contact with the scanner."
        default: return "The scanner reported an error (code \(code))."
        }
    }

    /// Set when a batch finished with a fault but still produced pages.
    private(set) var lastWarning: String?

    func scanBatch(settings: ScanSettings,
                   onPage: @Sendable @escaping (ScannedPage) -> Void,
                   onStatus: @Sendable @escaping (String) -> Void) async throws -> Int {
        lastWarning = nil
        cancelRequested = false
        guard let exe = SaneBackend.executable else { throw Failure.notInstalled }
        let device = try discover()

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p215-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pattern = dir.appendingPathComponent("page-%03d.tif").path
        let args = arguments(for: settings, device: device, pattern: pattern)

        onStatus("Starting scanner…")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        do { try process.run() } catch { throw Failure.failed(-1, "\(error)") }
        currentProcess = process

        // scanimage reports progress on stderr, one line per page.
        let errHandle = errPipe.fileHandleForReading
        var errText = ""

        var delivered = Set<String>()
        var produced = 0      // sides seen
        var kept = 0          // pages actually handed to the caller
        var warning: String?  // a fault that did not cost us the whole batch

        func ingestFinishedPages(all: Bool) {
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasSuffix(".tif") }
                .sorted { a, b in
                    let na = Int(a.dropFirst("page-".count).prefix(3)) ?? 0
                    let nb = Int(b.dropFirst("page-".count).prefix(3)) ?? 0
                    return na == nb ? a < b : na < nb
                }
            // While the process is alive the newest file may still be being
            // written, so hold it back until the next one appears or we finish.
            let ready = all ? files : files.dropLast()
            for f in ready where !delivered.contains(f) {
                let url = dir.appendingPathComponent(f)
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      CGImageSourceGetStatus(src) == .statusComplete,
                      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                    // Still being written, or unreadable. Leave it out of
                    // `delivered` so a later pass can pick it up.
                    continue
                }
                delivered.insert(f)

                // Derive the side from the file's own number rather than a
                // running counter: one unreadable file used to flip front/back
                // for every page after it, and simplex batches were labelling
                // every other page as a back side.
                let number = Int(f.dropFirst("page-".count).prefix(3)) ?? (produced + 1)
                let side: ScannedPage.Side = settings.side == .simplex
                    ? .front
                    : ((number - 1) % 2 == 0 ? .front : .back)

                let page = ScannedPage(original: cg, dpi: settings.resolution.effective,
                                       side: side)
                page.inkCoverage = ImagePipeline.shared.inkCoverage(cg)
                // canon_dr's calibration for this model is rated "poor" upstream
                // and it shows: raw scans come back with a badly lifted black
                // point, darkest pixel around luma 160 and nothing below 64, so
                // text reads as mid-grey. Stretching each channel to its own
                // black/white point is what makes the blacks actually black.
                page.adjustments.autoLevel = true

                // A sheet-fed scanner cannot know which way the paper went in,
                // and duplex backs routinely come out upside down.
                if settings.rotateToText, page.inkCoverage > 0.001 {
                    page.adjustments.rotation = Orientation.detect(cg)
                }

                // Blank pages are flagged, never dropped. Silently discarding
                // them meant a misjudged threshold destroyed real scans with no
                // count, no warning and no way back.
                page.isBlank = page.inkCoverage < settings.blankThreshold
                onPage(page)
                produced += 1
                kept += 1
                onStatus("\(kept) page(s)")
            }
        }

        while process.isRunning {
            if cancelRequested { process.terminate(); break }
            let chunk = errHandle.availableData
            if !chunk.isEmpty {
                let text = String(decoding: chunk, as: UTF8.self)
                errText += text
                for line in text.split(separator: "\n") {
                    if line.contains("Scanning page") || line.contains("Scanned page") {
                        onStatus(line.trimmingCharacters(in: .whitespaces))
                    }
                }
            }
            ingestFinishedPages(all: false)
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        errText += String(decoding: errHandle.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        currentProcess = nil
        ingestFinishedPages(all: true)

        if cancelRequested { throw Failure.cancelled }

        // Exit 7 is SANE_STATUS_NO_DOCS -- the ordinary end of an ADF batch.
        // 0 = clean, 7 = SANE_STATUS_NO_DOCS, the ordinary end of an ADF batch.
        let code = process.terminationStatus
        if code != 0 && code != 7 {
            let message = errText
                .split(separator: "\n")
                .last { $0.lowercased().contains("scanimage:") }
                .map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if delivered.isEmpty {
                throw Failure.failed(code, message)
            }
            // Some pages made it. Report the fault without throwing away work.
            warning = message.isEmpty ? Self.describe(exit: code) : message
            lastWarning = warning
        }
        return kept
    }
}
