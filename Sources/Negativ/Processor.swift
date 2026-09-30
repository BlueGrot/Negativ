import Foundation
import CoreGraphics

/// Per-channel input range mapped to 0…1 before tone adjustments.
struct Levels: Equatable {
    var lo: SIMD3<Float>
    var hi: SIMD3<Float>
    /// Linear light below which a pixel is treated as unlit (outside the film).
    var floor: Float = 0

    var array: [Float] { [lo.x, lo.y, lo.z, hi.x, hi.y, hi.z, floor] }
    init(lo: SIMD3<Float>, hi: SIMD3<Float>, floor: Float = 0) {
        self.lo = lo
        self.hi = hi
        self.floor = floor
    }
    init?(array a: [Float]?) {
        guard let a, a.count == 7 else { return nil }
        self.init(lo: SIMD3(a[0], a[1], a[2]), hi: SIMD3(a[3], a[4], a[5]), floor: a[6])
    }
}

struct Histogram {
    var r: [Float], g: [Float], b: [Float]
}

struct ToneParams {
    var mode: FilmMode
    var base: SIMD3<Float>
    var floor: Float
    var lo: SIMD3<Float>
    var invRange: SIMD3<Float>
    var offset: SIMD3<Float>
    var contrast: Float
    var black: Float
    var invWB: Float
    var highlights: Float
    var shadows: Float
    var invGamma: Float
    var curve: Float
    var saturation: Float

    static let wbScale: Float = 0.1

    init(settings s: EditSettings, levels: Levels) {
        mode = s.mode
        base = Processor.baseVector(s)
        floor = levels.floor
        lo = levels.lo
        invRange = 1 / pointwiseMax(levels.hi - levels.lo, SIMD3(repeating: 0.02))
        let e = Float(s.exposure) * 0.2
        let t = Float(s.temperature) * Self.wbScale, n = Float(s.tint) * Self.wbScale
        offset = SIMD3(e + t, e - n, e - t)
        contrast = Float(s.contrast)
        // Right lifts the blacks (as in other editors): the black point moves down.
        black = -Float(s.blacks) * 0.25
        invWB = 1 / max(0.05, (1 - Float(s.whites) * 0.25) - black)
        highlights = Float(s.highlights)
        shadows = Float(s.shadows)
        invGamma = 1 / powf(2, Float(s.midtones))
        curve = Float(s.curve)
        saturation = Float(s.saturation)
    }
}

enum Processor {
    static let luma = SIMD3<Float>(0.2126, 0.7152, 0.0722)
    static let zero = SIMD3<Float>(repeating: 0)
    static let one = SIMD3<Float>(repeating: 1)

    static func baseVector(_ s: EditSettings) -> SIMD3<Float> {
        guard let b = s.filmBase, b.count == 3 else { return one }
        return pointwiseMax(SIMD3(b[0], b[1], b[2]), SIMD3(repeating: 1e-4))
    }

    @inline(__always) static func srgbEncode(_ x: Float) -> Float {
        let c = max(x, 0)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055
    }

    /// Value before levels: density for negatives, display-encoded for slides.
    @inline(__always) static func raw(_ c: SIMD3<Float>, _ mode: FilmMode, _ base: SIMD3<Float>, floor: Float = 0) -> SIMD3<Float> {
        // Unlit areas (holder mask) would otherwise read as absurd densities and render as coloured noise.
        let c = mode == .positive ? c : pointwiseMax(c, SIMD3(repeating: floor))
        switch mode {
        case .colorNegative:
            let t = pointwiseMax(c / base, SIMD3(repeating: 1e-5))
            return SIMD3(-log10f(t.x), -log10f(t.y), -log10f(t.z))
        case .bwNegative:
            let l = max((c * luma).sum() / (base * luma).sum(), 1e-5)
            return SIMD3(repeating: -log10f(l))
        case .positive:
            return SIMD3(srgbEncode(c.x), srgbEncode(c.y), srgbEncode(c.z))
        }
    }

    /// Levels-normalised value, before user tone controls.
    @inline(__always) static func normalised(_ r: SIMD3<Float>, _ p: ToneParams) -> SIMD3<Float> {
        (r - p.lo) * p.invRange
    }

    @inline(__always) static func tone(_ r: SIMD3<Float>, _ p: ToneParams) -> SIMD3<Float> {
        var v = normalised(r, p) + p.offset
        v = 0.5 + (v - 0.5) * p.contrast
        v = (v - p.black) * p.invWB
        // Highlights / shadows: reshape the ends of the range, reaching past white and black too,
        // so clipped highlights and crushed shadows can be brought back (or pushed further).
        // Highlights act from the midtones up to 0.25 past white, shadows from the midtones
        // down to 0.25 past black; the other end and the middle are left alone.
        if p.highlights != 0 {
            let t = ((v - 0.5) / 0.75).clamped(lowerBound: zero, upperBound: one)
            v += p.highlights * 0.3 * t * t
        }
        if p.shadows != 0 {
            let t = ((0.5 - v) / 0.75).clamped(lowerBound: zero, upperBound: one)
            v += p.shadows * 0.3 * t * t
        }
        v = v.clamped(lowerBound: zero, upperBound: one)
        if p.invGamma != 1 { v = SIMD3(powf(v.x, p.invGamma), powf(v.y, p.invGamma), powf(v.z, p.invGamma)) }
        if p.curve != 0 {
            let s = v * v * (3 - 2 * v)
            v += (s - v) * p.curve
        }
        if p.saturation != 1 {
            let l = (v * luma).sum()
            v = (l + (v - l) * p.saturation).clamped(lowerBound: zero, upperBound: one)
        }
        return v
    }

    @inline(__always) static func pixel(_ src: UnsafePointer<Float>, _ p: ToneParams, negative: Bool) -> SIMD3<Float> {
        let c = SIMD3(src[0], src[1], src[2])
        if negative {
            return SIMD3(min(srgbEncode(c.x), 1), min(srgbEncode(c.y), 1), min(srgbEncode(c.z), 1))
        }
        return tone(raw(c, p.mode, p.base, floor: p.floor), p)
    }

    // MARK: Analysis

    /// Auto levels from the cropped region: per-channel percentiles of the density,
    /// ignoring unlit areas outside the film (black holder masks, unlit borders).
    static func analyze(_ img: LinearImage, settings: EditSettings) -> Levels {
        if let locked = Levels(array: settings.fixedLevels) { return locked }
        let base = baseVector(settings)
        let W = img.width, H = img.height

        // Reference: the clearest film or bare backlight anywhere in the frame.
        let refStep = max(1, Int((Double(W * H) / 100_000).squareRoot()))
        var lums: [Float] = []
        img.pixels.withUnsafeBufferPointer { px in
            for y in stride(from: 0, to: H, by: refStep) {
                for x in stride(from: 0, to: W, by: refStep) {
                    let i = (y * W + x) * 4
                    lums.append((SIMD3(px[i], px[i + 1], px[i + 2]) * luma).sum())
                }
            }
        }
        lums.sort()
        let ref = max(lums.isEmpty ? 1 : lums[min(lums.count - 1, Int(Double(lums.count) * 0.995))], 1e-6)
        // Film rarely exceeds ~2.4 density over base (8 stops); slides go deeper.
        let unlit = ref * powf(2, settings.mode == .positive ? -12 : -8.5)
        let floor: Float = settings.mode == .positive ? 0 : unlit

        let region = settings.crop.inset(by: 0.03)
        let x0 = max(0, Int(region.x * Double(W))), x1 = min(W, Int((region.x + region.w) * Double(W)))
        let y0 = max(0, Int(region.y * Double(H))), y1 = min(H, Int((region.y + region.h) * Double(H)))
        let area = max(1, (x1 - x0) * (y1 - y0))
        let step = max(1, Int((Double(area) / 300_000).squareRoot()))
        let gw = max(1, (x1 - x0 + step - 1) / step), gh = max(1, (y1 - y0 + step - 1) / step)
        var raws = [SIMD3<Float>](repeating: zero, count: gw * gh)
        var lit = [Bool](repeating: false, count: gw * gh)
        img.pixels.withUnsafeBufferPointer { px in
            for gy in 0..<gh {
                let y = min(y1 - 1, y0 + gy * step)
                for gx in 0..<gw {
                    let x = min(x1 - 1, x0 + gx * step)
                    let i = (y * W + x) * 4
                    let c = SIMD3(px[i], px[i + 1], px[i + 2])
                    lit[gy * gw + gx] = (c * luma).sum() >= unlit
                    raws[gy * gw + gx] = raw(c, settings.mode, base, floor: floor)
                }
            }
        }
        // Erode so the soft transition between mask and film doesn't count either.
        var keep = erode(lit, w: gw, h: gh, r: max(1, max(gw, gh) / 100))
        if keep.lazy.filter({ $0 }).count < gw * gh / 100 { keep = [Bool](repeating: true, count: gw * gh) }

        let bins = 3000
        let rangeLo: Float = -1, rangeHi: Float = 5
        let scale = Float(bins) / (rangeHi - rangeLo)
        var hist = [[Int]](repeating: [Int](repeating: 0, count: bins), count: 3)
        var total = 0
        for (i, r) in raws.enumerated() where keep[i] {
            for c in 0..<3 {
                hist[c][min(bins - 1, max(0, Int((r[c] - rangeLo) * scale)))] += 1
            }
            total += 1
        }
        func percentile(_ h: [Int], _ q: Double) -> Float {
            let target = Int(Double(total) * q)
            var acc = 0
            for (i, n) in h.enumerated() {
                acc += n
                if acc > target { return rangeLo + (Float(i) + 0.5) / scale }
            }
            return rangeHi
        }
        var lo = SIMD3(percentile(hist[0], 0.002), percentile(hist[1], 0.002), percentile(hist[2], 0.002))
        var hi = SIMD3(percentile(hist[0], 0.998), percentile(hist[1], 0.998), percentile(hist[2], 0.998))
        switch settings.mode {
        case .colorNegative, .bwNegative:
            // With a measured base the mask is already divided out, so keep that balance:
            // one black point for all channels, at the densest shadow.
            if settings.filmBase != nil { lo = SIMD3(repeating: max(0, lo.min())) }
        case .positive:
            // Keep the slide's own colour balance: one stretch for all channels.
            lo = SIMD3(repeating: lo.min())
            hi = SIMD3(repeating: hi.max())
        }
        let span = pointwiseMax(hi - lo, SIMD3(repeating: 0.05))
        lo -= span * 0.02
        hi = lo + span * 1.04
        return Levels(lo: lo, hi: hi, floor: floor)
    }

    /// Binary erosion: a cell survives only if every cell within `r` (box) is set.
    static func erode(_ m: [Bool], w: Int, h: Int, r: Int) -> [Bool] {
        func pass(_ src: [Bool], len: Int, lines: Int, _ index: (Int, Int) -> Int) -> [Bool] {
            var out = src
            var prefix = [Int](repeating: 0, count: len + 1)
            for line in 0..<lines {
                for k in 0..<len { prefix[k + 1] = prefix[k] + (src[index(line, k)] ? 0 : 1) }
                for k in 0..<len {
                    out[index(line, k)] = prefix[min(len, k + r + 1)] - prefix[max(0, k - r)] == 0
                }
            }
            return out
        }
        let rows = pass(m, len: w, lines: h) { $0 * w + $1 }
        return pass(rows, len: h, lines: w) { $1 * w + $0 }
    }

    // MARK: Film type

    /// How colourful the film is: colour spread between channels in density, after removing
    /// the constant cast of the base/backlight. B&W film is near zero.
    static func colourfulness(_ img: LinearImage) -> Float {
        let W = img.width, H = img.height
        let step = max(1, Int((Double(W * H) / 60_000).squareRoot()))
        var lums: [Float] = []
        var rg: [Float] = [], bg: [Float] = [], dg: [Float] = []
        img.pixels.withUnsafeBufferPointer { px in
            for y in stride(from: H / 5, to: H * 4 / 5, by: step) {
                for x in stride(from: W / 5, to: W * 4 / 5, by: step) {
                    let i = (y * W + x) * 4
                    let c = pointwiseMax(SIMD3(px[i], px[i + 1], px[i + 2]), SIMD3(repeating: 1e-6))
                    lums.append((c * luma).sum())
                    let d = SIMD3(-log10f(c.x), -log10f(c.y), -log10f(c.z))
                    rg.append(d.x - d.y)
                    bg.append(d.z - d.y)
                    dg.append(d.y)
                }
            }
        }
        guard !lums.isEmpty else { return 0 }
        // Film only: skip the holder mask / unlit areas, and bare backlight (the clearest light,
        // which has its own colour cast).
        let ref = lums.sorted()[Int(Double(lums.count - 1) * 0.995)]
        let keep = lums.indices.filter { lums[$0] > ref * powf(2, -8) && lums[$0] < ref * 0.8 }
        guard keep.count > 100 else { return 0 }
        func median(_ a: [Float]) -> Float { let s = a.sorted(); return s[s.count / 2] }
        let mrg = median(keep.map { rg[$0] }), mbg = median(keep.map { bg[$0] })
        let chroma = keep.map { i -> Float in
            let a = rg[i] - mrg, b = bg[i] - mbg
            return (a * a + b * b).squareRoot()
        }.sorted()
        let d = keep.map { dg[$0] }.sorted()
        let spread = max(0.1, d[d.count * 95 / 100] - d[d.count * 5 / 100])
        return chroma[chroma.count * 9 / 10] / spread
    }

    /// B&W film, judged from a small decode of the scan (not the camera's JPEG preview,
    /// whose colour processing is too noisy for this).
    static func looksMonochrome(_ img: LinearImage) -> Bool { colourfulness(img) < 0.12 }

    // MARK: Rendering

    /// Processes the whole preview buffer to an 8-bit sRGB image and its histogram.
    static func render(_ img: LinearImage, settings: EditSettings, levels: Levels, negative: Bool) -> (CGImage, Histogram)? {
        let w = img.width, h = img.height
        var out = [UInt8](repeating: 255, count: w * h * 4)
        let p = ToneParams(settings: settings, levels: levels)
        img.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                process8(src.baseAddress!, dst.baseAddress!, width: w, height: h, params: p, negative: negative)
            }
        }
        let hist = histogram(out, w: w, h: h, region: settings.crop)
        guard let image = makeCGImage8(out, w: w, h: h) else { return nil }
        return (image, hist)
    }

    static func process8(_ s: UnsafePointer<Float>, _ d: UnsafeMutablePointer<UInt8>, width w: Int, height h: Int,
                         params p: ToneParams, negative: Bool = false) {
        let chunks = max(1, min(h, ProcessInfo.processInfo.activeProcessorCount * 4))
        DispatchQueue.concurrentPerform(iterations: chunks) { ci in
            let r0 = h * ci / chunks, r1 = h * (ci + 1) / chunks
            for i in (r0 * w)..<(r1 * w) {
                let v = pixel(s + i * 4, p, negative: negative) * 255 + 0.5
                d[i * 4] = UInt8(v.x)
                d[i * 4 + 1] = UInt8(v.y)
                d[i * 4 + 2] = UInt8(v.z)
                d[i * 4 + 3] = 255
            }
        }
    }

    /// RGB 16-bit output (3 components per pixel).
    static func process16(_ s: UnsafePointer<Float>, _ d: UnsafeMutablePointer<UInt16>, width w: Int, height h: Int, params p: ToneParams) {
        let chunks = max(1, min(h, ProcessInfo.processInfo.activeProcessorCount * 4))
        DispatchQueue.concurrentPerform(iterations: chunks) { ci in
            let r0 = h * ci / chunks, r1 = h * (ci + 1) / chunks
            for i in (r0 * w)..<(r1 * w) {
                let v = pixel(s + i * 4, p, negative: false) * 65535 + 0.5
                d[i * 3] = UInt16(v.x)
                d[i * 3 + 1] = UInt16(v.y)
                d[i * 3 + 2] = UInt16(v.z)
            }
        }
    }

    /// Histogram of the cropped area only, so the border around the frame doesn't dominate it.
    static func histogram(_ px: [UInt8], w: Int, h: Int, region: NormRect) -> Histogram {
        var r = [Float](repeating: 0, count: 256), g = r, b = r
        let x0 = max(0, Int(region.x * Double(w))), x1 = min(w, Int((region.x + region.w) * Double(w)))
        let y0 = max(0, Int(region.y * Double(h))), y1 = min(h, Int((region.y + region.h) * Double(h)))
        let step = max(1, Int((Double(max(1, (x1 - x0) * (y1 - y0))) / 200_000).squareRoot()))
        for y in stride(from: y0, to: y1, by: step) {
            for x in stride(from: x0, to: x1, by: step) {
                let i = (y * w + x) * 4
                r[Int(px[i])] += 1
                g[Int(px[i + 1])] += 1
                b[Int(px[i + 2])] += 1
            }
        }
        // Normalise ignoring the clipped end bins so they don't flatten the rest.
        let peak = max(1, (r[1...254] + g[1...254] + b[1...254]).max() ?? 1)
        return Histogram(r: r.map { min(1, $0 / peak) }, g: g.map { min(1, $0 / peak) }, b: b.map { min(1, $0 / peak) })
    }

    static func makeCGImage8(_ px: [UInt8], w: Int, h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: Pipeline.srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
