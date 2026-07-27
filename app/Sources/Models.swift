import Foundation
import CoreGraphics

// MARK: - Scan settings

enum ColorMode: String, CaseIterable, Codable, Identifiable {
    case autoDetect, color, colorPhoto, gray, grayPhoto, blackWhite
    case errorDiffusion, textEnhancement

    var id: String { rawValue }

    var label: String {
        switch self {
        case .autoDetect:      return "Detect automatically"
        case .color:           return "24-bit Colour"
        case .colorPhoto:      return "24-bit Colour (photo)"
        case .gray:            return "Greyscale"
        case .grayPhoto:       return "Greyscale (photo)"
        case .blackWhite:      return "Black and White"
        case .errorDiffusion:  return "Error Diffusion"
        case .textEnhancement: return "Advanced Text Enhancement"
        }
    }

    /// What the hardware is actually asked to produce.
    var wireMode: WireMode {
        switch self {
        case .color, .colorPhoto, .autoDetect: return .color
        case .gray, .grayPhoto:                return .gray
        case .blackWhite, .errorDiffusion, .textEnhancement: return .gray
        }
    }

    /// Binarisation applied in software after capture, if any.
    var binarize: Binarize {
        switch self {
        case .blackWhite:      return .threshold
        case .errorDiffusion:  return .errorDiffusion
        case .textEnhancement: return .adaptive
        default:               return .none
        }
    }

    enum WireMode { case color, gray }
    enum Binarize { case none, threshold, errorDiffusion, adaptive }
}

enum PageSize: String, CaseIterable, Codable, Identifiable {
    case auto, a4, a5, a5r, a6, a6r, b5, b6, b6r, legal, letter, max
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:   return "Match original size"
        case .a4:     return "A4"
        case .a5:     return "A5"
        case .a5r:    return "A5R"
        case .a6:     return "A6"
        case .a6r:    return "A6R"
        case .b5:     return "B5"
        case .b6:     return "B6"
        case .b6r:    return "B6R"
        case .legal:  return "Legal"
        case .letter: return "Letter"
        case .max:    return "Scanner's maximum"
        }
    }

    /// Width and height in millimetres. `auto` reports the scanner maximum and
    /// is cropped down in software afterwards.
    var millimetres: (w: Double, h: Double) {
        switch self {
        case .a4:     return (210, 297)
        case .a5:     return (148, 210)
        case .a5r:    return (210, 148)
        case .a6:     return (105, 148)
        case .a6r:    return (148, 105)
        case .b5:     return (182, 257)
        case .b6:     return (128, 182)
        case .b6r:    return (182, 128)
        case .legal:  return (215.9, 355.6)
        case .letter: return (215.9, 279.4)
        case .auto, .max: return (215.9, 355.6)
        }
    }
}

enum Resolution: Int, CaseIterable, Codable, Identifiable {
    case auto = 0, dpi150 = 150, dpi200 = 200, dpi300 = 300, dpi400 = 400, dpi600 = 600
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .auto:   return "Detect automatically"
        case .dpi150: return "150 dpi (speed priority)"
        case .dpi200: return "200 dpi"
        case .dpi300: return "300 dpi"
        case .dpi400: return "400 dpi"
        case .dpi600: return "600 dpi (quality priority)"
        }
    }

    /// Effective dpi actually sent to the hardware.
    var effective: Int { self == .auto ? 300 : rawValue }
}

enum ScanSide: String, CaseIterable, Codable, Identifiable {
    case simplex, duplex
    var id: String { rawValue }
    var label: String {
        switch self {
        case .simplex: return "Simplex"
        case .duplex:  return "Duplex"
        }
    }
}

enum DeskewMode: String, CaseIterable, Codable, Identifiable {
    case off, paperEdge, contents
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off:       return "Off"
        case .paperEdge: return "Straighten by document edge"
        case .contents:  return "Straighten by edge and contents"
        }
    }
}

struct ScanSettings: Codable, Equatable {
    var colorMode: ColorMode = .color
    var resolution: Resolution = .dpi300
    var pageSize: PageSize = .auto
    var side: ScanSide = .duplex
    var skipBlankPages = true
    var deskew: DeskewMode = .paperEdge
    /// Detect which way up each page is and rotate it. On by default: a
    /// sheet-fed scanner has no idea which way the paper went in.
    var rotateToText = true
    var brightness: Double = 0      // -1 ... 1
    var contrast: Double = 0        // -1 ... 1
    var threshold: Double = 0.5     // 0 ... 1, used by binarisation

    /// Blank-page detection sensitivity: a page whose ink coverage is below
    /// this fraction is treated as blank. A sheet with nothing but a short
    /// handwritten note measures about 0.04% once the paper edge is excluded,
    /// while a genuinely empty side measures 0.00%. The cutoff sits between
    /// them, biased hard toward keeping: deleting a page is one click, but a
    /// page wrongly hidden means feeding the sheet again.
    var blankThreshold: Double = 0.0001

    /// Run coarse calibration of the analogue front end before a batch.
    ///
    /// Off by default, deliberately. The three-pass routine SANE's canon_dr
    /// uses (COR CAL 0xe1 + internal reference scans) is implemented in
    /// ScanEngine, but on this unit the second pass leaves the firmware waiting
    /// for data it never delivers, which wedges the USB storage endpoint until
    /// the scanner is unplugged. Until that is understood, tone is corrected in
    /// software instead -- see PageAdjustments.autoLevel.
    var calibrate = false
}

// MARK: - Output settings

enum FileFormat: String, CaseIterable, Codable, Identifiable {
    case pdf, tiff, jpeg, png
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .tiff: return "tif"
        case .jpeg: return "jpg"
        case .png: return "png"
        }
    }
    var supportsMultipage: Bool { self == .pdf || self == .tiff }
}

enum MultipageMode: String, CaseIterable, Codable, Identifiable {
    case single, perPage, everyN
    var id: String { rawValue }
    var label: String {
        switch self {
        case .single:  return "Save all pages as one file"
        case .perPage: return "One file per page"
        case .everyN:  return "One file per N pages"
        }
    }
}

enum CompressionMode: String, CaseIterable, Codable, Identifiable {
    case standard, high
    var id: String { rawValue }
    var label: String { self == .standard ? "Standard" : "High compression" }
}

enum DateFormatStyle: String, CaseIterable, Codable, Identifiable {
    case none, yyyymmdd, mmddyyyy, ddmmyyyy
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none:     return "None"
        case .yyyymmdd: return "YYYYMMDD"
        case .mmddyyyy: return "MMDDYYYY"
        case .ddmmyyyy: return "DDMMYYYY"
        }
    }
    func string(from d: Date) -> String {
        guard self != .none else { return "" }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        let (y, m, dd) = (c.year ?? 0, c.month ?? 0, c.day ?? 0)
        switch self {
        case .none:     return ""
        case .yyyymmdd: return String(format: "%04d%02d%02d", y, m, dd)
        case .mmddyyyy: return String(format: "%02d%02d%04d", m, dd, y)
        case .ddmmyyyy: return String(format: "%02d%02d%04d", dd, m, y)
        }
    }
}

/// OCR languages, mapped to the BCP-47 tags Vision expects.
enum OCRLanguage: String, CaseIterable, Codable, Identifiable {
    case english, spanish, french, german, italian, dutch, portuguese
    case russian, turkish, chineseSimplified, chineseTraditional, japanese, korean
    case japaneseEnglish

    var id: String { rawValue }

    var label: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .dutch: return "Dutch"
        case .portuguese: return "Portuguese"
        case .russian: return "Russian"
        case .turkish: return "Turkish"
        case .chineseSimplified: return "Simplified Chinese"
        case .chineseTraditional: return "Traditional Chinese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .japaneseEnglish: return "Japanese and English"
        }
    }

    var visionTag: String {
        switch self {
        case .english: return "en-US"
        case .spanish: return "es-ES"
        case .french: return "fr-FR"
        case .german: return "de-DE"
        case .italian: return "it-IT"
        case .dutch: return "nl-NL"
        case .portuguese: return "pt-BR"
        case .russian: return "ru-RU"
        case .turkish: return "tr-TR"
        case .chineseSimplified: return "zh-Hans"
        case .chineseTraditional: return "zh-Hant"
        case .japanese: return "ja-JP"
        case .korean: return "ko-KR"
        case .japaneseEnglish: return "ja-JP"
        }
    }

    /// Vision accepts an ordered list; mixed-script documents need more than one.
    var visionTags: [String] {
        self == .japaneseEnglish ? ["ja-JP", "en-US"] : [visionTag]
    }
}

struct OutputSettings: Codable, Equatable {
    var format: FileFormat = .pdf
    /// Backing store; always read through `multipage`, which refuses to report
    /// a multi-page mode for a format that cannot hold more than one page.
    var multipageRaw: MultipageMode = .single
    var multipage: MultipageMode {
        get { format.supportsMultipage ? multipageRaw : .perPage }
        set { multipageRaw = newValue }
    }
    var pagesPerFile: Int = 2
    var pdfA = false
    var compression: CompressionMode = .standard
    /// 1 = best quality ... 5 = smallest file
    var compressionRate: Int = 3
    var ocrEnabled = false
    var ocrLanguage: OCRLanguage = .english

    var baseName = "Scan"
    var dateStyle: DateFormatStyle = .yyyymmdd
    var addTime = false
    var addCounter = true
    var counterDigits = 3
    var counterStart = 1

    var destination: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory())

    /// JPEG quality derived from the compression controls.
    var jpegQuality: Double {
        let base: Double = compression == .high ? 0.55 : 0.85
        // rate 1 favours quality, 5 favours size
        let adjust = Double(3 - compressionRate) * 0.08
        return min(0.95, max(0.25, base + adjust))
    }

    func fileName(index: Int, at date: Date = Date()) -> String {
        var parts: [String] = []
        if !baseName.isEmpty { parts.append(baseName) }
        let d = dateStyle.string(from: date)
        if !d.isEmpty { parts.append(d) }
        if addTime {
            let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
            parts.append(String(format: "%02d%02d%02d",
                                c.hour ?? 0, c.minute ?? 0, c.second ?? 0))
        }
        if addCounter {
            let n = counterStart + index
            parts.append(String(format: "%0\(max(1, counterDigits))d", n))
        }
        var name = parts.isEmpty ? "Scan" : parts.joined(separator: "_")
        name = OutputSettings.sanitise(name)
        return name.isEmpty ? "Scan" : name
    }

    /// Characters that are illegal in a filename, plus the leading dot that
    /// would quietly produce a hidden file.
    static func sanitise(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}")
        var s = raw.components(separatedBy: illegal).joined(separator: "-")
        while s.hasPrefix(".") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Why the current settings cannot produce a usable name, if they cannot.
    var nameProblem: String? {
        if baseName != OutputSettings.sanitise(baseName) {
            return "The name contains characters that are not allowed."
        }
        let hasText = !OutputSettings.sanitise(baseName).isEmpty
        if !hasText && dateStyle == .none && !addTime {
            return "Add a name, a date or a time — a counter alone is not a filename."
        }
        return nil
    }
}

// MARK: - Presets

struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var scan: ScanSettings
    var output: OutputSettings
    var builtIn = false
    /// Run as a one-click job: scan, then save straight to the output folder
    /// with no dialog. This is CaptureOnTouch's "Scanning Shortcut" without the
    /// panel machinery, and it is the difference between three steps and one.
    var autoSave = false

    static let builtIns: [Preset] = {
        var text = ScanSettings()
        text.colorMode = .textEnhancement
        text.resolution = .dpi300
        text.skipBlankPages = true

        var photo = ScanSettings()
        photo.colorMode = .colorPhoto
        photo.resolution = .dpi600
        photo.deskew = .off
        photo.skipBlankPages = false

        var auto = ScanSettings()
        auto.colorMode = .autoDetect
        auto.resolution = .auto

        var bw = ScanSettings()
        bw.colorMode = .blackWhite
        bw.resolution = .dpi300

        var colour = ScanSettings()
        colour.colorMode = .color
        colour.resolution = .dpi300

        var pdfOut = OutputSettings()
        var jpegOut = OutputSettings(); jpegOut.format = .jpeg; jpegOut.multipage = .perPage

        return [
            Preset(name: "Text",        scan: text,   output: pdfOut,  builtIn: true),
            Preset(name: "Photo",       scan: photo,  output: jpegOut, builtIn: true),
            Preset(name: "Full auto",   scan: auto,   output: pdfOut,  builtIn: true),
            Preset(name: "Black and White", scan: bw, output: pdfOut,  builtIn: true),
            Preset(name: "Colour",      scan: colour, output: pdfOut,  builtIn: true),
        ]
    }()
}

// MARK: - Pages

/// A single captured side. `original` is never mutated; edits are recorded as
/// adjustments and re-applied, so "revert to original" is always available.
struct PageAdjustments: Codable, Equatable {
    var rotation: Int = 0            // degrees, multiples of 90
    var straighten: Double = 0       // degrees, -10 ... 10
    var brightness: Double = 0       // -1 ... 1
    var contrast: Double = 0         // -1 ... 1
    var grayscale = false
    var blackWhite = false
    /// Stretch each colour channel to its own black/white point. The scanner's
    /// analogue front end is left at its power-on state, so raw captures are
    /// pale and slightly colour-cast; this is what makes them look right.
    var autoLevel = true
    /// Normalised crop rectangle in unit space (0...1), origin top-left.
    var crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// True when nothing but the default auto-level is in play.
    var isIdentity: Bool {
        var reference = PageAdjustments()
        reference.autoLevel = autoLevel
        return self == reference
    }
}

@Observable
final class ScannedPage: Identifiable {
    let id = UUID()
    /// Full-resolution capture as it came off the scanner.
    let original: CGImage
    let dpi: Int
    /// Which side of the sheet this came from, for duplex batches.
    let side: Side
    var adjustments = PageAdjustments()
    var isSelected = false
    /// Ink coverage 0...1, used for blank-page detection and reporting.
    var inkCoverage: Double = 0
    /// Looks blank. Such pages are hidden from the grid and excluded from
    /// export by default, but never thrown away.
    var isBlank = false
    /// Luminance black/white points, computed once from the raw capture.
    var cachedLevels: (lo: Double, hi: Double)?

    enum Side: String, Codable { case front, back }

    init(original: CGImage, dpi: Int, side: Side = .front) {
        self.original = original
        self.dpi = dpi
        self.side = side
    }

    var pixelSize: CGSize {
        CGSize(width: original.width, height: original.height)
    }
}
