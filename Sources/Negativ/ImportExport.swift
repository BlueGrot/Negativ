import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct SourceFile: Identifiable, Hashable {
    let url: URL
    let date: Date
    let size: Int64
    var id: URL { url }
}

enum CardScanner {
    /// All supported images under DCIM (or the folder itself if it has none), newest first.
    static func scan(_ root: URL) -> [SourceFile] {
        let dcim = root.appendingPathComponent("DCIM")
        let base = FileManager.default.fileExists(atPath: dcim.path) ? dcim : root
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [SourceFile] = []
        for case let url as URL in e where Pipeline.isSupported(url) {
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile == true else { continue }
            out.append(SourceFile(url: url, date: v?.contentModificationDate ?? .distantPast, size: Int64(v?.fileSize ?? 0)))
        }
        return out.sorted { ($0.date, $0.url.lastPathComponent) > ($1.date, $1.url.lastPathComponent) }
    }

    /// The files that already exist in one of the rolls (same name and size).
    static func alreadyImported(_ files: [SourceFile], rolls: [URL]) -> Set<URL> {
        var known = Set<String>()
        for roll in rolls {
            let list = (try? FileManager.default.contentsOfDirectory(at: roll, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
            for f in list where Pipeline.isSupported(f) {
                let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                known.insert("\(f.lastPathComponent.lowercased())|\(size)")
            }
        }
        return Set(files.filter { known.contains("\($0.url.lastPathComponent.lowercased())|\($0.size)") }.map(\.url))
    }

    /// Copies files into `dest`, renaming on name clashes. Calls progress on the main queue.
    static func copy(_ files: [SourceFile], to dest: URL, progress: @escaping (Int) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for (i, f) in files.enumerated() {
            var target = dest.appendingPathComponent(f.url.lastPathComponent)
            var n = 1
            while fm.fileExists(atPath: target.path) {
                let stem = f.url.deletingPathExtension().lastPathComponent
                target = dest.appendingPathComponent("\(stem)-\(n).\(f.url.pathExtension)")
                n += 1
            }
            try fm.copyItem(at: f.url, to: target)
            DispatchQueue.main.async { progress(i + 1) }
        }
    }
}

struct ExportOptions {
    enum Format: String, CaseIterable, Identifiable {
        case jpeg = "JPEG", tiff16 = "TIFF 16-bit"
        var id: String { rawValue }
        var ext: String { self == .jpeg ? "jpg" : "tif" }
    }
    var format: Format = .jpeg
    var quality = 0.92
    var longEdge: Int? = nil
    var dest: URL
}

enum ExportError: LocalizedError {
    case decode(String), write(String)
    var errorDescription: String? {
        switch self {
        case .decode(let n): return "Could not read \(n)"
        case .write(let n): return "Could not write \(n)"
        }
    }
}

enum Exporter {
    /// `name` is the output file name without extension (differs from the scan's for virtual copies).
    static func export(_ url: URL, name outName: String? = nil, settings: EditSettings, options: ExportOptions) throws -> URL {
        let name = url.lastPathComponent
        // Levels come from the same preview-sized analysis the editor uses, so the export matches the screen.
        guard let preview = Pipeline.loadPreview(url, settings: settings),
              let src = Pipeline.sourceImage(url, maxDim: nil) else { throw ExportError.decode(name) }
        let levels = Processor.analyze(preview, settings: settings)
        let params = ToneParams(settings: settings, levels: levels)

        var img = Pipeline.applyGeometry(src, settings)
        let W = img.extent.width, H = img.extent.height
        let c = settings.crop
        let rect = CGRect(x: (c.x * W).rounded(), y: ((1 - c.y - c.h) * H).rounded(),
                          width: (c.w * W).rounded(), height: (c.h * H).rounded())
        img = Pipeline.toOrigin(img.cropped(to: rect))
        if let le = options.longEdge, max(rect.width, rect.height) > CGFloat(le) {
            img = Pipeline.lanczos(img, scale: CGFloat(le) / max(rect.width, rect.height))
        }
        let w = max(1, Int(img.extent.width)), h = max(1, Int(img.extent.height))

        // Render and process in horizontal strips to keep memory bounded on big files.
        let comps = options.format == .jpeg ? 4 : 3
        let bytesPerComp = options.format == .jpeg ? 1 : 2
        var out = Data(count: w * h * comps * bytesPerComp)
        let stripRows = 256
        var strip = [Float](repeating: 0, count: w * stripRows * 4)
        var row = 0
        while row < h {
            let rows = min(stripRows, h - row)
            // Row 0 of the bitmap is the top of the bounds; CI's y axis points up.
            let bounds = CGRect(x: img.extent.minX, y: img.extent.minY + CGFloat(h - row - rows), width: CGFloat(w), height: CGFloat(rows))
            strip.withUnsafeMutableBytes { p in
                Pipeline.context.render(img, toBitmap: p.baseAddress!, rowBytes: w * 16, bounds: bounds, format: .RGBAf, colorSpace: Pipeline.linearSpace)
            }
            strip.withUnsafeBufferPointer { s in
                out.withUnsafeMutableBytes { d in
                    if options.format == .jpeg {
                        let dst = d.bindMemory(to: UInt8.self).baseAddress! + row * w * 4
                        Processor.process8(s.baseAddress!, dst, width: w, height: rows, params: params)
                    } else {
                        let dst = d.bindMemory(to: UInt16.self).baseAddress! + row * w * 3
                        Processor.process16(s.baseAddress!, dst, width: w, height: rows, params: params)
                    }
                }
            }
            row += rows
        }

        let stem = outName ?? url.deletingPathExtension().lastPathComponent
        var target = options.dest.appendingPathComponent(stem).appendingPathExtension(options.format.ext)
        // Never overwrite the scan itself (TIFF export into the roll folder on a case-insensitive disk).
        if target.standardizedFileURL.path.lowercased() == url.standardizedFileURL.path.lowercased() {
            target = options.dest.appendingPathComponent(stem + "-positive").appendingPathExtension(options.format.ext)
        }
        let cg: CGImage?
        if options.format == .jpeg {
            cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: Pipeline.srgb,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: CGDataProvider(data: out as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        } else {
            cg = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: w * 6, space: Pipeline.srgb,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                         provider: CGDataProvider(data: out as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        let type = options.format == .jpeg ? UTType.jpeg : UTType.tiff
        guard let cg, let dest = CGImageDestinationCreateWithURL(target as CFURL, type.identifier as CFString, 1, nil) else {
            throw ExportError.write(target.lastPathComponent)
        }
        var props = metadata(from: url)
        if options.format == .jpeg {
            props[kCGImageDestinationLossyCompressionQuality] = options.quality
        } else {
            var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = 5 // LZW
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.write(target.lastPathComponent) }
        return target
    }
}

extension Exporter {
    /// Capture date, camera, lens and exposure data from the scan, for the exported file.
    /// Orientation is baked into the pixels, so it's reset.
    static func metadata(from url: URL) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [:] }
        var out: [CFString: Any] = [:]
        for k in [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let d = p[k] { out[k] = d }
        }
        if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            tiff[kCGImagePropertyTIFFSoftware] = "Negativ"
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        out[kCGImagePropertyOrientation] = 1
        return out
    }
}

/// Processed thumbnails from the camera's embedded preview.
final class ThumbCache {
    static let shared = ThumbCache()
    private let linear = NSCache<NSString, LinearImage>()
    /// Renderings made by the editor (exact look), keyed by frame and settings.
    private let rendered = NSCache<NSString, CGImage>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .utility
        return q
    }()

    init() {
        linear.totalCostLimit = 300 << 20
        rendered.countLimit = 300
    }

    private func renderedKey(_ frameKey: String, _ s: EditSettings) -> NSString {
        "\(frameKey)|\(s.hashValue)" as NSString
    }

    func store(_ image: CGImage, for frameKey: String, settings: EditSettings) {
        rendered.setObject(image, forKey: renderedKey(frameKey, settings))
    }

    /// The editor's own rendering of this frame with exactly these settings, if there is one.
    func rendered(for frameKey: String, settings: EditSettings) -> CGImage? {
        rendered.object(forKey: renderedKey(frameKey, settings))
    }

    /// Cancelling the calling task (a cell scrolled out of view) drops the work if it hasn't started.
    /// `accurate` decodes the scan itself (matches the editor, slower); otherwise the camera's
    /// embedded preview is used (fast, fine for browsing a card).
    func thumbnail(_ url: URL, settings: EditSettings, maxDim: Int = 360, accurate: Bool = true) async -> CGImage? {
        let op = BlockOperation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
                // A cancelled operation never runs its block, but always completes.
                let once = ResumeOnce(cont)
                op.addExecutionBlock { once.resume(self.build(url, settings: settings, maxDim: maxDim, accurate: accurate)) }
                op.completionBlock = { once.resume(nil) }
                if Task.isCancelled { op.cancel() }
                queue.addOperation(op)
            }
        } onCancel: {
            op.cancel()
        }
    }

    private func build(_ url: URL, settings: EditSettings, maxDim: Int, accurate: Bool) -> CGImage? {
        let key = "\(url.path)|\(settings.geometryKey)|\(maxDim)|\(accurate)" as NSString
        let lin: LinearImage
        if let c = linear.object(forKey: key) {
            lin = c
        } else {
            let loaded = accurate ? Pipeline.loadPreview(url, settings: settings, maxDim: CGFloat(maxDim))
                                  : Pipeline.loadThumbnail(url, settings: settings, maxDim: maxDim)
            guard let l = loaded else { return nil }
            linear.setObject(l, forKey: key, cost: l.pixels.count * 4)
            lin = l
        }
        let levels = Processor.analyze(lin, settings: settings)
        guard let img = Processor.render(lin, settings: settings, levels: levels, negative: false)?.0 else { return nil }
        let c = settings.crop
        let r = CGRect(x: c.x * Double(img.width), y: c.y * Double(img.height), width: c.w * Double(img.width), height: c.h * Double(img.height)).integral
        return img.cropping(to: r) ?? img
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private var cont: CheckedContinuation<CGImage?, Never>?
    private let lock = NSLock()
    init(_ cont: CheckedContinuation<CGImage?, Never>) { self.cont = cont }
    func resume(_ value: CGImage?) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
