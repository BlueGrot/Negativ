import Foundation
import CoreGraphics

enum FilmMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case colorNegative, bwNegative, positive
    var id: String { rawValue }
    var label: String {
        switch self {
        case .colorNegative: return "Colour neg"
        case .bwNegative: return "B&W neg"
        case .positive: return "Slide"
        }
    }
}

/// Rectangle in normalised image coordinates, origin top-left.
struct NormRect: Codable, Hashable {
    var x: Double, y: Double, w: Double, h: Double
    static let full = NormRect(x: 0, y: 0, w: 1, h: 1)
    var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }

    func inset(by f: Double) -> NormRect {
        NormRect(x: x + w * f, y: y + h * f, w: w * (1 - 2 * f), h: h * (1 - 2 * f))
    }
    /// Rect after the image is rotated 90° clockwise.
    var rotatedRight: NormRect { NormRect(x: 1 - (y + h), y: x, w: h, h: w) }
    /// Rect after the image is rotated 90° counter-clockwise.
    var rotatedLeft: NormRect { NormRect(x: y, y: 1 - (x + w), w: h, h: w) }
    var flippedH: NormRect { NormRect(x: 1 - x - w, y: y, w: w, h: h) }
}

struct EditSettings: Codable, Hashable {
    var mode: FilmMode = .colorNegative
    // Geometry
    var quarterTurns = 0          // clockwise
    var flipH = false
    var straighten = 0.0          // degrees, positive = clockwise
    var crop = NormRect.full
    // Inversion
    var filmBase: [Float]? = nil  // linear RGB of the unexposed film rebate; nil = auto per frame
    // Tone
    var exposure = 0.0
    var contrast = 1.0
    var blacks = 0.0
    var whites = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var midtones = 0.0
    var curve = 0.3
    // Colour
    var temperature = 0.0
    var tint = 0.0
    var saturation = 1.0
    // Balance
    /// Levels locked from a reference frame (lo RGB, hi RGB, floor), so a whole roll shares one
    /// colour balance. nil = measured per frame.
    var fixedLevels: [Float]? = nil

    init() {}

    init(mode: FilmMode) { self.mode = mode }

    /// Names of the fields that differ, for coalescing undo steps.
    func changedFields(from o: EditSettings) -> Set<String> {
        var f = Set<String>()
        if mode != o.mode { f.insert("mode") }
        if quarterTurns != o.quarterTurns { f.insert("quarterTurns") }
        if flipH != o.flipH { f.insert("flipH") }
        if straighten != o.straighten { f.insert("straighten") }
        if crop != o.crop { f.insert("crop") }
        if filmBase != o.filmBase { f.insert("filmBase") }
        if exposure != o.exposure { f.insert("exposure") }
        if contrast != o.contrast { f.insert("contrast") }
        if blacks != o.blacks { f.insert("blacks") }
        if whites != o.whites { f.insert("whites") }
        if highlights != o.highlights { f.insert("highlights") }
        if shadows != o.shadows { f.insert("shadows") }
        if midtones != o.midtones { f.insert("midtones") }
        if curve != o.curve { f.insert("curve") }
        if temperature != o.temperature { f.insert("temperature") }
        if tint != o.tint { f.insert("tint") }
        if saturation != o.saturation { f.insert("saturation") }
        if fixedLevels != o.fixedLevels { f.insert("fixedLevels") }
        return f
    }

    var geometryKey: String { "\(quarterTurns)|\(flipH)|\(straighten)" }
    var levelsKey: String { "\(geometryKey)|\(mode.rawValue)|\(filmBase ?? [])|\(fixedLevels ?? [])|\(crop.x),\(crop.y),\(crop.w),\(crop.h)" }

    /// Everything except geometry and crop, taken from `o`.
    func pastingAdjustments(from o: EditSettings) -> EditSettings {
        var s = o
        s.quarterTurns = quarterTurns
        s.flipH = flipH
        s.straighten = straighten
        s.crop = crop
        return s
    }

    func rotated(clockwise: Bool) -> EditSettings {
        var s = self
        s.quarterTurns = ((quarterTurns + (clockwise ? 1 : -1)) % 4 + 4) % 4
        s.crop = clockwise ? crop.rotatedRight : crop.rotatedLeft
        return s
    }

    func flipped() -> EditSettings {
        var s = self
        s.flipH.toggle()
        s.crop = crop.flippedH
        return s
    }

    // Tolerant decoding so sidecars survive new fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EditSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        mode = v(.mode, d.mode)
        quarterTurns = v(.quarterTurns, d.quarterTurns)
        flipH = v(.flipH, d.flipH)
        straighten = v(.straighten, d.straighten)
        crop = v(.crop, d.crop)
        filmBase = (try? c.decodeIfPresent([Float].self, forKey: .filmBase)) ?? nil
        exposure = v(.exposure, d.exposure)
        contrast = v(.contrast, d.contrast)
        blacks = v(.blacks, d.blacks)
        whites = v(.whites, d.whites)
        highlights = v(.highlights, d.highlights)
        shadows = v(.shadows, d.shadows)
        midtones = v(.midtones, d.midtones)
        curve = v(.curve, d.curve)
        temperature = v(.temperature, d.temperature)
        tint = v(.tint, d.tint)
        saturation = v(.saturation, d.saturation)
        fixedLevels = (try? c.decodeIfPresent([Float].self, forKey: .fixedLevels)) ?? nil
    }
}

enum CropAspect: String, CaseIterable, Identifiable {
    case free = "Free", original = "Original", r3x2 = "3:2", r4x3 = "4:3 (645)", r5x4 = "5:4",
         r1x1 = "1:1 (6×6)", r7x6 = "7:6 (6×7)", r9x6 = "3:2 (6×9)", xpan = "65:24 (XPan)", r16x9 = "16:9"
    var id: String { rawValue }
    /// Width / height in pixels for a landscape frame.
    func ratio(originalW: Double, originalH: Double) -> Double? {
        switch self {
        case .free: return nil
        case .original: return originalW / originalH
        case .r3x2, .r9x6: return 3.0 / 2.0
        case .r4x3: return 4.0 / 3.0
        case .r5x4: return 5.0 / 4.0
        case .r1x1: return 1
        case .r7x6: return 7.0 / 6.0
        case .xpan: return 65.0 / 24.0
        case .r16x9: return 16.0 / 9.0
        }
    }
}
