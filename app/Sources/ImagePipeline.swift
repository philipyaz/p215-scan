import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import Accelerate
import UniformTypeIdentifiers

/// Core Image work for page rendering, thumbnails and analysis.
/// A single CIContext is reused for the whole app; creating one per render is
/// the classic cause of "why is this so slow".
final class ImagePipeline: @unchecked Sendable {

    static let shared = ImagePipeline()

    private let context: CIContext
    private let thumbnailCache = NSCache<NSString, CGImage>()
    private let lock = NSLock()

    private init() {
        context = CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
        ])
        thumbnailCache.countLimit = 400
    }

    // MARK: - Rendering

    /// Apply a page's adjustments and return a new CGImage.
    func render(_ page: ScannedPage) -> CGImage {
        let adj = page.adjustments
        if adj.isIdentity && !adj.autoLevel { return page.original }

        var image = CIImage(cgImage: page.original)

        // 0. Auto levels, before anything else changes the histogram.
        if adj.autoLevel {
            if page.cachedLevels == nil { page.cachedLevels = levels(page.original) }
            if let l = page.cachedLevels, let f = CIFilter(name: "CIColorMatrix") {
                let span = max(1.0, l.hi - l.lo)
                let scale = CGFloat(255.0 / span)
                let bias = CGFloat(-l.lo / span)
                f.setValue(image, forKey: kCIInputImageKey)
                f.setValue(CIVector(x: scale, y: 0, z: 0, w: 0), forKey: "inputRVector")
                f.setValue(CIVector(x: 0, y: scale, z: 0, w: 0), forKey: "inputGVector")
                f.setValue(CIVector(x: 0, y: 0, z: scale, w: 0), forKey: "inputBVector")
                f.setValue(CIVector(x: bias, y: bias, z: bias, w: 0),
                           forKey: "inputBiasVector")
                if let out = f.outputImage { image = out }
            }
        }

        // 1. Crop first so later filters do less work.
        if adj.crop != CGRect(x: 0, y: 0, width: 1, height: 1) {
            let e = image.extent
            // Crop rect arrives with a top-left origin; CI uses bottom-left.
            let rect = CGRect(
                x: e.minX + adj.crop.minX * e.width,
                y: e.minY + (1 - adj.crop.maxY) * e.height,
                width: adj.crop.width * e.width,
                height: adj.crop.height * e.height
            ).integral
            image = image.cropped(to: rect)
                         .transformed(by: .init(translationX: -rect.minX, y: -rect.minY))
        }

        // 2. Straighten (fine rotation with resampling).
        if abs(adj.straighten) > 0.001 {
            let radians = -adj.straighten * .pi / 180
            if let f = CIFilter(name: "CIStraightenFilter") {
                f.setValue(image, forKey: kCIInputImageKey)
                f.setValue(radians, forKey: kCIInputAngleKey)
                if let out = f.outputImage { image = out }
            }
        }

        // 3. Tone.
        if adj.brightness != 0 || adj.contrast != 0 || adj.grayscale || adj.blackWhite {
            if let f = CIFilter(name: "CIColorControls") {
                f.setValue(image, forKey: kCIInputImageKey)
                f.setValue(adj.brightness, forKey: kCIInputBrightnessKey)
                f.setValue(1 + adj.contrast, forKey: kCIInputContrastKey)
                f.setValue((adj.grayscale || adj.blackWhite) ? 0.0 : 1.0,
                           forKey: kCIInputSaturationKey)
                if let out = f.outputImage { image = out }
            }
        }

        // 4. Hard black and white.
        if adj.blackWhite {
            let comps: [CGFloat] = [0, 0.5, 1]
            if let f = CIFilter(name: "CIColorPosterize") {
                f.setValue(image, forKey: kCIInputImageKey)
                f.setValue(2, forKey: "inputLevels")
                if let out = f.outputImage { image = out }
            }
            _ = comps
        }

        // 5. Coarse rotation last -- cheap and exact.
        let rot = ((adj.rotation % 360) + 360) % 360
        if rot != 0 {
            let radians = -Double(rot) * .pi / 180
            image = image.transformed(by: CGAffineTransform(rotationAngle: radians))
            image = image.transformed(by: .init(translationX: -image.extent.minX,
                                                y: -image.extent.minY))
        }

        let rect = image.extent.integral
        guard rect.width >= 1, rect.height >= 1,
              let out = context.createCGImage(image, from: rect) else {
            return page.original
        }
        return out
    }

    // MARK: - Thumbnails

    func thumbnail(for page: ScannedPage, maxPixel: Int = 320) -> CGImage? {
        let key = "\(page.id.uuidString)-\(maxPixel)-\(adjustmentKey(page.adjustments))" as NSString
        lock.lock()
        if let hit = thumbnailCache.object(forKey: key) { lock.unlock(); return hit }
        lock.unlock()

        let full = render(page)
        guard let small = downsample(full, maxPixel: maxPixel) else { return full }
        lock.lock(); thumbnailCache.setObject(small, forKey: key); lock.unlock()
        return small
    }

    private func adjustmentKey(_ a: PageAdjustments) -> String {
        "\(a.rotation),\(a.straighten),\(a.brightness),\(a.contrast),"
        + "\(a.grayscale),\(a.blackWhite),\(a.crop.minX),\(a.crop.minY),"
        + "\(a.crop.width),\(a.crop.height)"
    }

    func downsample(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxPixel else { return image }
        let scale = Double(maxPixel) / Double(longest)
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))

        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        // Scanned pages are white; compositing onto white keeps transparent
        // regions from turning black.
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    func invalidateThumbnails(for page: ScannedPage) {
        // Keys embed the adjustment signature, so stale entries simply age out.
        _ = page
    }

    // MARK: - Analysis

    /// Render an image down to an 8-bit greyscale byte buffer.
    /// The buffer must own its storage for the lifetime of the CGContext, so
    /// the allocation is made explicitly rather than passing `&array`, which
    /// would hand CoreGraphics a pointer Swift is free to invalidate.
    func grayBytes(_ image: CGImage, maxPixel: Int) -> (bytes: [UInt8], w: Int, h: Int)? {
        // Scale straight into the greyscale context rather than going through
        // downsample(), so alpha is composited onto white exactly once.
        let longest = max(image.width, image.height)
        let scale = longest > maxPixel ? Double(maxPixel) / Double(longest) : 1
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        let small = image

        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h)
        storage.initialize(repeating: 255, count: w * h)
        defer { storage.deallocate() }

        guard let ctx = CGContext(data: storage, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(small, in: CGRect(x: 0, y: 0, width: w, height: h))

        return (Array(UnsafeBufferPointer(start: storage, count: w * h)), w, h)
    }

    /// Render down to interleaved 8-bit RGB.
    func rgbBytes(_ image: CGImage, maxPixel: Int) -> (bytes: [UInt8], w: Int, h: Int)? {
        let longest = max(image.width, image.height)
        let scale = longest > maxPixel ? Double(maxPixel) / Double(longest) : 1
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))

        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
        storage.initialize(repeating: 255, count: w * h * 4)
        defer { storage.deallocate() }

        guard let ctx = CGContext(data: storage, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var out = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            out[i * 3]     = storage[i * 4]
            out[i * 3 + 1] = storage[i * 4 + 1]
            out[i * 3 + 2] = storage[i * 4 + 2]
        }
        return (out, w, h)
    }

    /// Per-channel black and white points, taken at percentiles so a few dust
    /// specks or a dark edge strip cannot drag the whole range.
    ///
    /// The P-215's analogue front end is not calibrated by this driver, so raw
    /// captures come out pale and slightly colour-cast. Stretching each channel
    /// independently fixes both at once, and is what makes scans look right.
    /// Black and white points for the page, measured on luminance.
    ///
    /// Deliberately a single pair applied to all three channels, not one pair
    /// per channel. Per-channel stretching looks tempting -- it neutralises a
    /// colour cast for free -- but on coloured paper it is destructive: a
    /// yellow sheet has almost no spread in the blue channel, so blue's black
    /// and white points collapse onto each other and the whole page saturates
    /// to pure yellow. Stretching luminance uniformly fixes the lifted black
    /// point this scanner produces while leaving hue intact.
    ///
    /// The white point is taken below the top of the histogram because a scan
    /// carries a bright tail from beyond the paper edge; anchoring on that
    /// leaves the paper grey.
    func levels(_ image: CGImage,
                lowPercentile: Double = 0.0005,
                highPercentile: Double = 0.88) -> (lo: Double, hi: Double)? {
        // Measured at 1000px, not 400: sparse ink -- a few handwritten words on
        // an otherwise empty sheet -- averages into the paper at low
        // resolution and the page looks like it has no dark tone at all.
        guard let (buf, w, h) = rgbBytes(image, maxPixel: 1000), w > 16, h > 16
        else { return nil }

        // Ignore the outer margin; the paper edge leaves a dark band that would
        // anchor the black point on something that is not ink.
        let bx = Int(Double(w) * 0.035), by = Int(Double(h) * 0.035)
        var hist = [Int](repeating: 0, count: 256)
        var counted = 0
        for y in by..<(h - by) {
            for x in bx..<(w - bx) {
                let i = (y * w + x) * 3
                guard i + 2 < buf.count else { continue }
                let luma = (Int(buf[i]) * 299 + Int(buf[i + 1]) * 587
                            + Int(buf[i + 2]) * 114) / 1000
                hist[min(255, max(0, luma))] += 1
                counted += 1
            }
        }
        guard counted > 0 else { return nil }

        func percentile(_ p: Double) -> Int {
            let target = max(1, Int(Double(counted) * p))
            var running = 0
            for v in 0..<256 {
                running += hist[v]
                if running >= target { return v }
            }
            return 255
        }

        let lo = percentile(lowPercentile)
        let hi = percentile(highPercentile)

        // A page with no real tonal range is blank or a solid colour; stretching
        // it only amplifies noise.
        guard hi - lo >= 24 else { return nil }
        return (Double(lo), Double(hi))
    }

    /// Fraction of the page covered in ink.
    ///
    /// Three things matter and each caused a real failure:
    /// - The proxy must stay large. At 200px a page of ordinary text averages
    ///   down to pale grey and reads as blank.
    /// - The outer margin must be ignored. A sheet-fed scanner leaves a dark
    ///   band along the paper edge, which alone reads as ~1.5% ink and makes a
    ///   genuinely blank sheet look printed.
    /// - The cutoff must follow the page's own white point, not a fixed value.
    ///   This scanner's black level drifts, so a fixed cutoff is either blind
    ///   or hallucinates ink depending on exposure.
    func inkCoverage(_ image: CGImage, maxPixel: Int = 1000,
                     borderFraction: Double = 0.035) -> Double {
        guard let (buf, w, h) = grayBytes(image, maxPixel: maxPixel), w > 8, h > 8
        else { return 0 }

        let bx = Int(Double(w) * borderFraction)
        let by = Int(Double(h) * borderFraction)
        let x0 = bx, x1 = w - bx, y0 = by, y1 = h - by
        guard x1 > x0, y1 > y0 else { return 0 }

        // White point: the 90th percentile inside the margin, i.e. the paper.
        var hist = [Int](repeating: 0, count: 256)
        for y in y0..<y1 {
            let row = y * w
            for x in x0..<x1 { hist[Int(buf[row + x])] += 1 }
        }
        let total = (x1 - x0) * (y1 - y0)
        var acc = 0, white = 255
        for v in stride(from: 255, through: 0, by: -1) {
            acc += hist[v]
            if acc >= total / 10 { white = v; break }
        }

        // Ink is anything meaningfully darker than the paper.
        let cutoff = max(24, white - 46)
        var dark = 0
        for v in 0..<cutoff { dark += hist[v] }
        return Double(dark) / Double(total)
    }

    /// Estimate the skew angle of a scanned page in degrees, by finding the
    /// rotation that maximises the variance of the horizontal projection
    /// profile -- text lines line up, so variance peaks when straight.
    func estimateSkew(_ image: CGImage, range: Double = 8, step: Double = 0.25) -> Double {
        guard let (buf, w, h) = grayBytes(image, maxPixel: 600), w > 8, h > 8 else { return 0 }

        // Binarise to ink/no-ink once.
        var ink = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) { ink[i] = buf[i] < 160 ? 1 : 0 }

        var best = 0.0, bestScore = -1.0
        var angle = -range
        while angle <= range {
            let t = tan(angle * .pi / 180)
            var profile = [Double](repeating: 0, count: h)
            for y in 0..<h {
                var sum = 0.0
                let shift = Int(t * Double(y - h / 2))
                for x in stride(from: 0, to: w, by: 2) {
                    let sx = x + shift
                    if sx >= 0 && sx < w { sum += ink[y * w + sx] }
                }
                profile[y] = sum
            }
            let mean = profile.reduce(0, +) / Double(h)
            var variance = 0.0
            for v in profile { let d = v - mean; variance += d * d }
            if variance > bestScore { bestScore = variance; best = angle }
            angle += step
        }
        return best
    }

    /// Find the bounding box of non-white content, as a unit rect with a
    /// top-left origin, padded slightly. Returns nil if the page looks blank.
    func contentBounds(_ image: CGImage, pad: Double = 0.005) -> CGRect? {
        guard let (buf, w, h) = grayBytes(image, maxPixel: 400), w > 4, h > 4 else { return nil }

        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where buf[y * w + x] < 200 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX > minX, maxY > minY else { return nil }

        let rect = CGRect(x: Double(minX) / Double(w) - pad,
                          y: Double(minY) / Double(h) - pad,
                          width: Double(maxX - minX) / Double(w) + 2 * pad,
                          height: Double(maxY - minY) / Double(h) + 2 * pad)
        return rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    // MARK: - Encoding

    func encode(_ image: CGImage, as format: FileFormat, quality: Double) -> Data? {
        let type: UTType
        switch format {
        case .jpeg: type = .jpeg
        case .png:  type = .png
        case .tiff: type = .tiff
        case .pdf:  type = .jpeg      // page images inside a PDF
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Multi-page TIFF.
    func encodeMultipageTIFF(_ images: [CGImage]) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.tiff.identifier as CFString, images.count, nil) else { return nil }
        // 5 = LZW. Uncompressed multi-page TIFFs of 300 dpi colour scans are
        // enormous for no benefit.
        let opts: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]
        ]
        for image in images {
            CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
