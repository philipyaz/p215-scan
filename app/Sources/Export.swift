import Foundation
import CoreGraphics
import CoreText
import Vision
import ImageIO
import UniformTypeIdentifiers

/// Writes scanned pages out as PDF (optionally searchable), TIFF, JPEG or PNG.
enum Exporter {

    struct Result {
        var files: [URL]
        var pagesWritten: Int
    }

    enum Failure: Error, CustomStringConvertible {
        case noPages
        case encodeFailed
        case writeFailed(URL, String)

        var description: String {
            switch self {
            case .noPages: return "There are no pages to save."
            case .encodeFailed: return "The image could not be encoded."
            case .writeFailed(let u, let m): return "Could not write \(u.lastPathComponent): \(m)"
            }
        }
    }

    // MARK: - Entry point

    static func export(pages: [ScannedPage],
                       settings: OutputSettings,
                       progress: (@Sendable (Double, String) -> Void)? = nil) async throws -> Result {
        guard !pages.isEmpty else { throw Failure.noPages }

        let pipeline = ImagePipeline.shared
        progress?(0.05, "Rendering pages…")
        let rendered: [CGImage] = pages.map { pipeline.render($0) }
        let dpis = pages.map(\.dpi)

        // Group pages into output files.
        let groups: [[Int]]
        switch settings.multipage {
        case .single:
            groups = settings.format.supportsMultipage
                ? [Array(rendered.indices)]
                : rendered.indices.map { [$0] }
        case .perPage:
            groups = rendered.indices.map { [$0] }
        case .everyN:
            let n = max(1, settings.pagesPerFile)
            groups = stride(from: 0, to: rendered.count, by: n).map {
                Array($0..<min($0 + n, rendered.count))
            }
        }

        // OCR up front so progress is meaningful and work is shared.
        var textByPage: [Int: [TextBox]] = [:]
        if settings.ocrEnabled && settings.format == .pdf {
            progress?(0.15, "Recognising text…")
            textByPage = await recognise(rendered,
                                         language: settings.ocrLanguage,
                                         progress: { done, total in
                let f = 0.15 + 0.55 * Double(done) / Double(max(total, 1))
                progress?(f, "Recognising text… \(done)/\(total)")
            })
        }

        var written: [URL] = []
        let date = Date()
        for (gi, group) in groups.enumerated() {
            progress?(0.75 + 0.25 * Double(gi) / Double(max(groups.count, 1)), "Writing files…")
            let name = settings.fileName(index: gi, at: date)
            let url = uniqueURL(in: settings.destination,
                                name: name,
                                ext: settings.format.fileExtension)
            let images = group.map { rendered[$0] }
            let groupDPI = group.map { dpis[$0] }
            let groupText = group.map { textByPage[$0] ?? [] }

            switch settings.format {
            case .pdf:
                try writePDF(images: images, dpis: groupDPI, text: groupText,
                             to: url, settings: settings)
            case .tiff:
                guard let data = images.count == 1
                        ? ImagePipeline.shared.encode(images[0], as: .tiff, quality: 1)
                        : ImagePipeline.shared.encodeMultipageTIFF(images)
                else { throw Failure.encodeFailed }
                try write(data, to: url)
            case .jpeg, .png:
                // Single-image formats get one file per page; grouping cannot
                // silently drop the rest.
                for (n, image) in images.enumerated() {
                    guard let data = ImagePipeline.shared.encode(
                        image, as: settings.format, quality: settings.jpegQuality)
                    else { throw Failure.encodeFailed }
                    let target = n == 0 ? url : uniqueURL(
                        in: settings.destination,
                        name: settings.fileName(index: gi, at: date) + "-\(n + 1)",
                        ext: settings.format.fileExtension)
                    try write(data, to: target)
                    if n > 0 { written.append(target) }
                }
            }
            written.append(url)
        }

        progress?(1.0, "Done")
        return Result(files: written, pagesWritten: rendered.count)
    }

    private static func write(_ data: Data, to url: URL) throws {
        do { try data.write(to: url, options: .atomic) }
        catch { throw Failure.writeFailed(url, error.localizedDescription) }
    }

    static func uniqueURL(in dir: URL, name: String, ext: String) -> URL {
        var candidate = dir.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(name)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: - OCR

    struct TextBox: Sendable {
        var text: String
        /// Normalised, origin bottom-left, exactly as Vision reports it.
        var box: CGRect
    }

    static func recognise(_ images: [CGImage],
                          language: OCRLanguage,
                          progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [Int: [TextBox]] {
        let total = images.count
        var out: [Int: [TextBox]] = [:]
        var done = 0

        // Bounded parallelism: Vision is memory hungry on large scans.
        let limit = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 2))

        await withTaskGroup(of: (Int, [TextBox]).self) { group in
            var next = 0
            func submit(_ i: Int) {
                let image = images[i]
                let tags = language.visionTags
                group.addTask { (i, recogniseOne(image, languageTags: tags)) }
            }
            while next < min(limit, total) { submit(next); next += 1 }
            for await (index, boxes) in group {
                out[index] = boxes
                done += 1
                progress?(done, total)
                if next < total { submit(next); next += 1 }
            }
        }
        return out
    }

    /// Vision silently returns zero observations for images that carry an alpha
    /// channel, so flatten onto white before handing anything over.
    private static func flatten(_ image: CGImage) -> CGImage {
        let alpha = image.alphaInfo
        if alpha == .none || alpha == .noneSkipLast || alpha == .noneSkipFirst {
            return image
        }
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    private static func recogniseOne(_ rawImage: CGImage, languageTags: [String]) -> [TextBox] {
        let image = flatten(rawImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languageTags

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }

        guard let observations = request.results else { return [] }
        return observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return TextBox(text: candidate.string, box: obs.boundingBox)
        }
    }

    // MARK: - PDF

    static func writePDF(images: [CGImage],
                         dpis: [Int],
                         text: [[TextBox]],
                         to url: URL,
                         settings: OutputSettings) throws {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { throw Failure.encodeFailed }

        var info: [String: Any] = [
            kCGPDFContextCreator as String: "P215 Scan",
            kCGPDFContextTitle as String: url.deletingPathExtension().lastPathComponent,
        ]
        if settings.pdfA {
            // Native APIs cannot certify PDF/A; we set the metadata that is in
            // reach and leave full conformance to a dedicated tool.
            info[kCGPDFContextSubject as String] = "Scanned document"
        }

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox,
                                  info as CFDictionary) else { throw Failure.encodeFailed }

        for (i, image) in images.enumerated() {
            let dpi = Double(max(dpis.indices.contains(i) ? dpis[i] : 300, 1))
            let wPt = Double(image.width) * 72.0 / dpi
            let hPt = Double(image.height) * 72.0 / dpi
            let box = CGRect(x: 0, y: 0, width: wPt, height: hPt)

            // CGPDFContext wants the media box as raw CFData holding a CGRect.
            // Passing an NSValue is silently ignored, and every page then comes
            // out at the context's default US Letter size with the image
            // overflowing it.
            var boxVar = box
            let boxData = withUnsafeBytes(of: &boxVar) { Data($0) }
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            // Re-encode as JPEG at the requested quality and hand CoreGraphics
            // a JPEG-backed image: it passes the compressed data straight into
            // the PDF as DCTDecode rather than re-encoding at its own default,
            // which is what makes the quality slider mean something.
            if let jpeg = ImagePipeline.shared.encode(image, as: .jpeg,
                                                      quality: settings.jpegQuality),
               let provider = CGDataProvider(data: jpeg as CFData),
               let compressed = CGImage(jpegDataProviderSource: provider, decode: nil,
                                        shouldInterpolate: true, intent: .defaultIntent) {
                ctx.draw(compressed, in: box)
            } else {
                ctx.draw(image, in: box)
            }

            if text.indices.contains(i), !text[i].isEmpty {
                drawInvisibleText(text[i], in: ctx, pageSize: CGSize(width: wPt, height: hPt))
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        try write(data as Data, to: url)
    }

    /// Draw the OCR result as invisible, selectable text on top of the page.
    private static func drawInvisibleText(_ boxes: [TextBox],
                                          in ctx: CGContext,
                                          pageSize: CGSize) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)

        for item in boxes where !item.text.isEmpty {
            // Vision's normalised box already uses a bottom-left origin, which
            // matches PDF user space, so this maps straight across.
            let rect = CGRect(x: item.box.minX * pageSize.width,
                              y: item.box.minY * pageSize.height,
                              width: item.box.width * pageSize.width,
                              height: item.box.height * pageSize.height)
            guard rect.width > 0.5, rect.height > 0.5 else { continue }

            // Pick a font size from the box height, then scale horizontally so
            // the glyph run spans the same width the scanner saw. Without this
            // correction, selection highlights drift away from the ink.
            let fontSize = max(1, rect.height * 0.82)
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attrs: [NSAttributedString.Key: Any] =
                [kCTFontAttributeName as NSAttributedString.Key: font]
            let attributed = NSAttributedString(string: item.text, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attributed)

            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let natural = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            guard natural > 0 else { continue }
            let xScale = rect.width / natural

            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: xScale, y: 1)
            ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + descent * 0.5)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }
}
