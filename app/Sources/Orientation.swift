import Foundation
import CoreGraphics
import Vision

/// Works out which way up a scanned page is, by asking Vision to read it at
/// each of the four rotations and keeping whichever yields the most confident
/// text.
///
/// This is CaptureOnTouch Lite's "Rotate image to match orientation of text".
/// A sheet-fed scanner has no idea which way the paper went in, and the back
/// side of a duplex sheet frequently comes out upside down, so without this a
/// batch ends up with pages at arbitrary rotations.
enum Orientation {

    /// Degrees clockwise the page must be rotated to read correctly: 0, 90,
    /// 180 or 270. Returns 0 when nothing legible is found, so a photo or a
    /// blank sheet is left alone.
    static func detect(_ image: CGImage,
                       languages: [String] = ["en-US"],
                       proxyPixels: Int = 1000) -> Int {
        let proxy = ImagePipeline.shared.downsample(image, maxPixel: proxyPixels) ?? image

        var bestAngle = 0
        var bestScore = 0.0

        for angle in [0, 90, 180, 270] {
            guard let rotated = rotate(proxy, degrees: angle) else { continue }
            let score = legibility(rotated, languages: languages)
            if score > bestScore {
                bestScore = score
                bestAngle = angle
            }
        }

        // Require a real signal; otherwise leave the page as it is.
        return bestScore > 2.0 ? bestAngle : 0
    }

    /// Total recognised characters weighted by confidence. Upside-down text
    /// still produces occasional matches, so weighting by confidence rather
    /// than counting observations is what separates the right rotation from
    /// the others.
    private static func legibility(_ image: CGImage, languages: [String]) -> Double {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.recognitionLanguages = languages

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let results = request.results else { return 0 }

        var score = 0.0
        for observation in results {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let letters = candidate.string.unicodeScalars.filter {
                CharacterSet.letters.contains($0)
            }.count
            score += Double(letters) * Double(candidate.confidence)
        }
        return score
    }

    static func rotate(_ image: CGImage, degrees: Int) -> CGImage? {
        let d = ((degrees % 360) + 360) % 360
        if d == 0 { return image }

        let swap = (d == 90 || d == 270)
        let w = swap ? image.height : image.width
        let h = swap ? image.width : image.height

        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        ctx.translateBy(x: Double(w) / 2, y: Double(h) / 2)
        ctx.rotate(by: -Double(d) * .pi / 180)
        ctx.translateBy(x: -Double(image.width) / 2, y: -Double(image.height) / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0,
                                   width: image.width, height: image.height))
        return ctx.makeImage()
    }
}
