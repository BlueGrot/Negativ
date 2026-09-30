import SwiftUI
import AppKit

// MARK: Canvas

struct EditorCanvas: View {
    @EnvironmentObject var editor: EditorModel

    /// Zoom relative to fitting the frame in the view (1 = fit), and how far it's been panned.
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize?
    /// Where the unzoomed image sits, for zooming around the pointer.
    @State private var layout = CanvasLayout()
    /// Full-resolution render of the visible area while zoomed in, with the state it was made for.
    @State private var detail: (key: String, image: CGImage)?

    private var showsFullFrame: Bool { editor.tool == .crop || editor.tool == .pickBase }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(white: 0.09)
                if let img = editor.image {
                    let target = editor.settings, shown = editor.shownGeometry
                    let turns = ((target.quarterTurns - shown.quarterTurns) % 4 + 4) % 4
                    let flip = target.flipH != shown.flipH
                    let dAngle = target.straighten - shown.straighten
                    // A rotation is still rendering: show the old image rotated to match meanwhile.
                    let stale = turns != 0 || flip || abs(dAngle) > 0.0001
                    let region = showsFullFrame ? NormRect.full : (stale ? shown.crop : target.crop)
                    let pxW = Double(img.width) * region.w, pxH = Double(img.height) * region.h
                    let aspect = pxW / max(pxH, 1)
                    let box = CGRect(origin: .zero, size: geo.size).insetBy(dx: 28, dy: 28)
                    let base = fitRect(aspect: turns % 2 == 1 ? 1 / aspect : aspect, in: box)
                    let fit = zoomed(base, in: box)
                    let shownImage = showsFullFrame ? img : (img.cropping(to: pixelRect(region, img)) ?? img)
                    let _ = layout.update(base: base, box: box, pixelsAcross: turns % 2 == 1 ? pxH : pxW)
                    Image(decorative: shownImage, scale: 1)
                        .resizable()
                        .interpolation(zoom > 1.5 ? .medium : .high)
                        .frame(width: turns % 2 == 1 ? fit.height : fit.width, height: turns % 2 == 1 ? fit.width : fit.height)
                        .scaleEffect(x: flip ? -1 : 1, y: 1)
                        .scaleEffect(stale ? straightenZoom(from: shown.straighten, to: target.straighten, img) : 1)
                        .rotationEffect(.degrees(Double(turns) * 90 + dAngle))
                        .position(x: fit.midX, y: fit.midY)
                        .gesture(panGesture, including: editor.tool == .none ? .all : .subviews)
                        .onTapGesture(count: 2) { resetZoom() }
                        .onHover { inside in
                            if inside && zoom > 1 && editor.tool == .none { NSCursor.openHand.set() } else if !inside { NSCursor.arrow.set() }
                        }
                    // Zoomed in: the visible area rendered from the full-resolution scan once the
                    // view settles (the enlarged preview shows meanwhile).
                    let visible = fit.intersection(CGRect(origin: .zero, size: geo.size))
                    let request = detailRequest(zoomed: zoom > 1.05 && !stale, fit: fit, visible: visible, region: region)
                    let detailKey = request.map { makeDetailKey($0, image: img, fullFrame: showsFullFrame) } ?? ""
                    if let detail, detail.key == detailKey, !detailKey.isEmpty {
                        Image(decorative: detail.image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: visible.width, height: visible.height)
                            .position(x: visible.midX, y: visible.midY)
                            .allowsHitTesting(false)
                    }
                    Color.clear
                        .frame(width: 0, height: 0)
                        .task(id: detailKey) {
                            guard let request else { return }
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            guard !Task.isCancelled, let image = await editor.renderDetail(request), !Task.isCancelled else { return }
                            detail = (detailKey, image)
                        }
                    if !stale {
                        if editor.tool == .crop {
                            CropOverlay(imageRect: fit)
                        }
                        if editor.tool == .pickBase || editor.tool == .pickNeutral {
                            // The tap is attached before positioning, so its location is relative
                            // to the image (after .position it would be relative to the canvas).
                            Color.clear
                                .contentShape(Rectangle())
                                .frame(width: fit.width, height: fit.height)
                                .hoverCursor(.crosshair)
                                .gesture(SpatialTapGesture().onEnded { v in
                                    let nx = region.x + Double(v.location.x / fit.width) * region.w
                                    let ny = region.y + Double(v.location.y / fit.height) * region.h
                                    editor.pick(at: CGPoint(x: nx, y: ny))
                                })
                                .position(x: fit.midX, y: fit.midY)
                        }
                    }
                }
                if editor.loading {
                    ProgressView().controlSize(.large)
                } else if editor.failed {
                    Label("Could not decode this file", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else if editor.url == nil {
                    Text("No frame selected").foregroundStyle(.secondary)
                }
                VStack {
                    if let hint = toolHint {
                        Text(hint)
                            .font(.callout)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, 10)
                    }
                    Spacer()
                    if zoom > 1.001 {
                        HStack(spacing: 8) {
                            Text(String(format: "%.1f×", zoom)).monospacedDigit()
                            Button("Fit") { resetZoom() }
                                .buttonStyle(.borderless)
                        }
                        .font(.callout)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 10)
                    }
                }
            }
            .clipped()
            .background(ScrollZoomCatcher { factor, point in zoom(by: factor, at: point) })
        }
        .onChange(of: editor.frame) { _, _ in resetZoom() }
    }

    /// The unzoomed image rect scaled by `zoom` about its centre and moved by `pan`.
    private func zoomed(_ base: CGRect, in box: CGRect) -> CGRect {
        let w = base.width * zoom, h = base.height * zoom
        let p = clampedPan(pan, size: CGSize(width: w, height: h), box: box)
        return CGRect(x: base.midX + p.width - w / 2, y: base.midY + p.height - h / 2, width: w, height: h)
    }

    /// Keeps a zoomed image covering the view: its edges can't be dragged inside the view's edges.
    private func clampedPan(_ p: CGSize, size: CGSize, box: CGRect) -> CGSize {
        let limX = max(0, (size.width - box.width) / 2), limY = max(0, (size.height - box.height) / 2)
        return CGSize(width: min(limX, max(-limX, p.width)), height: min(limY, max(-limY, p.height)))
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                guard zoom > 1 else { return }
                if panStart == nil { panStart = pan }
                guard let start = panStart else { return }
                pan = CGSize(width: start.width + v.translation.width, height: start.height + v.translation.height)
                NSCursor.closedHand.set()
            }
            .onEnded { _ in
                panStart = nil
                pan = clampedPan(pan, size: CGSize(width: layout.base.width * zoom, height: layout.base.height * zoom), box: layout.box)
                NSCursor.arrow.set()
            }
    }

    /// Zooms keeping the image point under `point` (view coordinates) where it is.
    private func zoom(by factor: CGFloat, at point: CGPoint) {
        let base = layout.base
        guard base.width > 0 else { return }
        // Up to 4 screen points per preview pixel; beyond that there's nothing more to see.
        let maxZoom = max(1, 4 * layout.pixelsAcross / base.width)
        let newZoom = min(maxZoom, max(1, zoom * factor))
        guard newZoom != zoom else { return }
        let size = CGSize(width: base.width * zoom, height: base.height * zoom)
        let p = clampedPan(pan, size: size, box: layout.box)
        let center = CGPoint(x: base.midX + p.width, y: base.midY + p.height)
        // The image point under the pointer, relative to the image centre in unzoomed units.
        let ux = (point.x - center.x) / zoom, uy = (point.y - center.y) / zoom
        let newCenter = CGPoint(x: point.x - ux * newZoom, y: point.y - uy * newZoom)
        zoom = newZoom
        pan = clampedPan(CGSize(width: newCenter.x - base.midX, height: newCenter.y - base.midY),
                         size: CGSize(width: base.width * newZoom, height: base.height * newZoom), box: layout.box)
    }

    private func detailRequest(zoomed: Bool, fit: CGRect, visible: CGRect, region: NormRect) -> EditorModel.DetailRequest? {
        guard zoomed, visible.width > 4, visible.height > 4, fit.width > 0, fit.height > 0 else { return nil }
        let rx = Double((visible.minX - fit.minX) / fit.width), ry = Double((visible.minY - fit.minY) / fit.height)
        let rw = Double(visible.width / fit.width), rh = Double(visible.height / fit.height)
        let rect = NormRect(x: region.x + rx * region.w, y: region.y + ry * region.h, w: rw * region.w, h: rh * region.h)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return .init(rect: rect, pixels: CGSize(width: visible.width * scale, height: visible.height * scale))
    }

    /// Everything the detail render depends on: frame, settings (crop only when it's applied),
    /// the preview it matches (so new levels re-render it), area and size.
    private func makeDetailKey(_ r: EditorModel.DetailRequest, image: CGImage, fullFrame: Bool) -> String {
        var s = editor.settings
        if fullFrame { s.crop = .full }
        return String(format: "%@|%ld|%ld|%d|%.5f,%.5f,%.5f,%.5f|%.0fx%.0f",
                      editor.frame?.key ?? "", s.hashValue, ObjectIdentifier(image).hashValue,
                      editor.showNegative || editor.tool == .pickBase ? 1 : 0,
                      r.rect.x, r.rect.y, r.rect.w, r.rect.h, r.pixels.width, r.pixels.height)
    }

    private func resetZoom() {
        zoom = 1
        pan = .zero
    }

    private var toolHint: String? {
        if let notice = editor.notice { return notice }
        switch editor.tool {
        case .crop: return "Drag the handles to crop · Return to finish"
        case .pickBase: return "Click the unexposed film between frames"
        case .pickNeutral: return "Click something that should be neutral grey"
        case .none: return editor.showNegative ? "Showing the negative" : nil
        }
    }

    /// Extra zoom straightening from one angle to another adds (the corner-free crop grows).
    private func straightenZoom(from a: Double, to b: Double, _ img: CGImage) -> CGFloat {
        func inscribed(_ deg: Double) -> Double {
            let w = Double(img.width), h = Double(img.height)
            let r = abs(deg) * .pi / 180, c = cos(r), s = sin(r)
            return min(w / (w * c + h * s), h / (w * s + h * c))
        }
        return CGFloat(inscribed(a) / inscribed(b))
    }

    private func pixelRect(_ r: NormRect, _ img: CGImage) -> CGRect {
        CGRect(x: r.x * Double(img.width), y: r.y * Double(img.height), width: r.w * Double(img.width), height: r.h * Double(img.height)).integral
    }
}

extension View {
    /// Cursor while hovering. Unlike a bare push/pop in onHover, it's restored when the view
    /// goes away under the pointer (e.g. Return ends cropping).
    func hoverCursor(_ cursor: NSCursor) -> some View { modifier(HoverCursor(cursor: cursor)) }
}

private struct HoverCursor: ViewModifier {
    let cursor: NSCursor
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !pushed { cursor.push(); pushed = true }
                if !inside, pushed { NSCursor.pop(); pushed = false }
            }
            .onDisappear {
                if pushed { NSCursor.pop(); pushed = false }
            }
    }
}

/// Where the canvas last laid out its unzoomed image (a class, so body can note it).
final class CanvasLayout {
    var base: CGRect = .zero
    var box: CGRect = .zero
    /// Preview pixels across the unzoomed image's width.
    var pixelsAcross: CGFloat = 0
    func update(base: CGRect, box: CGRect, pixelsAcross: Double) {
        self.base = base
        self.box = box
        self.pixelsAcross = CGFloat(pixelsAcross)
    }
}

/// Catches scroll-wheel and trackpad-pinch events over the canvas and reports them as zoom
/// factors at a point in the view (top-left origin). Uses a local event monitor, so SwiftUI
/// controls on top (crop handles) keep their clicks and drags.
struct ScrollZoomCatcher: NSViewRepresentable {
    let onZoom: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onZoom = onZoom
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) { v.onZoom = onZoom }

    final class CatcherView: NSView {
        var onZoom: ((CGFloat, CGPoint) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] e in
                guard let self, e.window === self.window, self.window?.attachedSheet == nil else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return e }
                let factor: CGFloat
                if e.type == .magnify {
                    factor = 1 + e.magnification
                } else {
                    // Mouse wheel notches are coarse, trackpad deltas fine-grained.
                    let dy = e.scrollingDeltaY
                    guard dy != 0 else { return e }
                    factor = exp(dy * (e.hasPreciseScrollingDeltas ? 0.01 : 0.1))
                }
                self.onZoom?(factor, p)
                return nil
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }
}

func fitRect(aspect: Double, in box: CGRect) -> CGRect {
    guard box.width > 0, box.height > 0, aspect > 0 else { return .zero }
    var w = box.width, h = box.width / aspect
    if h > box.height { h = box.height; w = h * aspect }
    return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
}

// MARK: Crop

struct CropOverlay: View {
    let imageRect: CGRect
    @EnvironmentObject var editor: EditorModel
    @State private var start: NormRect?

    enum Handle: CaseIterable { case tl, t, tr, r, br, b, bl, l }

    var body: some View {
        let c = editor.settings.crop
        let r = CGRect(x: imageRect.minX + c.x * imageRect.width, y: imageRect.minY + c.y * imageRect.height,
                       width: c.w * imageRect.width, height: c.h * imageRect.height)
        ZStack {
            Path { p in
                p.addRect(imageRect)
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            // Rule of thirds
            Path { p in
                for i in 1...2 {
                    let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                    p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
            .allowsHitTesting(false)

            Rectangle()
                .stroke(Color.white, lineWidth: 1)
                .background(Color.white.opacity(0.001))
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .gesture(drag(nil))
                .hoverCursor(.openHand)

            ForEach(Handle.allCases, id: \.self) { h in
                handleView(h)
                    .position(point(h, r))
                    .gesture(drag(h))
            }
        }
    }

    private func handleView(_ h: Handle) -> some View {
        let corner = [.tl, .tr, .br, .bl].contains(h)
        return Rectangle()
            .fill(Color.white)
            .frame(width: corner ? 12 : (h == .t || h == .b ? 26 : 5), height: corner ? 12 : (h == .l || h == .r ? 26 : 5))
            .padding(8)
            .contentShape(Rectangle())
    }

    private func point(_ h: Handle, _ r: CGRect) -> CGPoint {
        switch h {
        case .tl: return CGPoint(x: r.minX, y: r.minY)
        case .t: return CGPoint(x: r.midX, y: r.minY)
        case .tr: return CGPoint(x: r.maxX, y: r.minY)
        case .r: return CGPoint(x: r.maxX, y: r.midY)
        case .br: return CGPoint(x: r.maxX, y: r.maxY)
        case .b: return CGPoint(x: r.midX, y: r.maxY)
        case .bl: return CGPoint(x: r.minX, y: r.maxY)
        case .l: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    private func drag(_ h: Handle?) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if start == nil { start = editor.settings.crop }
                guard let s = start else { return }
                let dx = Double(v.translation.width / imageRect.width)
                let dy = Double(v.translation.height / imageRect.height)
                editor.settings.crop = CropOverlay.adjust(s, handle: h, dx: dx, dy: dy, ratio: editor.normalisedAspect())
            }
            .onEnded { _ in start = nil }
    }

    /// New crop for a handle drag; `ratio` is normalised width / height, nil for free.
    static func adjust(_ s: NormRect, handle: Handle?, dx: Double, dy: Double, ratio: Double?) -> NormRect {
        let minSize = 0.04
        guard let handle else {
            return NormRect(x: min(max(0, s.x + dx), 1 - s.w), y: min(max(0, s.y + dy), 1 - s.h), w: s.w, h: s.h)
        }
        var x0 = s.x, y0 = s.y, x1 = s.x + s.w, y1 = s.y + s.h
        switch handle {
        case .tl: x0 += dx; y0 += dy
        case .t: y0 += dy
        case .tr: x1 += dx; y0 += dy
        case .r: x1 += dx
        case .br: x1 += dx; y1 += dy
        case .b: y1 += dy
        case .bl: x0 += dx; y1 += dy
        case .l: x0 += dx
        }
        x0 = min(max(0, x0), x1 - minSize); x1 = max(min(1, x1), x0 + minSize)
        y0 = min(max(0, y0), y1 - minSize); y1 = max(min(1, y1), y0 + minSize)
        guard let ratio else { return NormRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0) }

        // Constrained: derive the dependent side, anchored on the opposite edge/corner, then fit in bounds.
        var w = x1 - x0, h = y1 - y0
        switch handle {
        case .t, .b: w = h * ratio
        case .l, .r: h = w / ratio
        default: if w / h > ratio { h = w / ratio } else { w = h * ratio }
        }
        let ax: Double, ay: Double  // anchor fractions: 0 = left/top fixed, 1 = right/bottom fixed, 0.5 = centred
        switch handle {
        case .tl: (ax, ay) = (1, 1)
        case .tr: (ax, ay) = (0, 1)
        case .br: (ax, ay) = (0, 0)
        case .bl: (ax, ay) = (1, 0)
        case .t: (ax, ay) = (0.5, 1)
        case .b: (ax, ay) = (0.5, 0)
        case .l: (ax, ay) = (1, 0.5)
        case .r: (ax, ay) = (0, 0.5)
        }
        let anchorX = ax == 0 ? s.x : (ax == 1 ? s.x + s.w : s.x + s.w / 2)
        let anchorY = ay == 0 ? s.y : (ay == 1 ? s.y + s.h : s.y + s.h / 2)
        // Largest size that still fits inside the frame from this anchor.
        let maxW = ax == 0 ? 1 - anchorX : (ax == 1 ? anchorX : 2 * min(anchorX, 1 - anchorX))
        let maxH = ay == 0 ? 1 - anchorY : (ay == 1 ? anchorY : 2 * min(anchorY, 1 - anchorY))
        let k = min(1, maxW / w, maxH / h)
        w *= k; h *= k
        return NormRect(x: anchorX - ax * w, y: anchorY - ay * h, w: w, h: h)
    }
}

// MARK: Inspector

struct InspectorView: View {
    @EnvironmentObject var editor: EditorModel
    @EnvironmentObject var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HistogramView(histogram: editor.histogram)
                    .frame(height: 80)

                section("Film") {
                    Picker("", selection: $editor.settings.mode) {
                        ForEach(FilmMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if editor.settings.mode != .positive {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(baseColor)
                                .frame(width: 22, height: 22)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.2)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Film base").font(.callout)
                                Text(editor.settings.filmBase == nil ? "Auto per frame" : "Measured")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                editor.tool = editor.tool == .pickBase ? .none : .pickBase
                            } label: { Image(systemName: "eyedropper") }
                                .help("Pick the film base from the rebate (B)")
                            if editor.settings.filmBase != nil {
                                Button { editor.settings.filmBase = nil } label: { Image(systemName: "xmark") }
                                    .help("Back to auto")
                            }
                        }
                    }
                    let locked = editor.settings.fixedLevels != nil
                    HStack(spacing: 8) {
                        Image(systemName: locked ? "lock.fill" : "lock.open")
                            .frame(width: 22)
                            .foregroundStyle(locked ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Colour balance").font(.callout)
                            Text(locked ? "Locked" : "Measured per frame")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if locked {
                            Button("Unlock") { app.unlockBalance() }
                                .help("Measure balance and levels per frame again, for the selected frames")
                        } else {
                            Button("Lock") { app.lockBalanceToSelection() }
                                .help("Keep this frame's colour balance and levels, and use them for all selected frames (⇧⌘L)")
                        }
                    }
                }

                section("Geometry") {
                    HStack {
                        Button { editor.rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }
                        Button { editor.rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }
                        Button { editor.flip() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                        Spacer()
                        Button(editor.tool == .crop ? "Done" : "Crop") {
                            editor.tool = editor.tool == .crop ? .none : .crop
                        }
                    }
                    HStack {
                        Button {
                            app.autoCropSelection()
                        } label: {
                            Label("Auto crop", systemImage: "viewfinder")
                        }
                        .disabled(app.autoCropping > 0)
                        .help("Straighten and crop to the detected film frame — applies to all selected frames (A)")
                        Button {
                            app.splitCurrentIntoFrames()
                        } label: {
                            Label("Split", systemImage: "rectangle.split.3x1")
                        }
                        .help("Find every frame in this scan; each extra frame becomes a virtual copy (⇧⌘K)")
                    }
                    HStack {
                        Picker("Aspect", selection: $editor.aspect) {
                            ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Button {
                            editor.aspectPortrait.toggle()
                            editor.applyAspect()
                        } label: {
                            Image(systemName: editor.aspectPortrait ? "rectangle.portrait" : "rectangle")
                        }
                        .disabled(editor.aspect == .free || editor.aspect == .original || editor.aspect == .r1x1)
                        .help("Landscape / portrait")
                    }
                    .onChange(of: editor.aspect) { _, _ in editor.applyAspect() }
                    AdjustSlider(title: "Straighten", value: $editor.settings.straighten, range: -10...10, def: 0, format: "%.1f°")
                    Button("Reset crop") { editor.settings.crop = .full }
                        .disabled(editor.settings.crop == .full)
                        .controlSize(.small)
                }

                section("Tone") {
                    AdjustSlider(title: "Exposure", value: $editor.settings.exposure, range: -2...2, def: 0)
                    AdjustSlider(title: "Contrast", value: $editor.settings.contrast, range: 0.4...2, def: 1)
                    AdjustSlider(title: "Midtones", value: $editor.settings.midtones, range: -1...1, def: 0)
                    AdjustSlider(title: "Highlights", value: $editor.settings.highlights, range: -1...1, def: 0)
                    AdjustSlider(title: "Shadows", value: $editor.settings.shadows, range: -1...1, def: 0)
                    AdjustSlider(title: "Whites", value: $editor.settings.whites, range: -1...1, def: 0)
                    AdjustSlider(title: "Blacks", value: $editor.settings.blacks, range: -1...1, def: 0)
                    AdjustSlider(title: "Print curve", value: $editor.settings.curve, range: 0...1, def: 0.3)
                }

                section("Colour") {
                    HStack {
                        Spacer()
                        Button {
                            editor.tool = editor.tool == .pickNeutral ? .none : .pickNeutral
                        } label: { Label("Pick neutral", systemImage: "eyedropper.halffull") }
                            .controlSize(.small)
                            .help("Click a grey in the picture to balance (W)")
                    }
                    AdjustSlider(title: "Temperature", value: $editor.settings.temperature, range: -1...1, def: 0)
                    AdjustSlider(title: "Tint", value: $editor.settings.tint, range: -1...1, def: 0)
                    AdjustSlider(title: "Saturation", value: $editor.settings.saturation, range: 0...2, def: 1)
                }

                section("Settings") {
                    HStack {
                        Button("Copy") { app.copySettings() }
                        Button("Paste") { app.pasteSettings() }.disabled(app.clipboard == nil)
                        Button("Sync (\(app.selection.count))") { app.syncToSelection() }
                            .disabled(app.selection.count < 2)
                            .help("Apply this frame's adjustments to all selected frames (⌘-click, ⇧-click or ⌘A in the filmstrip to select)")
                        Button("Roll") { app.syncToRoll() }
                            .help("Apply this frame's adjustments to every frame in the roll")
                    }
                    .controlSize(.small)
                    HStack {
                        Button("Reset frame") { app.resetCurrent() }
                        Spacer()
                        Button { editor.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                            .help("Undo (⌘Z)")
                        Button { editor.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                            .help("Redo (⇧⌘Z)")
                    }
                    .controlSize(.small)
                }
            }
            .padding(14)
        }
        .disabled(editor.url == nil)
        .background(Color(white: 0.12))
    }

    private var baseColor: Color {
        guard let b = editor.settings.filmBase, b.count == 3 else { return Color(white: 0.3) }
        let m = max(b.max() ?? 1, 1e-4)
        let e = b.map { Double(Processor.srgbEncode($0 / m)) }
        return Color(.sRGB, red: e[0], green: e[1], blue: e[2])
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

struct AdjustSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let def: Double
    var format = "%+.2f"

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { value = def }
            .help("Double-click to reset")
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
    }
}

struct HistogramView: View {
    let histogram: Histogram?

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.07)))
            guard let h = histogram else { return }
            ctx.blendMode = .plusLighter
            for (bins, color) in [(h.r, Color.red), (h.g, Color.green), (h.b, Color.blue)] {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height))
                for (i, v) in bins.enumerated() {
                    p.addLine(to: CGPoint(x: CGFloat(i) / 255 * size.width, y: size.height * (1 - CGFloat(v))))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                ctx.fill(p, with: .color(color.opacity(0.55)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
