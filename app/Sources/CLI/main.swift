import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Headless harness for the scanning engine. Kept out of the .app target so the
// same code can be exercised from a terminal, where removable-volume access is
// already granted and no GUI consent prompt gets in the way.
//
//   p215cli probe                 identify the scanner and read its sensors
//   p215cli raw <hex cdb> [len]   send one SCSI command
//   p215cli scan [out.pdf]        run a batch and export
//   p215cli export <img>... out.pdf   exercise the export/OCR path only

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func hex(_ bytes: [UInt8], limit: Int = 64) -> String {
    bytes.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
}

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print("""
    usage:
      p215cli probe
      p215cli raw <hex-cdb> [in-length]
      p215cli scan [output.pdf]
      p215cli export <image>... <output.pdf>
    """)
    exit(0)
}

switch command {

case "probe":
    let t = Tunnel()
    do {
        try t.open()
        defer { t.close() }
        let id = try t.inquiry()
        print("model      : \(id.vendor) \(id.product)")
        print("revision   : \(id.revision)")
        print("firmware   : \(id.firmware)")
        print("peripheral : 0x\(String(id.peripheralType, radix: 16)) "
              + "(\(id.peripheralType == 6 ? "scanner" : "other"))")
        let caps = try t.capabilities()
        print("max dpi    : \(caps.maxXres) x \(caps.maxYres)")
        print(String(format: "max area   : %d x %d px  (%.2f x %.2f in)",
                     caps.maxWidthPx, caps.maxLengthPx,
                     caps.maxWidthInches, caps.maxLengthInches))
        try t.testUnitReady()
        print("unit ready : yes")
        let s = try t.readSensors()
        print("sensors    : 0x\(String(s.raw, radix: 16)) "
              + "paper=\(s.paperInFeeder) card=\(s.cardInserted)")
    } catch { fail("probe failed: \(describeCLI(error))") }

case "raw":
    guard args.count >= 2 else { fail("usage: p215cli raw <hex-cdb> [in-length]") }
    let bytes = args[1]
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: ",", with: "")
    var cdb: [UInt8] = []
    var i = bytes.startIndex
    while i < bytes.endIndex, bytes.index(i, offsetBy: 2, limitedBy: bytes.endIndex) != nil {
        let j = bytes.index(i, offsetBy: 2)
        guard let b = UInt8(bytes[i..<j], radix: 16) else { fail("bad hex: \(bytes[i..<j])") }
        cdb.append(b)
        i = j
    }
    let inLen = args.count > 2 ? Int(args[2]) ?? 0 : 0
    var dataOut: [UInt8]? = nil
    if args.count > 3 {
        let spec = args[3]
        if spec.hasPrefix("zeros:") {
            dataOut = [UInt8](repeating: 0, count: Int(spec.dropFirst(6)) ?? 0)
        } else {
            let h = spec.replacingOccurrences(of: " ", with: "")
            var out: [UInt8] = []
            var k = h.startIndex
            while k < h.endIndex, h.index(k, offsetBy: 2, limitedBy: h.endIndex) != nil {
                let e = h.index(k, offsetBy: 2)
                guard let b = UInt8(h[k..<e], radix: 16) else { fail("bad hex") }
                out.append(b); k = e
            }
            dataOut = out
        }
    }
    let t = Tunnel()
    do {
        try t.open()
        defer { t.close() }
        let r = try t.executeRaw(cdb, inLength: inLen, dataOut: dataOut)
        print("status : 0x\(String(r.status, radix: 16))")
        if let s = r.sense {
            print(String(format: "sense  : key=0x%x asc=0x%02x ascq=0x%02x info=%d",
                         s.key, s.asc, s.ascq, s.info))
        }
        if !r.data.isEmpty, r.status == 0 {
            print("data   : \(hex(r.data, limit: 256))")
        }
    } catch { fail("command failed: \(describeCLI(error))") }

case "scan":
    let out = args.count > 1 ? args[1] : NSHomeDirectory() + "/Desktop/scan.pdf"
    let engine = ScanEngine()
    let sem = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable { var pages: [ScannedPage] = [] }
    let box = Box()

    Task {
        var settings = ScanSettings()
        settings.resolution = .dpi300
        settings.colorMode = .color
        settings.side = .simplex
        do {
            let n = try await engine.scanBatch(
                settings: settings,
                onPage: { p in box.pages.append(p); print("  page \(box.pages.count) "
                    + "\(Int(p.pixelSize.width))x\(Int(p.pixelSize.height)) "
                    + String(format: "ink=%.3f%%", p.inkCoverage * 100)) },
                onStatus: { print("  \($0)") })
            print("captured \(n) page(s)")

            if !box.pages.isEmpty {
                var o = OutputSettings()
                o.format = .pdf
                o.destination = URL(fileURLWithPath: out).deletingLastPathComponent()
                o.baseName = URL(fileURLWithPath: out).deletingPathExtension().lastPathComponent
                o.dateStyle = .none
                o.addCounter = false
                let r = try await Exporter.export(pages: box.pages, settings: o)
                print("saved: \(r.files.map(\.path).joined(separator: ", "))")
            }
        } catch { print("scan failed: \(describeCLI(error))") }
        sem.signal()
    }
    sem.wait()

case "export":
    guard args.count >= 3 else { fail("usage: p215cli export <image>... <output.pdf>") }
    let inputs = args[1..<(args.count - 1)].map { URL(fileURLWithPath: $0) }
    let outURL = URL(fileURLWithPath: args[args.count - 1])

    var pages: [ScannedPage] = []
    for url in inputs {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            fail("could not read \(url.lastPathComponent)")
        }
        let p = ScannedPage(original: cg, dpi: 300)
        p.inkCoverage = ImagePipeline.shared.inkCoverage(cg)
        pages.append(p)
        print("loaded \(url.lastPathComponent): \(cg.width)x\(cg.height) "
              + String(format: "ink=%.2f%%", p.inkCoverage * 100))
    }

    var o = OutputSettings()
    o.format = .pdf
    o.ocrEnabled = true
    o.ocrLanguage = .english
    o.destination = outURL.deletingLastPathComponent()
    o.baseName = outURL.deletingPathExtension().lastPathComponent
    o.dateStyle = .none
    o.addCounter = false

    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let r = try await Exporter.export(pages: pages, settings: o,
                                              progress: { f, m in
                print(String(format: "  %3.0f%% %@", f * 100, m))
            })
            print("saved: \(r.files.map(\.path).joined(separator: ", "))")
        } catch { print("export failed: \(describeCLI(error))") }
        sem.signal()
    }
    sem.wait()

case "cal":
    let engine = ScanEngine()
    let sem = DispatchSemaphore(value: 0)
    Task {
        let t = Tunnel()
        do {
            try t.open()
            defer { t.close() }
            t.timeout = 12
            let caps = try t.capabilities()
            var st = ScanSettings()
            st.resolution = .dpi300
            let r = try await engine.calibrate(t, settings: st, caps: caps,
                                               onStatus: { print("  \($0)") })
            print(r.summary)
        } catch { print("calibration failed: \(describeCLI(error))") }
        sem.signal()
    }
    sem.wait()

case "diag":
    // One paper cycle, maximum information: scan the same sheet raw (no crop,
    // no deskew, no blank skip) and report exactly what the hardware returned.
    let outDir = args.count > 1 ? args[1] : NSTemporaryDirectory() + "p215diag"
    try? FileManager.default.createDirectory(atPath: outDir,
                                             withIntermediateDirectories: true)
    let exe = "/opt/homebrew/bin/scanimage"
    let dev = "canon_dr:libusb:002:004"
    let pattern = outDir + "/raw-%03d.tif"
    for f in (try? FileManager.default.contentsOfDirectory(atPath: outDir)) ?? [] {
        try? FileManager.default.removeItem(atPath: outDir + "/" + f)
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: exe)
    proc.arguments = ["-d", dev, "--source", "ADF Duplex", "--mode", "Color",
                      "--resolution", "300", "--format", "tiff",
                      "--batch=" + pattern]
    let errPipe = Pipe(); proc.standardError = errPipe; proc.standardOutput = Pipe()
    print("running: scanimage --source 'ADF Duplex' --mode Color --resolution 300 (NO swcrop, NO swdeskew)")
    try? proc.run()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    print(String(decoding: errData, as: UTF8.self)
            .split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: outDir)) ?? [])
        .filter { $0.hasSuffix(".tif") }.sorted()
    print("files: \(files.count)")
    for f in files {
        let u = URL(fileURLWithPath: outDir + "/" + f)
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
        let ink = ImagePipeline.shared.inkCoverage(cg)
        let ang = Orientation.detect(cg)
        let bounds = ImagePipeline.shared.contentBounds(cg)
        print(String(format: "  %@  %dx%d px (%.2f x %.2f in @300dpi)  ink=%.3f%%  orient=%d",
                     f, cg.width, cg.height,
                     Double(cg.width)/300.0, Double(cg.height)/300.0, ink * 100, ang))
        if let b = bounds {
            print(String(format: "      content bounds: x=%.3f y=%.3f w=%.3f h=%.3f",
                         b.minX, b.minY, b.width, b.height))
        }
        // Save a viewable PNG.
        let png = URL(fileURLWithPath: outDir + "/" + f.replacingOccurrences(of: ".tif", with: ".png"))
        if let d = CGImageDestinationCreateWithURL(png as CFURL,
                        UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
        }
    }
    print("output: \(outDir)")

case "sane":
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let b = SaneBackend()
            let d = try await b.discover()
            print("device  : \(d.name)")
            print("model   : \(d.model)")
            print("options : \(d.options.count)")
            print("source  : \(d.values(for: "--source"))")
            print("mode    : \(d.values(for: "--mode"))")
            print("res     : \(d.values(for: "--resolution"))")
        } catch { print("sane discover failed: \(describeCLI(error))") }
        sem.signal()
    }
    sem.wait()

case "sane-scan":
    let out = args.count > 1 ? args[1] : NSHomeDirectory() + "/Desktop/sane-scan.pdf"
    let sem = DispatchSemaphore(value: 0)
    final class B: @unchecked Sendable { var pages: [ScannedPage] = [] }
    let box = B()
    Task {
        do {
            var st = ScanSettings()
            st.resolution = .dpi300
            st.colorMode = .color
            st.side = .duplex
            let b = SaneBackend()
            let n = try await b.scanBatch(settings: st,
                onPage: { p in
                    box.pages.append(p)
                    print("  page \(box.pages.count): \(Int(p.pixelSize.width))x\(Int(p.pixelSize.height)) "
                          + String(format: "ink=%.2f%%", p.inkCoverage * 100)) },
                onStatus: { print("  \($0)") })
            print("delivered \(n) file(s), kept \(box.pages.count) page(s)")
            if !box.pages.isEmpty {
                var o = OutputSettings()
                o.format = .pdf
                o.destination = URL(fileURLWithPath: out).deletingLastPathComponent()
                o.baseName = URL(fileURLWithPath: out).deletingPathExtension().lastPathComponent
                o.dateStyle = .none; o.addCounter = false
                let r = try await Exporter.export(pages: box.pages, settings: o)
                print("saved: \(r.files.map(\.path).joined(separator: ", "))")
            }
        } catch { print("scan failed: \(describeCLI(error))") }
        sem.signal()
    }
    sem.wait()

case "hist":
    guard args.count >= 2 else { fail("usage: p215cli hist <image>") }
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("cannot read") }
    print("size: \(cg.width)x\(cg.height)")
    // Full resolution -- no downsampling, so thin text is not averaged away.
    guard let (rgb, w, h) = ImagePipeline.shared.rgbBytes(cg, maxPixel: max(cg.width, cg.height))
    else { fail("cannot rasterise") }
    var hist = [Int](repeating: 0, count: 256)
    var mn = 255, mx = 0
    for i in stride(from: 0, to: rgb.count, by: 3) {
        let v = (Int(rgb[i]) * 299 + Int(rgb[i+1]) * 587 + Int(rgb[i+2]) * 114) / 1000
        hist[v] += 1; mn = min(mn, v); mx = max(mx, v)
    }
    let n = w * h
    print("luma min=\(mn) max=\(mx)")
    var acc = 0
    for pct in [0.001, 0.01, 0.05, 0.1, 0.5, 0.9, 0.99] {
        acc = 0
        let target = Int(Double(n) * pct)
        for v in 0..<256 { acc += hist[v]; if acc >= target { print(String(format: "  p%-6.3f = %d", pct, v)); break } }
    }
    let darkFrac = hist[0..<64].reduce(0,+)
    print(String(format: "pixels below 64 (true black-ish): %.3f%%", Double(darkFrac) / Double(n) * 100))

case "orient":
    guard args.count >= 2 else { fail("usage: p215cli orient <image> [out.png]") }
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("cannot read") }
    let angle = Orientation.detect(cg)
    print("detected rotation: \(angle) degrees")
    if args.count > 2, let fixed = Orientation.rotate(cg, degrees: angle) {
        let out = URL(fileURLWithPath: args[2])
        if let dest = CGImageDestinationCreateWithURL(out as CFURL,
                        UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, fixed, nil)
            CGImageDestinationFinalize(dest)
            print("wrote \(out.lastPathComponent)")
        }
    }

case "levels":
    guard args.count >= 2 else { fail("usage: p215cli levels <image>") }
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("cannot read") }
    for mp in [200, 400, 800, 1000, 2000] {
        let v = ImagePipeline.shared.inkCoverage(cg, maxPixel: mp)
        print(String(format: "  ink@%-5d = %.4f%%", mp, v * 100))
    }
    if let l = ImagePipeline.shared.levels(cg) {
        print(String(format: "levels: lo=%.0f hi=%.0f  (ink at lo maps to black)", l.lo, l.hi))
    } else { print("levels: nil (no stretch applied)") }
    if let (rgb, w, h) = ImagePipeline.shared.rgbBytes(cg, maxPixel: 200) {
        var mn = [255, 255, 255], mx = [0, 0, 0], sum = [0, 0, 0]
        for i in stride(from: 0, to: rgb.count, by: 3) {
            for c in 0..<3 {
                let v = Int(rgb[i + c])
                mn[c] = min(mn[c], v); mx[c] = max(mx[c], v); sum[c] += v
            }
        }
        let n = w * h
        print("min = \(mn)  max = \(mx)  mean = \(sum.map { $0 / max(n,1) })")
    }

case "ocr":
    guard args.count >= 2 else { fail("usage: p215cli ocr <image>") }
    let url = URL(fileURLWithPath: args[1])
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("cannot read image") }
    let sem = DispatchSemaphore(value: 0)
    Task {
        let res = await Exporter.recognise([cg], language: .english)
        let boxes = res[0] ?? []
        print("observations: \(boxes.count)")
        for b in boxes.prefix(12) {
            print(String(format: "  [%.3f,%.3f %.3fx%.3f] %@",
                         b.box.minX, b.box.minY, b.box.width, b.box.height, b.text))
        }
        sem.signal()
    }
    sem.wait()

default:
    fail("unknown command: \(command)")
}

func describeCLI(_ error: Error) -> String {
    switch error {
    case let e as Tunnel.Failure: return e.description
    case let e as ScanEngine.Failure: return e.description
    case let e as SaneBackend.Failure: return e.description
    case let e as Exporter.Failure: return e.description
    default: return error.localizedDescription
    }
}
