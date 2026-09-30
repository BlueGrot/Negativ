import Foundation

/// Finds the exposed image area in a scan.
///
/// Candidate rectangles come from growing regions of "denser than clear" film at a range of
/// thresholds. Each is scored on what a real frame border looks like: the rebate is the least
/// dense part of the film, so density steps *up* into the picture along nearly the whole edge,
/// the band just outside is flat (rebate, gap, holder mask), and the inside holds no bare
/// backlight. Sides may be slightly slanted, since handheld camera scans are rarely square.
enum FrameDetector {
    /// NEG_DEBUG=1 prints candidate boxes and scores.
    static let debug = ProcessInfo.processInfo.environment["NEG_DEBUG"] != nil

    struct Detection {
        /// Crop inside the frame, normalised to the image.
        var rect: NormRect
        /// How far the frame is turned clockwise, in degrees (straighten by the negative).
        var tilt: Double
    }

    /// The frame nearest the middle of the scan, or nil when no clear frame edge is found.
    static func detect(_ img: LinearImage) -> Detection? {
        guard let (grid, cap) = prepare(img) else { return nil }
        // 35 mm strip: its geometry says where the frame is; take the one nearest the middle.
        let strip = grid.stripFrames()
        if let strip, !strip.frames.isEmpty {
            let cx = Double(grid.w) / 2, cy = Double(grid.h) / 2
            let f = strip.frames.min { a, b in
                hypot(Double(a.0 + a.2) / 2 - cx, Double(a.1 + a.3) / 2 - cy) < hypot(Double(b.0 + b.2) / 2 - cx, Double(b.1 + b.3) / 2 - cy)
            }!
            return Detection(rect: grid.normalised(f), tilt: strip.tilt)
        }
        // A strip whose frames couldn't be placed yet (still tilted): report its tilt, so auto
        // crop straightens and looks again, with a rough box across the strip.
        if let strip, abs(strip.tilt) > 0.15 {
            let b = strip.band
            let vertical = b.1 == 0 && b.3 == grid.h
            let r: Grid.Rect = vertical ? (b.0, grid.h / 6, b.2, grid.h * 5 / 6) : (grid.w / 6, b.1, grid.w * 5 / 6, b.3)
            return Detection(rect: grid.normalised(r), tilt: strip.tilt)
        }
        let seeds = grid.seeds(xs: [0.35, 0.5, 0.65], ys: [0.35, 0.5, 0.65])
        var cands = grid.candidates(seeds: seeds, cap: cap, minArea: 1.0 / 25)
        // In a masked holder the frame fills the opening, even where the picture is as thin as
        // clear film (dark shadows), which splits the density-grown regions.
        if let opening = grid.litOpening(), !cands.contains(where: { $0 == opening }) { cands.append(opening) }
        let scored = cands.map(grid.fit)
        if debug {
            print("   opening", grid.litOpening().map { "\($0)" } ?? "nil", "grid", grid.w, grid.h)
            for c in scored where area(c.r) > grid.w * grid.h / 5 {
                print("   cand", c.r, String(format: "s %.3f weakest %.2f", c.s, c.weakest), "holder", c.holder,
                      "maskBeyond", (0..<4).map { String(format: "%.2f", grid.maskBeyond(c.r, $0)) })
            }
        }
        guard var best = scored.max(by: { $0.s < $1.s }), best.s >= 0.3 else { return nil }
        // A holder opening with only picture in it is the frame, however marginal its score
        // against patches of picture. (A real frame inside it still wins below.)
        // The holder mask marks the frame's edges; fitting would only pull them onto picture
        // edges (a roofline against the sky), so the opening is used as found.
        if let lit = grid.litOpening(), grid.isHolderOpening(lit) {
            let f = grid.fit(lit)
            best = (lit, max(f.s, 0.5), f.tilt, max(f.weakest, 0.4), true)
        }
        // A winner with a weak side (e.g. cut at a skyline) is probably part of the picture when
        // a box containing it scores about as well: take the bigger one.
        while best.weakest < 0.4, let outer = scored
            .filter({ $0.s >= best.s - 0.03 && contains($0.r, best.r)
                      && Double(area($0.r)) >= 1.05 * Double(area(best.r))
                      && Double(area($0.r)) <= 1.8 * Double(area(best.r)) }) // the rest of this frame, not a whole strip
            .max(by: { area($0.r) < area($1.r) }) {
            best = outer
        }
        // The rebate always surrounds the frame, and film + rebate against backlight is an even
        // cleaner edge than the frame's own. So a good frame nested inside the winner beats it —
        // if it has four real edges (not, say, the top half of the frame cut at a skyline).
        while let inner = scored
            .filter({ $0.s >= 0.6 && $0.weakest >= 0.4 && contains(best.r, $0.r)
                      && Double(area($0.r)) >= 0.35 * Double(area(best.r))
                      && Double(area($0.r)) <= 0.95 * Double(area(best.r)) })
            .max(by: { $0.s < $1.s }) {
            best = inner
        }
        // A 35 mm frame beside a row of sprocket holes is 1.5× as long as it's wide; if the picture
        // is too thin at one end to be found, lengthen the box from that end.
        best.r = grid.completeSprocketFrame(best.r)
        // Anything this small is a patch of picture, not a frame.
        guard Double(area(best.r)) >= 0.04 * Double(grid.w * grid.h) else { return nil }
        return Detection(rect: grid.normalised(grid.clearOfMask(best.r)), tilt: best.tilt)
    }

    /// Overlap relative to the smaller rect: ~1 when one mostly contains the other.
    static func overlap(_ a: NormRect, _ b: NormRect) -> Double {
        let ix = max(0, min(a.x + a.w, b.x + b.w) - max(a.x, b.x)), iy = max(0, min(a.y + a.h, b.y + b.h) - max(a.y, b.y))
        return ix * iy / max(1e-9, min(a.w * a.h, b.w * b.h))
    }

    /// Inner lies within outer, give or take a couple of percent (fitted edges wobble).
    private static func contains(_ outer: Grid.Rect, _ inner: Grid.Rect) -> Bool {
        let mx = max(2, (outer.2 - outer.0) / 50), my = max(2, (outer.3 - outer.1) / 50)
        return inner.0 >= outer.0 - mx && inner.1 >= outer.1 - my && inner.2 <= outer.2 + mx && inner.3 <= outer.3 + my
    }

    /// Every frame in the scan (e.g. two or three frames of a strip on a light table),
    /// in reading order.
    static func detectAll(_ img: LinearImage) -> [NormRect] {
        guard let (grid, cap) = prepare(img) else { return [] }
        if let strip = grid.stripFrames(), !strip.frames.isEmpty { return strip.frames.map(grid.normalised) }
        let fr = stride(from: 0.1, through: 0.9, by: 0.1).map { $0 }
        let seeds = grid.seeds(xs: fr, ys: [0.2, 0.35, 0.5, 0.65, 0.8])
        var cands: [Grid.Rect] = []
        for c in grid.candidates(seeds: seeds, cap: cap, minArea: 1.0 / 40) where !cands.contains(where: { iou($0, c) > 0.9 }) {
            cands.append(c)
        }
        let scored = cands.map(grid.fit).filter { $0.s >= 0.3 }.sorted { $0.s > $1.s }
        var picked: [Grid.Rect] = []
        for c in scored {
            let overlaps = picked.contains { p in
                let ix = max(0, min(p.2, c.r.2) - max(p.0, c.r.0)), iy = max(0, min(p.3, c.r.3) - max(p.1, c.r.1))
                return Double(ix * iy) > 0.15 * Double(min(area(p), area(c.r)))
            }
            if !overlaps { picked.append(c.r) }
        }
        // Frames on one strip are the same size: drop partial frames cut off by the edge of the
        // scan, and bits of picture that only look like frames.
        let touchesEdge = { (r: Grid.Rect) -> Bool in
            r.0 <= grid.w / 50 || r.2 >= grid.w - grid.w / 50 || r.1 <= grid.h / 50 || r.3 >= grid.h - grid.h / 50
        }
        if picked.contains(where: { !touchesEdge($0) }) { picked.removeAll(where: touchesEdge) }
        let largest = picked.map(area).max() ?? 0
        picked = picked.filter { Double(area($0)) >= 0.5 * Double(largest) }
        // Reading order: rows first (by centre, in bands of a third of the scan), then left to right.
        return picked
            .sorted { a, b in
                let ra = (a.1 + a.3) * 3 / (2 * grid.h), rb = (b.1 + b.3) * 3 / (2 * grid.h)
                return ra != rb ? ra < rb : a.0 < b.0
            }
            .map { grid.normalised(grid.clearOfMask($0)) }
    }

    private static func area(_ r: Grid.Rect) -> Int { (r.2 - r.0) * (r.3 - r.1) }

    private static func iou(_ a: Grid.Rect, _ b: Grid.Rect) -> Double {
        let ix = max(0, min(a.2, b.2) - max(a.0, b.0)), iy = max(0, min(a.3, b.3) - max(a.1, b.1))
        let inter = Double(ix * iy)
        return inter / Double(area(a) + area(b) - ix * iy)
    }

    /// Density grid of the scan, with holder mask and anything far denser than the picture set to clear.
    private static func prepare(_ img: LinearImage) -> (Grid, Float)? {
        let step = max(1, max(img.width, img.height) / 500)
        let gw = img.width / step, gh = img.height / step
        guard gw > 40, gh > 40 else { return nil }

        // Luminance on a coarse grid (box-averaged to beat grain).
        var lum = [Float](repeating: 0, count: gw * gh)
        img.pixels.withUnsafeBufferPointer { px in
            let b = max(1, step / 2)
            for gy in 0..<gh {
                for gx in 0..<gw {
                    var s: Float = 0
                    var n: Float = 0
                    for y in (gy * step)..<min(img.height, gy * step + b) {
                        for x in (gx * step)..<min(img.width, gx * step + b) {
                            let i = (y * img.width + x) * 4
                            s += (SIMD3(px[i], px[i + 1], px[i + 2]) * Processor.luma).sum()
                            n += 1
                        }
                    }
                    lum[gy * gw + gx] = s / max(n, 1)
                }
            }
        }

        // Density relative to the clearest light in the scan. The unlit holder mask counts as
        // clear, so mask → picture reads as an inward step just like rebate → picture.
        let sorted = lum.sorted()
        let ref = max(sorted[Int(Double(sorted.count - 1) * 0.995)], 1e-6)
        let unlit = ref * powf(2, -8.5)
        let d = lum.map { $0 >= unlit ? max(0, log10f(ref / $0)) : 0 }

        // Anything much denser than the picture's own densest area is holder, carrier or the
        // blurred edge of the mask — not film. Treat it like the mask.
        var central: [Float] = []
        for y in stride(from: gh * 3 / 10, to: gh * 7 / 10, by: 2) {
            for x in stride(from: gw * 3 / 10, to: gw * 7 / 10, by: 2) { central.append(d[y * gw + x]) }
        }
        central.sort()
        let cap = central[Int(Double(central.count - 1) * 0.98)] * 1.25 + 0.15
        // For telling the holder apart: film density runs on continuously from the picture into
        // its densest parts (a bright sky); a dimly lit holder sits beyond a gap. Walk up the
        // histogram to that gap, so the sky isn't mistaken for holder.
        var maskCap = cap
        let litD = zip(lum, d).filter { $0.0 >= unlit }.map { $0.1 }
        if !litD.isEmpty {
            let binW: Float = 0.05
            var hist = [Int](repeating: 0, count: 100)
            for v in litD { hist[min(99, Int(v / binW))] += 1 }
            let minCount = max(1, litD.count / 1000)
            var bin = min(99, Int(cap / binW))
            while bin < 99, hist[bin] >= minCount || hist[bin + 1] >= minCount { bin += 1 }
            maskCap = max(cap, Float(bin) * binW + 0.1)
        }
        // Mask: no light at all, or far denser than any film here (a dimly lit holder).
        let mask = zip(lum, d).map { $0.0 < unlit || $0.1 > maskCap }
        // The holder itself: mask connected to the edge of the scan (not bright lamps or a clock
        // face in the picture, which are just as dense on the negative).
        var holder = [Bool](repeating: false, count: mask.count)
        var stack: [Int] = []
        for x in 0..<gw { stack.append(x); stack.append((gh - 1) * gw + x) }
        for y in 0..<gh { stack.append(y * gw); stack.append(y * gw + gw - 1) }
        stack = stack.filter { mask[$0] }
        for i in stack { holder[i] = true }
        while let i = stack.popLast() {
            let x = i % gw, y = i / gw
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < gw, ny >= 0, ny < gh else { continue }
                let j = ny * gw + nx
                if mask[j], !holder[j] { holder[j] = true; stack.append(j) }
            }
        }
        return (Grid(d: d.map { $0 > cap ? 0 : $0 }, unlit: mask, holder: holder, w: gw, h: gh), cap)
    }

    private struct Grid {
        let d: [Float]
        /// Holder mask / no light at all.
        let unlit: [Bool]
        /// The part of the mask connected to the edge of the scan.
        let holder: [Bool]
        let w: Int
        let h: Int

        var band: Int { max(2, max(w, h) / 150) }
        let delta: Float = 0.04

        func seeds(xs: [Double], ys: [Double]) -> [Int] {
            ys.flatMap { fy in xs.map { fx in min(h - 1, Int(fy * Double(h))) * w + min(w - 1, Int(fx * Double(w))) } }
        }

        /// Pulled in slightly so no rebate or soft edge is left along the border.
        func normalised(_ r: Rect) -> NormRect {
            let rw = Double(r.2 - r.0), rh = Double(r.3 - r.1)
            let inset = 0.015
            return NormRect(x: (Double(r.0) + rw * inset) / Double(w),
                            y: (Double(r.1) + rh * inset) / Double(h),
                            w: rw * (1 - 2 * inset) / Double(w),
                            h: rh * (1 - 2 * inset) / Double(h))
        }

        /// Bounding boxes of regions grown from the seeds at a range of density thresholds.
        /// (Several seeds, since one can land on dust or an opaque blob.)
        func candidates(seeds: [Int], cap: Float, minArea: Double) -> [Rect] {
            var out: [Rect] = []
            var tau: Float = 0.04
            while tau < min(cap, 1.6) {
                var seen = [Bool](repeating: false, count: d.count)
                for seed in seeds where !seen[seed] && d[seed] >= tau && d[seed] <= cap {
                    if let r = componentBox(seed: seed, lo: tau, hi: cap, seen: &seen) {
                        let a = Double((r.2 - r.0) * (r.3 - r.1))
                        if a > Double(w * h) * minArea, !out.contains(where: { $0 == r }) { out.append(r) }
                    }
                }
                tau += 0.05
            }
            return out
        }

        /// The largest rect inside `r0` that holds no holder mask, so rounded corners of the
        /// opening (or a mask edge that isn't quite straight) don't show. Each side moves in at
        /// most 1/12 of the frame; if no inset is clean, the one with least mask wins.
        func clearOfMask(_ r0: Rect) -> Rect {
            // Mask grown by a cell (to catch the soft transition), summed for O(1) rect counts.
            var sum = [Int](repeating: 0, count: (w + 1) * (h + 1))
            for y in 0..<h {
                var row = 0
                for x in 0..<w {
                    var m = false
                    for yy in max(0, y - 1)...min(h - 1, y + 1) where !m {
                        for xx in max(0, x - 1)...min(w - 1, x + 1) where holder[yy * w + xx] { m = true; break }
                    }
                    if m { row += 1 }
                    sum[(y + 1) * (w + 1) + x + 1] = sum[y * (w + 1) + x + 1] + row
                }
            }
            func masked(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
                sum[y1 * (w + 1) + x1] - sum[y0 * (w + 1) + x1] - sum[y1 * (w + 1) + x0] + sum[y0 * (w + 1) + x0]
            }
            guard masked(r0.0, r0.1, r0.2, r0.3) > 0 else { return r0 }
            let maxX = max(1, (r0.2 - r0.0) / 12), maxY = max(1, (r0.3 - r0.1) / 12)
            // Each mask cell left in costs as much as 25 cells of picture cut away.
            let full = (r0.2 - r0.0) * (r0.3 - r0.1)
            var best = r0
            var bestCost = masked(r0.0, r0.1, r0.2, r0.3) * 25
            for l in 0...maxX {
                for rr in 0...maxX {
                    for t in 0...maxY {
                        for b in 0...maxY {
                            let c = (r0.0 + l, r0.1 + t, r0.2 - rr, r0.3 - b)
                            let lost = full - (c.2 - c.0) * (c.3 - c.1)
                            if lost >= bestCost { continue }
                            let cost = lost + masked(c.0, c.1, c.2, c.3) * 25
                            if cost < bestCost { bestCost = cost; best = c }
                        }
                    }
                }
            }
            return best
        }

        /// The holder opening: the run of mostly-lit columns and rows around the centre. (Projections
        /// rather than a flood fill, so light spilling past the end of the mask doesn't matter.)
        func litOpening() -> Rect? {
            guard unlit.lazy.filter({ $0 }).count > unlit.count / 10 else { return nil }
            func run(_ lit: [Double]) -> (Int, Int)? {
                let c = lit.count / 2
                guard lit[c] > 0.5 else { return nil }
                var a = c, b = c
                while a > 0, lit[a - 1] > 0.5 { a -= 1 }
                while b < lit.count - 1, lit[b + 1] > 0.5 { b += 1 }
                return (a, b + 1)
            }
            let colLit = (0..<w).map { x in Double((0..<h).filter { !unlit[$0 * w + x] }.count) / Double(h) }
            let rowLit = (0..<h).map { y in Double((0..<w).filter { !unlit[y * w + $0] }.count) / Double(w) }
            guard let (x0, x1) = run(colLit), let (y0, y1) = run(rowLit) else { return nil }
            // Nothing masked off at all: not an opening.
            guard x1 - x0 < w * 97 / 100 || y1 - y0 < h * 97 / 100 else { return nil }
            return (x0, y0, x1, y1)
        }

        /// Bounding box (x0, y0, x1, y1) of the 8-connected region with density in lo…hi around `seed`.
        func componentBox(seed: Int, lo: Float, hi: Float, seen: inout [Bool]) -> (Int, Int, Int, Int)? {
            var stack = [seed]
            seen[seed] = true
            var x0 = w, y0 = h, x1 = 0, y1 = 0
            var count = 0
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                count += 1
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                        let j = ny * w + nx
                        if !seen[j], d[j] >= lo, d[j] <= hi { seen[j] = true; stack.append(j) }
                    }
                }
            }
            guard count > 16 else { return nil }
            return (x0, y0, x1 + 1, y1 + 1)
        }

        typealias Rect = (Int, Int, Int, Int)

        /// How much one side looks like a frame border: the fraction of its length where density
        /// steps up going into the rect, weighted by how flat the band just outside is (rebate,
        /// gap between frames or holder mask are flat; picture content isn't).
        /// The edge may be slanted: it runs from offset `a` at its start to `b` at its end.
        /// side: 0 left, 1 right, 2 top, 3 bottom. Nil when the side has no room outside.
        func sideScore(_ r: Rect, _ side: Int, _ a: Int = 0, _ b: Int = 0) -> Float? {
            sideEvidence(r, side, a, b)?.score
        }

        /// Side score, and the share of the side that has holder mask right outside it.
        func sideEvidence(_ r: Rect, _ side: Int, _ a: Int = 0, _ b: Int = 0) -> (score: Float, mask: Float)? {
            let (x0, y0, x1, y1) = r
            let k = band
            let vertical = side < 2
            let edge = [x0, x1, y0, y1][side]
            let limit = vertical ? w : h
            guard edge + min(a, b) - k >= 0, edge + max(a, b) + k <= limit else { return nil }
            let along = vertical ? y0..<y1 : x0..<x1
            guard along.count > 4 else { return nil }
            let inward: Float = (side == 0 || side == 2) ? 1 : -1
            var hits = 0, maskHits = 0
            var outer: [Float] = []
            outer.reserveCapacity(along.count)
            let span = Float(along.count - 1)
            for (i, t) in along.enumerated() {
                let e = edge + a + Int((Float(b - a) * Float(i) / span).rounded())
                var before: Float = 0, after: Float = 0
                var unlitBefore = 0, unlitAfter = 0
                for j in 1...k {
                    let ib = vertical ? t * w + e - j : (e - j) * w + t
                    let ia = vertical ? t * w + e + j - 1 : (e + j - 1) * w + t
                    before += d[ib]; after += d[ia]
                    if unlit[ib] { unlitBefore += 1 }
                    if unlit[ia] { unlitAfter += 1 }
                }
                before /= Float(k); after /= Float(k)
                if (after - before) * inward > delta { hits += 1 }
                // Holder mask right outside, lit film right inside: a frame edge whatever the picture does.
                let (unlitOut, unlitIn) = inward > 0 ? (unlitBefore, unlitAfter) : (unlitAfter, unlitBefore)
                if unlitOut * 5 >= k * 4, unlitIn * 5 <= k { maskHits += 1 }
                outer.append(inward > 0 ? before : after)
            }
            let maskScore = Float(maskHits) / Float(along.count)
            // Median absolute deviation: sprocket holes or a speck of dust don't count against it.
            outer.sort()
            let med = outer[outer.count / 2]
            var dev = outer.map { abs($0 - med) }
            dev.sort()
            let mad = dev[dev.count / 2]
            let flatness = 1 / (1 + (mad / 0.04) * (mad / 0.04))
            return (max(Float(hits) / Float(outer.count) * flatness, maskScore), maskScore)
        }

        /// A holder opening holding only picture: mask beyond two or more sides, nothing clear
        /// running right across it, no sprocket holes.
        func isHolderOpening(_ r: Rect) -> Bool {
            let rw = r.2 - r.0, rh = r.3 - r.1
            let maskSides = (0..<4).filter { maskBeyond(r, $0) > 0.6 }.count
            if maskSides >= 2 {
                func clearLine(_ n: Int, _ at: (Int) -> Float) -> Bool {
                    var c = 0
                    for i in 0..<n where at(i) < 0.02 { c += 1 }
                    return c * 100 >= n * 85
                }
                // Interior only: the clear rim of film along the holder edge doesn't count.
                let mx = rw / 20, my = rh / 20
                let crossesClear = (r.0 + mx..<r.2 - mx).contains { x in clearLine(rh) { d[(r.1 + $0) * w + x] } }
                    || (r.1 + my..<r.3 - my).contains { y in clearLine(rw) { d[y * w + r.0 + $0] } }
                return !crossesClear && !hasSprocketHoles(r)
            }
            return false
        }

        /// A run of sprocket holes inside the rect: rows (or columns) with many separate clear gaps,
        /// hole-sized (specks and big clear areas don't count), evenly spaced and alike in size,
        /// as sprocket holes are and branches against the sky aren't. A single frame never has them.
        func hasSprocketHoles(_ r: Rect) -> Bool {
            let rw = r.2 - r.0, rh = r.3 - r.1
            guard rw > 10, rh > 10 else { return false }
            return (r.1..<r.3).filter { y in perforated(rw) { d[y * w + r.0 + $0] } }.count > rh / 50
                || (r.0..<r.2).filter { x in perforated(rh) { d[(r.1 + $0) * w + x] } }.count > rw / 50
        }

        /// A line crossing a row of sprocket holes: many hole-sized clear gaps, evenly spaced.
        func perforated(_ n: Int, minHoles: Int = 6, _ at: (Int) -> Float) -> Bool {
                let minLen = max(2, n / 100), maxLen = max(minLen + 1, n / 10)
                var holes: [(start: Int, len: Int)] = []
                var run = 0
                for i in 0...n {
                    if i < n, at(i) < 0.02 { run += 1; continue }
                    if run >= minLen && run <= maxLen { holes.append((i - run, run)) }
                    run = 0
                }
                guard holes.count >= minHoles else { return false }
                // Most values near the median (one missed or extra hole doesn't spoil it).
                func regular(_ v: [Int], _ tol: Double) -> Bool {
                    let m = Double(v.sorted()[v.count / 2])
                    return v.filter { abs(Double($0) - m) <= tol * m }.count * 10 >= v.count * 7
                }
                let pitch = zip(holes.dropFirst(), holes).map { $0.start - $1.start }
                return regular(pitch, 0.25) && regular(holes.map(\.len), 0.4)
        }

        // MARK: 35 mm strips

        struct Blob { var cx: Double; var cy: Double; var bw: Int; var bh: Int }

        /// Sprocket-hole candidates: small, well-filled clear rectangles (bare backlight through the film).
        func holeBlobs() -> [Blob] {
            var seen = [Bool](repeating: false, count: d.count)
            var blobs: [Blob] = []
            let maxSide = max(w, h) / 15
            for i in 0..<d.count where !seen[i] && !unlit[i] && d[i] < 0.02 {
                var stack = [i]
                seen[i] = true
                var x0 = w, y0 = h, x1 = 0, y1 = 0, area = 0
                var sx = 0.0, sy = 0.0
                while let j = stack.popLast() {
                    let x = j % w, y = j / w
                    x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                    area += 1
                    sx += Double(x); sy += Double(y)
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                        let k = ny * w + nx
                        if !seen[k], !unlit[k], d[k] < 0.02 { seen[k] = true; stack.append(k) }
                    }
                }
                let bw = x1 - x0 + 1, bh = y1 - y0 + 1
                guard area >= 10, bw <= maxSide, bh <= maxSide else { continue }
                let aspect = Double(bw) / Double(bh)
                guard aspect > 0.35, aspect < 3, Double(area) >= 0.55 * Double(bw * bh) else { continue }
                blobs.append(Blob(cx: sx / Double(area), cy: sy / Double(area), bw: bw, bh: bh))
            }
            return blobs
        }

        /// Frames on a 35 mm strip, found from its geometry: two parallel rows of sprocket holes
        /// (whose angle is the strip's tilt), the picture between them, 1.5× as long as it's wide,
        /// repeating every 38 mm with a flat rebate-density gap between frames.
        /// `frames` is empty when the strip is found but the gaps can't be placed (e.g. still tilted).
        func stripFrames() -> (frames: [Rect], tilt: Double, band: Rect)? {
            let blobs = holeBlobs()
            guard blobs.count >= 6 else { return nil }
            var best: (vertical: Bool, theta: Double, c1: Double, c2: Double, score: Int)?
            for vertical in [true, false] {
                // Hole size across the strip.
                let across = blobs.map { Double(vertical ? $0.bw : $0.bh) }.sorted()[blobs.count / 2]
                for step in -32...32 {
                    let theta = Double(step) * 0.25 * .pi / 180
                    let c = cos(theta), sn = sin(theta)
                    // Position across the strip once the tilt is taken out.
                    let u = blobs.map { vertical ? $0.cx * c + $0.cy * sn : $0.cy * c - $0.cx * sn }
                    func support(_ at: Double) -> Int { u.filter { abs($0 - at) <= 2.5 }.count }
                    guard let i1 = u.indices.max(by: { support(u[$0]) < support(u[$1]) }) else { continue }
                    let s1 = support(u[i1])
                    let far = u.indices.filter { abs(u[$0] - u[i1]) >= 4 * across }
                    guard let i2 = far.max(by: { support(u[$0]) < support(u[$1]) }) else { continue }
                    let s2 = support(u[i2])
                    // Two rows, 25.3 mm apart inside against holes about 2.8 mm across.
                    let ratio = (abs(u[i1] - u[i2]) - across) / across
                    guard s1 >= 3, s2 >= 3, ratio > 5, ratio < 14 else { continue }
                    // Each row repeats at the 4.75 mm perforation pitch, ~1.7× a hole's width
                    // (a missing hole just doubles one step). Rows of windows in a picture don't.
                    func regularRow(_ center: Double) -> Bool {
                        let along = u.indices.filter { abs(u[$0] - center) <= 2.5 }
                            .map { vertical ? blobs[$0].cy * c - blobs[$0].cx * sn : blobs[$0].cx * c + blobs[$0].cy * sn }
                            .sorted()
                        let steps = zip(along.dropFirst(), along).map { $0 - $1 }.filter { $0 > 1 }
                        guard steps.count >= 2 else { return false }
                        let p = steps.sorted()[steps.count / 2]
                        guard p / across > 1.2, p / across < 2.6 else { return false }
                        let fits = steps.filter { st in (1...3).contains { k in abs(st - Double(k) * p) <= 0.2 * p } }.count
                        return fits * 10 >= steps.count * 7
                    }
                    guard regularRow(u[i1]), regularRow(u[i2]) else { continue }
                    if s1 + s2 > (best?.score ?? 0) {
                        best = (vertical, Double(step) * 0.25, min(u[i1], u[i2]), max(u[i1], u[i2]), s1 + s2)
                    }
                }
            }
            guard let b = best else { return nil }
            let vertical = b.vertical
            let nu = vertical ? w : h, nv = vertical ? h : w
            func at(_ u: Int, _ v: Int) -> Float { vertical ? d[v * w + u] : d[u * w + v] }
            let across = blobs.map { Double(vertical ? $0.bw : $0.bh) }.sorted()[blobs.count / 2]
            // Hole rows' inner edges, at the middle of the scan along the strip.
            let theta = b.theta * .pi / 180
            let mid = Double(nv) / 2
            func toU(_ uRot: Double) -> Int { Int(((uRot / cos(theta)) - mid * tan(theta) * (vertical ? 1 : -1)).rounded()) }
            let all = (lo: toU(b.c1 + across / 2), hi: toU(b.c2 - across / 2))
            let tilt = b.theta
            if FrameDetector.debug { print("   strip vertical=\(vertical) holes", blobs.count, "rows", b.c1, b.c2, "support", b.score, "tilt", tilt, "inner", all) }
            guard all.lo > 0, all.hi < nu, all.hi - all.lo > 10 else { return nil }
            // Picture between the holes: 24 of the 25.3 mm, centred.
            let inner = all.hi - all.lo
            // (A touch more than the nominal 0.65 mm, so no border line shows.)
            let u0 = all.lo + Int(Double(inner) * 0.04), u1 = all.hi - Int(Double(inner) * 0.04)
            let width = u1 - u0
            guard width > 10 else { return nil }
            let len = Int(Double(width) * 1.5), pitch = Double(width) * 38 / 24

            // Gap rows: flat, at the rebate's density (measured between holes and picture).
            // Rebate density: the film between the picture and the holes, clear holes left out.
            let rebate: Float = {
                var v: [Float] = []
                let band = max(3, inner / 12)
                for vv in stride(from: 0, to: nv, by: 2) {
                    for u in max(0, all.lo - band)..<min(nu, u0) where at(u, vv) > 0.05 { v.append(at(u, vv)) }
                    for u in u1..<min(nu, all.hi + band) where at(u, vv) > 0.05 { v.append(at(u, vv)) }
                }
                v.sort()
                return v.isEmpty ? 0.2 : v[v.count / 2]
            }()
            let gap: [Bool] = (0..<nv).map { v in
                var sum: Float = 0, sq: Float = 0
                for u in u0..<u1 { let x = at(u, v); sum += x; sq += x * x }
                let n = Float(u1 - u0), m = sum / n
                return abs(m - rebate) < 0.1 && (sq / n - m * m).squareRoot() < 0.08
            }
            func gapNear(_ v: Int) -> Bool { (max(0, v - 3)...min(nv - 1, max(0, v + 3))).contains { gap[$0] } }

            // Where along the strip the frames fall: gaps at both ends, none inside.
            var bestOffset = -1
            var bestScore = 0.0
            for v0 in 0..<max(1, Int(pitch)) {
                var score = 0.0
                var k = Double(v0) - pitch * 3
                while k < Double(nv) {
                    let a = Int(k), b = Int(k) + len
                    if a - 1 >= 0 && gapNear(a - 1) { score += 1 }
                    if b + 1 < nv && gapNear(b + 1) { score += 1 }
                    let lo = max(0, a + 4), hi = min(nv, b - 4)
                    if hi > lo { score -= 2 * Double((lo..<hi).filter { gap[$0] }.count) / Double(hi - lo) }
                    k += pitch
                }
                if score > bestScore { bestScore = score; bestOffset = v0 }
            }
            if FrameDetector.debug { print("   strip u0..u1", u0, u1, "len", len, "pitch", pitch, "rebate", rebate, "gapRows", gap.filter { $0 }.count, "offset", bestOffset, "score", bestScore, "tilt", tilt) }
            let band: Rect = vertical ? (u0, 0, u1, nv) : (0, u0, nv, u1)
            guard bestOffset >= 0, bestScore >= 1 else { return ([], tilt, band) }
            var frames: [Rect] = []
            var k = Double(bestOffset) - pitch * 3
            while k < Double(nv) {
                let a = Int(k), b = Int(k) + len
                if a >= 0 && b <= nv {
                    // Skip frames hidden by the holder or off the film.
                    // (Unlit or clipped: holder, or a card laid over the film.)
                    let covered = (a..<b).filter { v in
                        (u0..<u1).filter { let i = vertical ? v * w + $0 : $0 * w + v; return unlit[i] || d[i] == 0 }.count * 2 > u1 - u0
                    }.count
                    if covered * 4 < b - a {
                        let t = max(1, len / 60)
                        frames.append(vertical ? (u0, a + t, u1, b - t) : (a + t, u0, b - t, u1))
                    }
                }
                k += pitch
            }
            return (frames, tilt, band)
        }

        /// Lengthens a frame found between two rows of sprocket holes to the 3:2 of 35 mm film
        /// when it's clearly short, moving whichever end has the weaker edge, then snapping that
        /// end to the nearest good edge (the gap to the next frame).
        func completeSprocketFrame(_ r: Rect) -> Rect {
            let fw = r.2 - r.0, fh = r.3 - r.1
            guard fw > 10, fh > 10 else { return r }
            // Holes run along the strip, just beyond the frame's long sides.
            let bx = max(4, fw / 5), by = max(4, fh / 5)
            let holesLR = hasSprocketHoles((max(0, r.0 - bx), 0, r.0, h)) || hasSprocketHoles((r.2, 0, min(w, r.2 + bx), h))
            let holesTB = hasSprocketHoles((0, max(0, r.1 - by), w, r.1)) || hasSprocketHoles((0, r.3, w, min(h, r.3 + by)))
            var out = r
            if holesLR && !holesTB {
                // Vertical strip: the frame's length runs down the scan.
                let want = Int(Double(fw) * 1.5)
                guard Double(fh) < 1.3 * Double(fw) else { return r }
                let topS = sideScore(r, 2) ?? 0, botS = sideScore(r, 3) ?? 0
                if botS <= topS { out.3 = min(h, r.1 + want) } else { out.1 = max(0, r.3 - want) }
                let side = botS <= topS ? 3 : 2
                if let f = fitSide(out, side), f.s > 0.3 {
                    if side == 3 { out.3 += min(f.a, f.b) } else { out.1 += max(f.a, f.b) }
                }
            } else if holesTB && !holesLR {
                // Horizontal strip.
                let want = Int(Double(fh) * 1.5)
                guard Double(fw) < 1.3 * Double(fh) else { return r }
                let leftS = sideScore(r, 0) ?? 0, rightS = sideScore(r, 1) ?? 0
                if rightS <= leftS { out.2 = min(w, r.0 + want) } else { out.0 = max(0, r.2 - want) }
                let side = rightS <= leftS ? 1 : 0
                if let f = fitSide(out, side), f.s > 0.3 {
                    if side == 1 { out.2 += min(f.a, f.b) } else { out.0 += max(f.a, f.b) }
                }
            }
            return out
        }

        /// Share of a side with holder mask a short way beyond it (past the thin lit rim a holder leaves).
        func maskBeyond(_ r: Rect, _ side: Int) -> Float {
            let reach = max(3, max(w, h) / 30)
            let vertical = side < 2
            let along = vertical ? r.1..<r.3 : r.0..<r.2
            guard !along.isEmpty else { return 0 }
            let edge = [r.0, r.2 - 1, r.1, r.3 - 1][side]
            let dir = side == 0 || side == 2 ? -1 : 1
            var hits = 0
            for t in along {
                for j in 1...reach {
                    let e = edge + dir * j
                    guard e >= 0, e < (vertical ? w : h) else { break }
                    if unlit[vertical ? t * w + e : e * w + t] { hits += 1; break }
                }
            }
            return Float(hits) / Float(along.count)
        }

        /// Best slanted placement of one side near its current position.
        func fitSide(_ r: Rect, _ side: Int) -> (a: Int, b: Int, s: Float)? {
            let win = max(3, max(w, h) / 40)
            var best: (a: Int, b: Int, s: Float)?
            // Coarse, then fine around the coarse winner.
            for a in stride(from: -win, through: win, by: 2) {
                for b in stride(from: -win, through: win, by: 2) {
                    if let s = sideScore(r, side, a, b), s > (best?.s ?? -1) { best = (a, b, s) }
                }
            }
            guard let coarse = best else { return nil }
            for a in (coarse.a - 1)...(coarse.a + 1) {
                for b in (coarse.b - 1)...(coarse.b + 1) {
                    if let s = sideScore(r, side, a, b), s > best!.s { best = (a, b, s) }
                }
            }
            return best
        }

        /// Fits all four (possibly slanted) sides; returns the axis-aligned rect inside them
        /// and a score: a blend of the mean and the weakest side. A side running off the scan
        /// counts as weak evidence, so a whole strip doesn't beat the frame on it.
        /// `holder`: the rect is a holder opening holding only picture (mask beyond two or more
        /// sides, nothing clear running across it, no sprocket holes).
        func fit(_ r0: Rect) -> (r: Rect, s: Float, tilt: Double, weakest: Float, holder: Bool) {
            var r = r0
            let offScan: Float = 0.2
            var scores: [Float] = [offScan, offScan, offScan, offScan]
            var tilts: [(t: Double, w: Double)] = []
            for pass in 0..<2 {
                var inner = r
                for side in 0..<4 {
                    // A side at the edge of the scan: the frame runs on past it. Leave it there.
                    let edge = [r0.0, r0.2, r0.1, r0.3][side], limit = side < 2 ? w : h
                    if edge <= band || edge >= limit - band { scores[side] = offScan; continue }
                    guard let f = fitSide(r, side) else { scores[side] = offScan; continue }
                    scores[side] = f.s
                    // Tilt only from convincing edges; a weak side's slant is noise.
                    if pass == 1, f.s > 0.6 {
                        // Slant along the side → clockwise tilt of the frame (y points down).
                        let len = Double(side < 2 ? r.3 - r.1 : r.2 - r.0)
                        let slope = Double(f.b - f.a) / max(1, len)
                        let t = (side < 2 ? -atan(slope) : atan(slope)) * 180 / .pi
                        tilts.append((t, Double(f.s)))
                    }
                    switch side {
                    case 0: inner.0 = r.0 + max(f.a, f.b)
                    case 1: inner.2 = r.2 + min(f.a, f.b)
                    case 2: inner.1 = r.1 + max(f.a, f.b)
                    default: inner.3 = r.3 + min(f.a, f.b)
                    }
                }
                guard inner.2 - inner.0 > w / 8, inner.3 - inner.1 > h / 8 else { return (r, 0, 0, 0, false) }
                r = inner
            }
            // Mostly the three best sides: a frame whose fourth edge runs off the scan or is
            // ragged is still far more convincing than a patch with four mediocre sides.
            let sortedScores = scores.sorted()
            let edges = 0.75 * (sortedScores[1...].reduce(0, +) / 3) + 0.25 * sortedScores[0]
            // Frames are big; small boxes are more likely a patch of picture.
            let areaFrac = Double((r.2 - r.0) * (r.3 - r.1)) / Double(w * h)
            let size = Float(0.7 + 0.3 * areaFrac.squareRoot())
            // A frame's sides are parallel: trust a tilt only when two or more sides agree on it.
            var tilt = 0.0
            var bestSupport = 0.0
            for c in tilts {
                let near = tilts.filter { abs($0.t - c.t) <= 0.6 }
                let support = near.reduce(0) { $0 + $1.w }
                if near.count >= 2, support > bestSupport {
                    bestSupport = support
                    tilt = near.reduce(0) { $0 + $1.t * $1.w } / support
                }
            }
            // A frame holds picture only: bare backlight or sprocket holes inside the rect mean it
            // spans more than one frame, the whole strip or the light panel.
            // Except the holder opening itself when nothing clear runs right across it: with no
            // backlight in view, the picture's deep shadows are as clear as anything in the scan.
            let rw = r.2 - r.0, rh = r.3 - r.1
            if isHolderOpening(r) { return (r, edges * size, tilt, sortedScores[0], true) }
            // Sprocket holes inside: this spans the rebate, so it's a strip, not a frame.
            if hasSprocketHoles(r) { return (r, edges * size * 0.2, tilt, sortedScores[0], false) }
            var clear = 0, total = 0
            for y in stride(from: r.1, to: r.3, by: 2) {
                for x in stride(from: r.0, to: r.2, by: 2) {
                    if d[y * w + x] < 0.02 { clear += 1 }
                    total += 1
                }
            }
            let clearFrac = Float(clear) / Float(max(1, total))
            // (A little clear is dust or rim.)
            return (r, edges * size * max(0, 1 - max(0, clearFrac - 0.01) * 8), tilt, sortedScores[0], false)
        }
    }
}

import CoreImage

/// Auto crop with straightening: detect the frame; if it's tilted, straighten and detect again
/// on the straightened image so the crop fits the now-square frame.
enum AutoCrop {
    struct Result {
        var straighten: Double
        var crop: NormRect
    }

    /// `source` is the decoded scan before geometry (see `Pipeline.decodePreview`).
    static func run(source: CIImage, settings current: EditSettings) -> Result? {
        // Measure from the scan as shot, so an earlier (possibly wrong) straighten can't skew it.
        var s0 = current
        s0.straighten = 0
        let lin = Pipeline.renderLinear(Pipeline.applyGeometry(source, s0))
        guard var det = FrameDetector.detect(lin) else { return nil }
        var s = s0
        // Each pass measures what tilt is left; a couple of passes settle within a fraction of a degree.
        for _ in 0..<3 where abs(det.tilt) > 0.15 && abs(det.tilt) < 8 {
            var next = s
            next.straighten = max(-10, min(10, s.straighten - det.tilt))
            guard let d2 = FrameDetector.detect(Pipeline.renderLinear(Pipeline.applyGeometry(source, next))),
                  FrameDetector.overlap(d2.rect, det.rect) > 0.7 else { break } // jumped elsewhere: keep what we had
            det = d2
            s = next
        }
        return Result(straighten: s.straighten, crop: det.rect)
    }
}
