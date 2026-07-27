// Renders the app icon: a page mid-scan, the beam separating the crisp
// scanned half from the faint unscanned half. Run via make-icon.sh.
//
// Pure CoreGraphics: renders a 1024 master, then resamples it to every
// .iconset size. usage: swift makeicon.swift <iconset-dir> <docs-png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [r / 255, g / 255, b / 255, a])!
}

func makeContext(_ size: Int) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
              bytesPerRow: 0, space: srgb,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func drawIcon(_ ctx: CGContext) {
    // macOS icon grid: 824 pt squircle centred in the 1024 canvas.
    let squircle = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                          cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.addPath(squircle)
    ctx.clip()

    // Background: indigo falling to near-black navy.
    let bg = CGGradient(colorsSpace: srgb,
                        colors: [rgba(74, 92, 232), rgba(20, 22, 66)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 260, y: 924),
                           end: CGPoint(x: 764, y: 100), options: [])

    // Soft top-light so the slab doesn't look flat.
    let halo = CGGradient(colorsSpace: srgb,
                          colors: [rgba(255, 255, 255, 0.16), rgba(255, 255, 255, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(halo, startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 980), endRadius: 700, options: [])

    let beamY: CGFloat = 470   // icon-space height of the scan beam

    // The page, slightly rotated, with a soft shadow.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 512)
    ctx.rotate(by: -6 * .pi / 180)
    let page = CGRect(x: -230, y: -300, width: 460, height: 600)
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 46, color: rgba(0, 0, 0, 0.45))
    ctx.addPath(CGPath(roundedRect: page, cornerWidth: 26, cornerHeight: 26, transform: nil))
    ctx.setFillColor(rgba(250, 251, 255))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Text lines: crisp where the beam has passed (above), faint where it hasn't.
    let inkDark = rgba(52, 60, 92, 0.88)
    let inkFaint = rgba(52, 60, 92, 0.18)
    var y: CGFloat = page.maxY - 78
    let widths: [CGFloat] = [300, 356, 328, 356, 210, 0, 356, 340, 300, 356, 250, 180]
    for w in widths {
        defer { y -= 46 }
        if w == 0 { continue }                       // paragraph gap
        // approximate icon-space height of this line to pick its side of the beam
        let iconY = 512 + y * cos(6 * .pi / 180)
        ctx.setFillColor(iconY > beamY ? inkDark : inkFaint)
        let line = CGRect(x: page.minX + 52, y: y, width: w, height: 18)
        ctx.addPath(CGPath(roundedRect: line, cornerWidth: 9, cornerHeight: 9, transform: nil))
        ctx.fillPath()
    }
    ctx.restoreGState()

    // The scan beam: a wide glow, a bright inner band, a hot core.
    let glow = CGGradient(colorsSpace: srgb,
                          colors: [rgba(70, 227, 255, 0), rgba(70, 227, 255, 0.5),
                                   rgba(70, 227, 255, 0)] as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 100, y: beamY - 90, width: 824, height: 180))
    ctx.drawLinearGradient(glow, start: CGPoint(x: 0, y: beamY - 90),
                           end: CGPoint(x: 0, y: beamY + 90), options: [])
    ctx.restoreGState()
    ctx.setFillColor(rgba(160, 240, 255, 0.35))
    ctx.fill(CGRect(x: 100, y: beamY - 18, width: 824, height: 36))
    ctx.setFillColor(rgba(225, 252, 255))
    ctx.fill(CGRect(x: 100, y: beamY - 5, width: 824, height: 10))
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("failed to write \(path)") }
}

func resample(_ master: CGImage, to size: Int) -> CGImage {
    let ctx = makeContext(size)
    ctx.interpolationQuality = .high
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

let iconsetDir = CommandLine.arguments[1]
let docsPNG = CommandLine.arguments[2]

let masterCtx = makeContext(1024)
drawIcon(masterCtx)
let master = masterCtx.makeImage()!

for base in [16, 32, 128, 256, 512] {
    writePNG(resample(master, to: base), to: "\(iconsetDir)/icon_\(base)x\(base).png")
    writePNG(base == 512 ? master : resample(master, to: base * 2),
             to: "\(iconsetDir)/icon_\(base)x\(base)@2x.png")
}
writePNG(resample(master, to: 512), to: docsPNG)
print("wrote \(iconsetDir) and \(docsPNG)")
