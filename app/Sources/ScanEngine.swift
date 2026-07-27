import Foundation
import CoreGraphics

/// Drives an acquisition over the file tunnel.
///
/// The command set is Canon's DR-family SCSI -- the same one SANE's `canon_dr`
/// backend speaks; only the pipe differs. See reference/protocol/PROTOCOL.md for the transport
/// and reference/protocol/SCANSEQ.md for the command sequence and byte layouts.
actor ScanEngine {

    enum Failure: Error, CustomStringConvertible {
        case notConnected
        case noPaper
        case cancelled
        case badImageData(String)

        var description: String {
            switch self {
            case .notConnected: return "The scanner is not connected."
            case .noPaper:      return "There is no paper in the feeder."
            case .cancelled:    return "Scanning was cancelled."
            case .badImageData(let m): return "Unusable image data: \(m)"
            }
        }
    }

    private static let descLen = 0x2C
    private static let headerLen = 8
    /// Window geometry is expressed in 1/1200 inch.
    private static let unitsPerInch = 1200.0
    /// The hardware rounds the pixel width down to a multiple of this.
    private static let pixelsPerLineModulus = 8

    private var cancelRequested = false
    func requestCancel() { cancelRequested = true }
    func clearCancel() { cancelRequested = false }

    // MARK: - Probe

    struct Device {
        var identity: Tunnel.Identity
        var capabilities: Tunnel.Capabilities
        var sensors: Tunnel.Sensors
    }

    func probe() throws -> Device {
        let t = Tunnel()
        try t.open()
        defer { t.close() }
        return Device(identity: try t.inquiry(),
                      capabilities: try t.capabilities(),
                      sensors: (try? t.readSensors())
                        ?? .init(raw: 0, paperInFeeder: false, cardInserted: false))
    }

    // MARK: - Geometry

    struct Geometry {
        var dpi: Int
        var widthPx: Int
        var heightPx: Int
        var components: Int
        var bytesPerLine: Int { widthPx * components }
        var totalBytes: Int { bytesPerLine * heightPx }
        var widthUnits: UInt32
        var lengthUnits: UInt32
    }

    private func geometry(for settings: ScanSettings,
                          caps: Tunnel.Capabilities) -> Geometry {
        let dpi = settings.resolution.effective
        let (mmW, mmH) = settings.pageSize.millimetres
        let maxW = caps.maxWidthInches > 0 ? caps.maxWidthInches : 8.5
        let maxH = caps.maxLengthInches > 0 ? caps.maxLengthInches : 14.0
        let inW = min(mmW / 25.4, maxW)
        let inH = min(mmH / 25.4, maxH)

        // Round the pixel width down to the hardware's modulus BEFORE turning
        // it back into 1/1200-inch units, or the scanner returns short lines
        // and every row is skewed.
        var widthPx = Int(inW * Double(dpi))
        widthPx -= widthPx % ScanEngine.pixelsPerLineModulus
        let heightPx = Int(inH * Double(dpi))

        let unitsPerPixel = ScanEngine.unitsPerInch / Double(dpi)
        return Geometry(
            dpi: dpi,
            widthPx: widthPx,
            heightPx: heightPx,
            components: settings.colorMode.wireMode == .color ? 3 : 1,
            widthUnits: UInt32(Double(widthPx) * unitsPerPixel),
            lengthUnits: UInt32(Double(heightPx) * unitsPerPixel))
    }

    // MARK: - Byte helpers

    private func put16(_ b: inout [UInt8], _ o: Int, _ v: UInt16) {
        b[o] = UInt8(truncatingIfNeeded: v >> 8); b[o + 1] = UInt8(truncatingIfNeeded: v)
    }
    private func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
        b[o]     = UInt8(truncatingIfNeeded: v >> 24)
        b[o + 1] = UInt8(truncatingIfNeeded: v >> 16)
        b[o + 2] = UInt8(truncatingIfNeeded: v >> 8)
        b[o + 3] = UInt8(truncatingIfNeeded: v)
    }

    // MARK: - Setup commands

    /// Vendor SET SCAN MODE, buffer page. Must precede SET WINDOW, and byte 6
    /// bit 1 tells the scanner whether two windows are coming. Get this wrong
    /// and the two-window SCAN is rejected with a parameter-list-length error.
    private func setScanMode(_ t: Tunnel, duplex: Bool) throws {
        var payload = [UInt8](repeating: 0, count: 20)
        payload[0x01] = 0x13        // payload head length, P-215 family only
        payload[0x04] = 0x32        // page code: buffer
        payload[0x05] = 0x0E        // page length
        payload[0x06] = duplex ? 0x02 : 0x00
        try t.execute([0xD6, 0x10, 0x00, 0x00, 0x14, 0x00], dataOut: payload)
    }

    private func windowDescriptor(id: UInt8, settings: ScanSettings,
                                  geom: Geometry) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: ScanEngine.descLen)
        d[0x00] = id
        put16(&d, 0x02, UInt16(geom.dpi))
        put16(&d, 0x04, UInt16(geom.dpi))
        put32(&d, 0x06, 0)                       // upper-left X
        // invert_tly: this model wants the ones-complement of the top edge.
        put32(&d, 0x0A, ~UInt32(0))
        put32(&d, 0x0E, geom.widthUnits)
        put32(&d, 0x12, geom.lengthUnits)
        d[0x16] = 0x80                           // brightness, neutral
        d[0x17] = UInt8(max(1, min(254, settings.threshold * 255)))
        d[0x18] = 0x80                           // contrast, neutral
        d[0x19] = geom.components == 3 ? 0x05 : 0x02   // composition
        d[0x1A] = 0x08                           // bits per component, not per pixel
        d[0x1D] = 0x10
        d[0x20] = 0x00                           // no compression
        d[0x2A] = 0x88                           // model-specific constant
        return d
    }

    /// Duplex is expressed as the *same* 52-byte payload sent twice, the second
    /// time with the window id set to 1 -- not as one payload holding two
    /// descriptors. Sending a 96-byte payload earns a parameter-list-length
    /// error.
    private func setWindow(_ t: Tunnel, settings: ScanSettings,
                           geom: Geometry, duplex: Bool) throws {
        for id: UInt8 in (duplex ? [0, 1] : [0]) {
            var payload = [UInt8](repeating: 0, count: ScanEngine.headerLen)
            payload[6] = UInt8(truncatingIfNeeded: ScanEngine.descLen >> 8)
            payload[7] = UInt8(truncatingIfNeeded: ScanEngine.descLen)
            payload += windowDescriptor(id: id, settings: settings, geom: geom)

            let n = payload.count
            try t.execute([0x24, 0, 0, 0, 0, 0,
                           UInt8(truncatingIfNeeded: n >> 16),
                           UInt8(truncatingIfNeeded: n >> 8),
                           UInt8(truncatingIfNeeded: n), 0],
                          dataOut: payload)
        }
    }

    // MARK: - Coarse calibration

    /// Analogue front-end settings. Gain and offset are per-side scalars;
    /// only exposure is per-channel.
    private struct AFE {
        var gain: [Int] = [1, 1]                       // front, back
        var offset: [Int] = [1, 1]
        var exposure: [[Int]] = [[0, 0, 0], [0, 0, 0]]

        func payload() -> [UInt8] {
            var p = [UInt8](repeating: 0, count: 0x28)
            func clamp(_ v: Int) -> UInt8 { UInt8(max(0, min(255, v))) }
            func be16(_ o: Int, _ v: Int) {
                let x = UInt16(max(0, min(0xFFFF, v)))
                p[o] = UInt8(truncatingIfNeeded: x >> 8)
                p[o + 1] = UInt8(truncatingIfNeeded: x)
            }
            for side in 0..<2 {
                let base = side == 0 ? 0x00 : 0x14
                p[base] = clamp(gain[side]); p[base + 1] = p[base]; p[base + 2] = p[base]
                p[base + 4] = clamp(offset[side])
                p[base + 5] = p[base + 4]; p[base + 6] = p[base + 4]
                be16(base + 0x08, exposure[side][0])
                be16(base + 0x0A, exposure[side][1])
                be16(base + 0x0C, exposure[side][2])
            }
            return p
        }
    }

    private func writeAFE(_ t: Tunnel, _ afe: AFE) throws {
        try t.execute([0xE1, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x28, 0x00],
                      dataOut: afe.payload())
    }

    /// A calibration scan: no paper is fed, the sensor reads its internal
    /// reference. `code` 0xFF = lamp off, 0xFE = lamp on.
    private func calibrationScan(_ t: Tunnel, code: UInt8, bytes: Int,
                                 rearm: () throws -> Void) throws -> [UInt8] {
        try rearm()
        try t.execute([0x1B, 0x00, 0x00, 0x00, 0x02, 0x00], dataOut: [code, code])
        FileHandle.standardError.write(Data("    [cal scan 0x\(String(code, radix: 16)) started]\n".utf8))
        var out: [UInt8] = []
        var idle = 0
        while out.count < bytes {
            let want = min(bytes - out.count, 1_500_000)
            let cdb: [UInt8] = [0x28, 0x00, 0x00, 0x00, 0x00, 0x00,
                                UInt8(truncatingIfNeeded: want >> 16),
                                UInt8(truncatingIfNeeded: want >> 8),
                                UInt8(truncatingIfNeeded: want), 0x00]
            let r = try t.executeRaw(cdb, inLength: want)
            if r.status == 0 { out += r.data; idle = 0; continue }
            guard let s = r.sense else { break }
            if s.key == 0x02 { idle += 1; if idle > 100 { break }; usleep(20_000); continue }
            if s.key == 0x00 {
                let valid = max(0, want - Int(s.info))
                if valid > 0 { out += r.data.prefix(valid) }
                break
            }
            break
        }

        // Close the scan session explicitly. Reading past the end just blocks
        // on a doorbell that never rings, and leaving it open makes the next
        // SCAN fail with a command sequence error.
        FileHandle.standardError.write(Data("    [cal scan read \(out.count) bytes, cancelling]\n".utf8))
        _ = try? t.execute([0xD8, 0x00, 0x00, 0x00, 0x00, 0x00])
        FileHandle.standardError.write(Data("    [cancelled]\n".utf8))

        return out
    }

    /// Program the analogue front end. Without this the P-215 returns a pale,
    /// colour-cast image -- it has no self-calibration.
    struct CalibrationResult {
        var gain: Int
        var offset: Int
        var exposure: [Int]
        var blackMin: Int
        var whiteMax: Int
        var samples: Int
        var summary: String {
            String(format: "gain=%d offset=%d exposure=[%d,%d,%d] blackMin=%d whiteMax=%d bytes=%d",
                   gain, offset, exposure[0], exposure[1], exposure[2],
                   blackMin, whiteMax, samples)
        }
    }

    @discardableResult
    func calibrate(_ t: Tunnel, settings: ScanSettings,
                   caps: Tunnel.Capabilities,
                   onStatus: (String) -> Void) throws -> CalibrationResult {
        // Calibration always runs in colour and duplex, 8 lines, whatever the
        // user asked for.
        var calSettings = settings
        calSettings.colorMode = .color
        calSettings.side = .duplex
        var geom = geometry(for: calSettings, caps: caps)
        geom.heightPx = 8
        let unitsPerPixel = ScanEngine.unitsPerInch / Double(geom.dpi)
        geom.lengthUnits = UInt32(8.0 * unitsPerPixel)

        // Calibration always runs duplex, so the scan mode must say so.
        let rearm = { [self] in
            try setScanMode(t, duplex: true)
            try setWindow(t, settings: calSettings, geom: geom, duplex: true)
        }
        try rearm()
        let totalBytes = geom.bytesPerLine * geom.heightPx * 2   // both sides
        var afe = AFE()
        var blackMin = -1, whiteMax = -1, samples = 0

        // Pass 1 -- black level, lamp off.
        onStatus("Calibrating (black level)…")
        afe.gain = [1, 1]; afe.offset = [1, 1]
        afe.exposure = [[0, 0, 0], [0, 0, 0]]
        try writeAFE(t, afe)
        var data = try calibrationScan(t, code: 0xFF, bytes: totalBytes, rearm: rearm)
        if !data.isEmpty {
            let lines = data.count / max(geom.bytesPerLine, 1)
            let px = ScanEngine.deinterlaceColorFront(data, width: geom.widthPx,
                                                      height: lines)
            let minimum = Int(px.min() ?? 0)
            blackMin = minimum
            samples = data.count
            let off = max(0, minimum * 3 - 2)
            afe.offset = [off, off]
        }

        // Pass 2 -- per-channel exposure, deliberately overexposed.
        onStatus("Calibrating (exposure)…")
        afe.exposure = [[0x320, 0x320, 0x320], [0x320, 0x320, 0x320]]
        try writeAFE(t, afe)
        data = try calibrationScan(t, code: 0xFE, bytes: totalBytes, rearm: rearm)
        if !data.isEmpty {
            let lines = data.count / max(geom.bytesPerLine, 1)
            let px = ScanEngine.deinterlaceColorFront(data, width: geom.widthPx,
                                                      height: lines)
            for channel in 0..<3 {
                var maxV = 0
                var i = channel
                while i < px.count { maxV = max(maxV, Int(px[i])); i += 3 }
                if maxV > 0 {
                    let e = 0x320 * 102 / maxV
                    afe.exposure[0][channel] = max(1, e)
                    afe.exposure[1][channel] = max(1, e)
                }
            }
        }

        // Pass 3 -- gain.
        onStatus("Calibrating (gain)…")
        try writeAFE(t, afe)
        data = try calibrationScan(t, code: 0xFE, bytes: totalBytes, rearm: rearm)
        if !data.isEmpty {
            let lines = data.count / max(geom.bytesPerLine, 1)
            let px = ScanEngine.deinterlaceColorFront(data, width: geom.widthPx,
                                                      height: lines)
            let maxV = Int(px.max() ?? 0)
            whiteMax = maxV
            let g = max(1, (250 - maxV) * 4 / 5)
            afe.gain = [g, g]
        }

        // Commit.
        try writeAFE(t, afe)
        return CalibrationResult(gain: afe.gain[0], offset: afe.offset[0],
                                 exposure: afe.exposure[0], blackMin: blackMin,
                                 whiteMax: whiteMax, samples: samples)
    }

    private func feedSheet(_ t: Tunnel) throws {
        try t.execute([0x31, 0x01, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    private func ejectSheet(_ t: Tunnel) {
        _ = try? t.execute([0x31, 0x00, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    private func startScan(_ t: Tunnel, windows: [UInt8]) throws {
        try t.execute([0x1B, 0x00, 0x00, 0x00, UInt8(windows.count), 0x00],
                      dataOut: windows)
    }

    // MARK: - Image read

    /// Pull one page's worth of bytes. Returns nil when the feeder is empty.
    private func readImage(_ t: Tunnel, geom: Geometry,
                           onProgress: (Int, Int) -> Void) throws -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(geom.totalBytes)

        // Ask in whole lines, comfortably inside the 2 MiB data-in window.
        let linesPerRead = max(1, (1_500_000 / max(geom.bytesPerLine, 1)))
        let chunk = linesPerRead * geom.bytesPerLine

        var idleRetries = 0
        while out.count < geom.totalBytes {
            if cancelRequested { throw Failure.cancelled }
            let want = min(chunk, geom.totalBytes - out.count)
            let cdb: [UInt8] = [0x28, 0x00, 0x00, 0x00, 0x00, 0x00,
                                UInt8(truncatingIfNeeded: want >> 16),
                                UInt8(truncatingIfNeeded: want >> 8),
                                UInt8(truncatingIfNeeded: want),
                                0x00]

            let r = try t.executeRaw(cdb, inLength: want)

            if r.status == 0 {
                out += r.data
                idleRetries = 0
                onProgress(out.count, geom.totalBytes)
                continue
            }

            guard let s = r.sense else { break }

            // Key 2 (NOT READY) simply means "nothing yet, ask again".
            if s.key == 0x02 {
                idleRetries += 1
                if idleRetries > 200 { break }
                usleep(50_000)
                continue
            }

            // Key 0 with ILI set is the normal end of a page: the INFORMATION
            // field carries the residue, i.e. how much of the request was NOT
            // filled.
            if s.key == 0x00 {
                let residue = Int(s.info)
                let valid = max(0, want - residue)
                if valid > 0 { out += r.data.prefix(valid) }
                break
            }

            // Hopper empty / no medium: the batch is over.
            if s.key == 0x08 || s.asc == 0x3A || (s.asc == 0x80 && s.ascq == 0x02) {
                return out.isEmpty ? nil : out
            }
            throw Tunnel.Failure.checkCondition(key: s.key, asc: s.asc,
                                                ascq: s.ascq, info: s.info)
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - De-interlacing

    /// Front colour arrives as `rRgGbB`: three separate colour planes per line,
    /// each `width` bytes, and each plane is stored right-to-left.
    static func deinterlaceColorFront(_ src: [UInt8], width: Int, height: Int) -> [UInt8] {
        let bpl = width * 3
        var out = [UInt8](repeating: 0xFF, count: bpl * height)
        src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in
                for y in 0..<height {
                    let line = y * bpl
                    guard line + bpl <= s.count else { break }
                    for c in 0..<3 {
                        let plane = line + c * width
                        for k in 0..<width {
                            d[line + k * 3 + c] = s[plane + (width - 1 - k)]
                        }
                    }
                }
            }
        }
        return out
    }

    /// Back colour arrives as plain sequential planes, left-to-right.
    static func deinterlaceColorBack(_ src: [UInt8], width: Int, height: Int) -> [UInt8] {
        let bpl = width * 3
        var out = [UInt8](repeating: 0xFF, count: bpl * height)
        src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in
                for y in 0..<height {
                    let line = y * bpl
                    guard line + bpl <= s.count else { break }
                    for c in 0..<3 {
                        let plane = line + c * width
                        for k in 0..<width { d[line + k * 3 + c] = s[plane + k] }
                    }
                }
            }
        }
        return out
    }

    /// Front greyscale: one plane per line, stored right-to-left.
    static func deinterlaceGrayFront(_ src: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0xFF, count: width * height)
        src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in
                for y in 0..<height {
                    let line = y * width
                    guard line + width <= s.count else { break }
                    for k in 0..<width { d[line + k] = s[line + (width - 1 - k)] }
                }
            }
        }
        return out
    }

    // MARK: - Bitmap assembly

    static func makeImage(from bytes: [UInt8], width: Int, height: Int,
                          components: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let needed = width * height * components
        var buf = bytes
        if buf.count < needed { buf += [UInt8](repeating: 0xFF, count: needed - buf.count) }
        if buf.count > needed { buf.removeSubrange(needed..<buf.count) }

        let space = components == 1 ? CGColorSpaceCreateDeviceGray()
                                    : CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 8 * components,
                       bytesPerRow: width * components,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Batch

    func scanBatch(settings: ScanSettings,
                   onPage: @Sendable @escaping (ScannedPage) -> Void,
                   onStatus: @Sendable @escaping (String) -> Void) async throws -> Int {
        cancelRequested = false

        let t = Tunnel()
        try t.open()
        defer { t.close() }

        let caps = try t.capabilities()
        let geom = geometry(for: settings, caps: caps)

        onStatus("Preparing…")
        try t.testUnitReady()
        guard try t.readSensors().paperInFeeder else { throw Failure.noPaper }

        let duplex = settings.side != .simplex

        // The P-215 has no self-calibration; without this the image comes out
        // pale and colour-cast. Calibration reprograms the scan mode and
        // window, so it has to run before the real ones are set.
        if settings.calibrate {
            try calibrate(t, settings: settings, caps: caps, onStatus: onStatus)
        }

        try setScanMode(t, duplex: duplex)
        try setWindow(t, settings: settings, geom: geom, duplex: duplex)

        var produced = 0
        var sheet = 0

        while true {
            if cancelRequested { break }
            if let s = try? t.readSensors(), !s.paperInFeeder, sheet > 0 { break }

            onStatus("Feeding sheet \(sheet + 1)…")
            do { try feedSheet(t) } catch { break }
            _ = try? t.testUnitReady()

            let windows: [UInt8] = duplex ? [0, 1] : [0]
            do { try startScan(t, windows: windows) } catch { break }

            onStatus("Scanning sheet \(sheet + 1)…")
            let sidesExpected = duplex ? 2 : 1
            var gotAny = false

            for sideIndex in 0..<sidesExpected {
                guard let raw = try readImage(t, geom: geom, onProgress: { got, total in
                    let pct = Int(Double(got) / Double(max(total, 1)) * 100)
                    onStatus("Scanning sheet \(sheet + 1)… \(pct)%")
                }) else { break }
                gotAny = true

                let side: ScannedPage.Side = sideIndex == 0 ? .front : .back
                let pixels: [UInt8]
                if geom.components == 3 {
                    pixels = side == .front
                        ? ScanEngine.deinterlaceColorFront(raw, width: geom.widthPx,
                                                           height: geom.heightPx)
                        : ScanEngine.deinterlaceColorBack(raw, width: geom.widthPx,
                                                          height: geom.heightPx)
                } else {
                    pixels = side == .front
                        ? ScanEngine.deinterlaceGrayFront(raw, width: geom.widthPx,
                                                          height: geom.heightPx)
                        : raw
                }

                guard let cg = ScanEngine.makeImage(from: pixels, width: geom.widthPx,
                                                    height: geom.heightPx,
                                                    components: geom.components)
                else { continue }

                let page = ScannedPage(original: cg, dpi: geom.dpi, side: side)
                page.inkCoverage = ImagePipeline.shared.inkCoverage(cg)

                // Flagged, not discarded -- see SaneBackend for the reasoning.
                page.isBlank = settings.skipBlankPages
                    && page.inkCoverage < settings.blankThreshold
                if settings.rotateToText, page.inkCoverage > 0.001 {
                    page.adjustments.rotation = Orientation.detect(cg)
                }
                if settings.deskew != .off {
                    let angle = ImagePipeline.shared.estimateSkew(cg)
                    if abs(angle) > 0.2 { page.adjustments.straighten = angle }
                }
                if settings.pageSize == .auto,
                   let bounds = ImagePipeline.shared.contentBounds(cg) {
                    page.adjustments.crop = bounds
                }
                onPage(page)
                produced += 1
            }

            if !gotAny { break }
            sheet += 1
        }

        ejectSheet(t)
        return produced
    }
}
