import Foundation
import CoreGraphics
import CoreImage
import Combine

enum Tool: Equatable {
    case none, crop, pickBase, pickNeutral
}

/// Holds the frame being edited and keeps its processed preview up to date.
final class EditorModel: ObservableObject {
    @Published private(set) var frame: FrameRef?
    var url: URL? { frame?.url }
    @Published var settings = EditSettings() {
        didSet { settingsChanged(from: oldValue) }
    }
    @Published var tool: Tool = .none {
        didSet {
            guard tool != oldValue else { return }
            requestRender()
        }
    }
    @Published var showNegative = false {
        didSet { requestRender() }
    }
    @Published var aspect: CropAspect = .free
    @Published var aspectPortrait = false

    /// Processed preview of the whole oriented frame (crop is applied at display time).
    @Published private(set) var image: CGImage?
    @Published private(set) var histogram: Histogram?
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    /// Short-lived message shown over the image.
    @Published private(set) var notice: String?
    /// Geometry `image` was rendered with. While it differs from `settings` (a rotation is
    /// rendering), the canvas rotates the old image so the change shows immediately.
    @Published private(set) var shownGeometry = EditSettings()
    /// Small processed image of the current frame as it looks in the editor, for the filmstrip.
    @Published private(set) var thumbnail: (key: String, settings: EditSettings, image: CGImage)?

    /// Called whenever the user changes settings, so the roll can persist them.
    var onChange: ((FrameRef, EditSettings) -> Void)?

    private var linear: LinearImage?
    private var linearGeometry = EditSettings()
    /// The current frame decoded once, before geometry; rotating re-renders from this.
    private var source: (url: URL, image: CIImage)?
    private var geometryInFlight: Int?
    private var geometryDirty = false
    private var levels: (key: String, value: Levels)?
    private var suppress = false
    private var loadGeneration = 0
    private var rendering = false
    private var renderDirty = false

    // Undo history per frame (keyed by FrameRef.key), so it survives moving between frames.
    private var history: [String: (undo: [EditSettings], redo: [EditSettings])] = [:]
    private var lastRecord: (key: String, fields: Set<String>, time: Date)?
    private var recording = true

    var imagePixelSize: CGSize {
        guard let linear else { return .zero }
        return CGSize(width: linear.width, height: linear.height)
    }

    func open(_ frame: FrameRef?, settings: EditSettings) {
        let url = frame?.url
        suppress = true
        self.frame = frame
        self.settings = settings
        suppress = false
        tool = .none
        image = nil
        histogram = nil
        linear = nil
        levels = nil
        failed = false
        if source?.url != url { source = nil }
        reload(force: true)
    }

    /// Replaces settings from outside (paste, sync, detected defaults) without echoing back.
    func replaceSettings(_ s: EditSettings, record: Bool) {
        guard s != settings else { return }
        let old = settings
        if record, let frame { recordHistory(old, for: frame, coalesce: false) }
        suppress = true
        settings = s
        suppress = false
        applyChange(from: old)
    }

    private func settingsChanged(from old: EditSettings) {
        guard !suppress, let frame, old != settings else { return }
        // Locked levels belong to one film type and base; changing either unlocks them.
        if settings.fixedLevels != nil, settings.fixedLevels == old.fixedLevels,
           settings.mode != old.mode || settings.filmBase != old.filmBase {
            settings.fixedLevels = nil
        }
        if recording { recordHistory(old, for: frame, coalesce: true) }
        onChange?(frame, settings)
        applyChange(from: old)
    }

    // MARK: Undo

    /// Records the state before a change. Consecutive changes of the same single slider
    /// (or crop drag) within a second merge into one step.
    func recordHistory(_ old: EditSettings, for frame: FrameRef, coalesce: Bool) {
        let key = frame.key
        let fields = frame == self.frame ? settings.changedFields(from: old) : []
        let now = Date()
        var h = history[key] ?? ([], [])
        let merge = coalesce && fields.count == 1 && lastRecord.map {
            $0.key == key && $0.fields == fields && now.timeIntervalSince($0.time) < 1
        } == true
        if !merge {
            h.undo.append(old)
            if h.undo.count > 200 { h.undo.removeFirst() }
        }
        h.redo.removeAll()
        history[key] = h
        lastRecord = coalesce ? (key, fields, now) : nil
    }

    var canUndo: Bool { frame.flatMap { history[$0.key]?.undo.isEmpty == false } ?? false }
    var canRedo: Bool { frame.flatMap { history[$0.key]?.redo.isEmpty == false } ?? false }

    func undo() { step(back: true) }
    func redo() { step(back: false) }

    private func step(back: Bool) {
        guard let key = frame?.key, var h = history[key] else { return }
        guard let target = back ? h.undo.popLast() : h.redo.popLast() else { return }
        if back { h.redo.append(settings) } else { h.undo.append(settings) }
        history[key] = h
        lastRecord = nil
        recording = false
        settings = target
        recording = true
    }

    private func applyChange(from old: EditSettings) {
        if old.geometryKey != settings.geometryKey {
            reload()
            return
        }
        // While cropping the full frame is shown with frozen levels, so a crop-only change needs no render.
        if tool == .crop, old.pastingAdjustments(from: settings) == settings { return }
        requestRender()
    }

    /// Re-renders the oriented preview. Decodes the file only when it isn't cached yet;
    /// otherwise geometry is applied to the in-memory copy, which is fast enough to follow
    /// a slider. Changes arriving mid-render are coalesced into one follow-up render.
    private func reload(force: Bool = false) {
        guard let url else { return }
        if geometryInFlight != nil, !force {
            geometryDirty = true
            return
        }
        loadGeneration += 1
        let gen = loadGeneration
        geometryInFlight = gen
        geometryDirty = false
        let s = settings
        let cached = source?.url == url ? source?.image : nil
        if cached == nil { loading = true }
        DispatchQueue.global(qos: .userInitiated).async {
            let src = cached ?? Pipeline.decodePreview(url)
            let lin = src.map { Pipeline.renderLinear(Pipeline.applyGeometry($0, s)) }
            DispatchQueue.main.async {
                if self.geometryInFlight == gen { self.geometryInFlight = nil }
                guard gen == self.loadGeneration, url == self.url else { return }
                self.loading = false
                if let src { self.source = (url, src) }
                self.linear = lin
                self.linearGeometry = s
                self.failed = lin == nil
                self.requestRender()
                if self.geometryDirty {
                    self.geometryDirty = false
                    self.reload()
                }
            }
        }
    }

    private func requestRender() {
        guard let linear else { return }
        if rendering {
            renderDirty = true
            return
        }
        rendering = true
        let s = settings
        var geometry = linearGeometry
        // The crop the displayed image should use, when it still matches this geometry.
        if s.geometryKey == geometry.geometryKey { geometry.crop = s.crop }
        let negative = showNegative || tool == .pickBase
        let key = s.levelsKey
        var cached: Levels? = nil
        if let levels {
            // While cropping, keep the levels we had so the image doesn't pump under the handles.
            if levels.key == key || tool == .crop { cached = levels.value }
        }
        let frameKey = frame?.key
        DispatchQueue.global(qos: .userInitiated).async {
            let lv = cached ?? Processor.analyze(linear, settings: s)
            let result = Processor.render(linear, settings: s, levels: lv, negative: negative)
            // What the filmstrip shows for this frame: the editor's own rendering, cropped.
            let thumb = negative || s.geometryKey != geometry.geometryKey ? nil
                : result.flatMap { Self.makeThumbnail($0.0, crop: s.crop) }
            DispatchQueue.main.async {
                self.rendering = false
                if linear === self.linear {
                    if cached == nil { self.levels = (key, lv) }
                    if let result {
                        self.image = result.0
                        self.histogram = result.1
                        self.shownGeometry = geometry
                    }
                    if let thumb, let frameKey, frameKey == self.frame?.key {
                        self.thumbnail = (frameKey, s, thumb)
                        ThumbCache.shared.store(thumb, for: frameKey, settings: s)
                    }
                }
                if self.renderDirty {
                    self.renderDirty = false
                    self.requestRender()
                }
            }
        }
    }

    private static func makeThumbnail(_ img: CGImage, crop c: NormRect) -> CGImage? {
        let r = CGRect(x: c.x * Double(img.width), y: c.y * Double(img.height),
                       width: c.w * Double(img.width), height: c.h * Double(img.height)).integral
        guard let cropped = img.cropping(to: r) else { return nil }
        let scale = min(1, 360 / Double(max(cropped.width, cropped.height)))
        let w = max(1, Int(Double(cropped.width) * scale)), h = max(1, Int(Double(cropped.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: Pipeline.srgb,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Levels in use for the current frame (measured or locked).
    var currentLevels: Levels? {
        if let locked = Levels(array: settings.fixedLevels) { return locked }
        return levels?.value
    }

    // MARK: Full-resolution detail

    struct DetailRequest: Equatable {
        /// Visible area, normalised to the whole oriented frame.
        var rect: NormRect
        /// Screen pixels it's shown at.
        var pixels: CGSize
    }

    private let detailQueue = DispatchQueue(label: "negativ.detail", qos: .userInitiated)
    /// The full-resolution scan, decoded lazily; only touched on `detailQueue`.
    private var fullSource: (url: URL, image: CIImage)?

    /// Renders the visible area from the full-resolution scan with the current settings and
    /// levels, so zooming in shows real detail rather than an enlarged preview.
    func renderDetail(_ req: DetailRequest) async -> CGImage? {
        guard let url, let levels = currentLevels else { return nil }
        let s = settings
        let negative = showNegative || tool == .pickBase
        return await withCheckedContinuation { cont in
            detailQueue.async {
                if self.fullSource?.url != url {
                    self.fullSource = Pipeline.sourceImage(url, maxDim: nil).map { (url, $0.insertingIntermediate(cache: true)) }
                }
                guard let src = self.fullSource?.image,
                      let lin = Pipeline.renderDetail(src, settings: s, rect: req.rect, maxPixels: req.pixels) else {
                    cont.resume(returning: nil)
                    return
                }
                let params = ToneParams(settings: s, levels: levels)
                var out = [UInt8](repeating: 255, count: lin.width * lin.height * 4)
                lin.pixels.withUnsafeBufferPointer { src in
                    out.withUnsafeMutableBufferPointer { dst in
                        Processor.process8(src.baseAddress!, dst.baseAddress!, width: lin.width, height: lin.height,
                                           params: params, negative: negative)
                    }
                }
                cont.resume(returning: Processor.makeCGImage8(out, w: lin.width, h: lin.height))
            }
        }
    }

    // MARK: Pickers

    /// Point in normalised coordinates of the full oriented frame.
    func pick(at p: CGPoint) {
        guard let linear else { return }
        let c = linear.sample(nx: p.x, ny: p.y)
        switch tool {
        case .pickBase:
            settings.filmBase = [c.x, c.y, c.z]
            tool = .none
        case .pickNeutral:
            guard let lv = levels?.value else { return }
            let params = ToneParams(settings: settings, levels: lv)
            let v = Processor.normalised(Processor.raw(c, settings.mode, params.base, floor: params.floor), params)
            let k = Double(ToneParams.wbScale)
            var s = settings
            s.temperature = max(-1, min(1, Double(v.z - v.x) / (2 * k)))
            s.tint = max(-1, min(1, Double(v.y - (v.x + v.z) / 2) / k))
            settings = s
            tool = .none
        default:
            break
        }
    }

    // MARK: Geometry

    func rotate(clockwise: Bool) {
        settings = settings.rotated(clockwise: clockwise)
        aspectPortrait.toggle()
    }

    func flip() { settings = settings.flipped() }

    func resetCrop() { settings.crop = .full }

    /// Negative film type last used per frame, so toggling back from positive restores it.
    private var negativeMode: [String: FilmMode] = [:]

    /// Switches between inverting the scan as a negative and showing it as it is (a positive).
    func toggleInversion() {
        guard let frame else { return }
        if settings.mode == .positive {
            // Back to the film type it had, or B&W / colour as the scan looks.
            let mode = negativeMode[frame.key] ?? (linear.map(Processor.looksMonochrome) == true ? .bwNegative : .colorNegative)
            settings.mode = mode
            flash(mode == .bwNegative ? "B&W negative" : "Colour negative")
        } else {
            negativeMode[frame.key] = settings.mode
            settings.mode = .positive
            flash("Positive (not inverted)")
        }
    }

    /// Straightens and crops to the film frame found in the scan (respecting a chosen aspect).
    func autoCrop() {
        guard let frame, let src = source?.image, source?.url == frame.url else { return }
        let s0 = settings
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AutoCrop.run(source: src, settings: s0)
            DispatchQueue.main.async {
                // Drop the result if the user moved on or changed things meanwhile.
                guard frame == self.frame, self.settings == s0 else { return }
                guard let result else {
                    self.flash("No frame edge found")
                    return
                }
                var s = s0
                s.straighten = result.straighten
                s.crop = result.crop
                self.settings = s
                if self.aspect != .free { self.applyAspect() }
                if abs(result.straighten - s0.straighten) > 0.05 {
                    self.flash(String(format: "Straightened by %+.1f°", result.straighten - s0.straighten))
                }
            }
        }
    }

    /// All frames in the current scan (for strips with several frames per shot).
    func detectAllFrames(_ completion: @escaping ([NormRect]) -> Void) {
        guard let linear, let frame else { return }
        flash("Looking for frames…")
        DispatchQueue.global(qos: .userInitiated).async {
            let rects = FrameDetector.detectAll(linear)
            DispatchQueue.main.async {
                guard frame == self.frame else { return }
                completion(rects)
            }
        }
    }

    func flash(_ message: String) {
        notice = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if self.notice == message { self.notice = nil }
        }
    }

    /// Crop aspect as a ratio of normalised width / normalised height.
    func normalisedAspect() -> Double? {
        let size = imagePixelSize
        guard size.width > 0, var r = aspect.ratio(originalW: size.width, originalH: size.height) else { return nil }
        if aspect == .original {
            return 1
        }
        if aspectPortrait { r = 1 / r }
        return r * Double(size.height / size.width)
    }

    /// Fits the current crop to the chosen aspect, keeping its centre.
    func applyAspect() {
        guard let r = normalisedAspect() else { return }
        var c = settings.crop
        let cx = c.x + c.w / 2, cy = c.y + c.h / 2
        if c.w / c.h > r { c.w = c.h * r } else { c.h = c.w / r }
        c.x = min(max(0, cx - c.w / 2), 1 - c.w)
        c.y = min(max(0, cy - c.h / 2), 1 - c.h)
        settings.crop = c
    }
}
