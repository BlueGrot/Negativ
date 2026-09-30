import Foundation
import CoreImage
import ImageIO

/// Scene-linear RGBA float image, row 0 = top.
final class LinearImage: @unchecked Sendable {
    let width: Int
    let height: Int
    let pixels: [Float]
    init(width: Int, height: Int, pixels: [Float]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Mean linear RGB in a small box around a normalised point.
    func sample(nx: Double, ny: Double, radius: Int = 4) -> SIMD3<Float> {
        let cx = min(width - 1, max(0, Int(nx * Double(width))))
        let cy = min(height - 1, max(0, Int(ny * Double(height))))
        var sum = SIMD3<Float>(repeating: 0)
        var n: Float = 0
        for y in max(0, cy - radius)...min(height - 1, cy + radius) {
            for x in max(0, cx - radius)...min(width - 1, cx + radius) {
                let i = (y * width + x) * 4
                sum += SIMD3(pixels[i], pixels[i + 1], pixels[i + 2])
                n += 1
            }
        }
        return sum / max(n, 1)
    }
}

enum Pipeline {
    static let previewMaxDim: CGFloat = 2200
    static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    static let context = CIContext(options: [
        .workingColorSpace: linearSpace,
        .cacheIntermediates: false,
        .name: "Negativ",
    ])

    static let rawExtensions: Set<String> = [
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "dng", "raf", "orf", "rw2",
        "pef", "srw", "3fr", "iiq", "erf", "kdc", "mos", "mrw", "x3f", "rwl", "fff",
    ]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "tif", "tiff", "png", "heic", "heif"]

    static func isRaw(_ url: URL) -> Bool { rawExtensions.contains(url.pathExtension.lowercased()) }
    static func isSupported(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased()
        return rawExtensions.contains(e) || imageExtensions.contains(e)
    }

    /// Decoded, scene-linear source image with camera orientation applied.
    static func sourceImage(_ url: URL, maxDim: CGFloat?) -> CIImage? {
        if isRaw(url), let raw = CIRAWFilter(imageURL: url) {
            raw.boostAmount = 0 // linear response, no camera tone curve
            if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = 0 } // keep the grain
            if let maxDim {
                let m = max(raw.nativeSize.width, raw.nativeSize.height)
                if m > maxDim { raw.scaleFactor = Float(maxDim / m) }
            }
            if let out = raw.outputImage { return out }
        }
        guard var img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        if let maxDim {
            let m = max(img.extent.width, img.extent.height)
            if m > maxDim { img = lanczos(img, scale: maxDim / m) }
        }
        return img
    }

    /// Camera's embedded preview (fast), used for thumbnails.
    static func thumbnailSource(_ url: URL, maxDim: Int) -> CIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return CIImage(cgImage: cg)
    }

    static func lanczos(_ img: CIImage, scale: CGFloat) -> CIImage {
        img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
    }

    static func toOrigin(_ img: CIImage) -> CIImage {
        img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
    }

    /// Rotation, flip and straighten. Straightening crops to the largest same-aspect rect with no empty corners.
    static func applyGeometry(_ input: CIImage, _ s: EditSettings) -> CIImage {
        var img = toOrigin(input)
        let orients: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        let t = ((s.quarterTurns % 4) + 4) % 4
        if t != 0 { img = toOrigin(img.oriented(orients[t])) }
        if s.flipH { img = toOrigin(img.oriented(.upMirrored)) }
        if abs(s.straighten) > 0.001 {
            let w = img.extent.width, h = img.extent.height
            let a = CGFloat(s.straighten) * .pi / 180
            let c = abs(cos(a)), sn = abs(sin(a))
            let scale = min(w / (w * c + h * sn), h / (w * sn + h * c))
            let rot = CGAffineTransform(translationX: w / 2, y: h / 2).rotated(by: -a).translatedBy(x: -w / 2, y: -h / 2)
            img = img.clampedToExtent().transformed(by: rot)
            let cw = (w * scale).rounded(.down), ch = (h * scale).rounded(.down)
            img = toOrigin(img.cropped(to: CGRect(x: ((w - cw) / 2).rounded(), y: ((h - ch) / 2).rounded(), width: cw, height: ch)))
        }
        return img
    }

    /// For zoomed-in detail: keeps the decoded full-resolution scan between renders.
    static let detailContext = CIContext(options: [
        .workingColorSpace: linearSpace,
        .cacheIntermediates: true,
        .name: "NegativDetail",
    ])

    /// The part `rect` (normalised, of the oriented frame) of the full-resolution scan, at most
    /// `maxPixels` in size (never enlarged past the scan's own pixels).
    static func renderDetail(_ source: CIImage, settings: EditSettings, rect r: NormRect, maxPixels: CGSize) -> LinearImage? {
        var img = applyGeometry(source, settings)
        let W = img.extent.width, H = img.extent.height
        let crop = CGRect(x: r.x * W, y: (1 - r.y - r.h) * H, width: r.w * W, height: r.h * H).integral.intersection(img.extent)
        guard crop.width >= 2, crop.height >= 2 else { return nil }
        img = toOrigin(img.cropped(to: crop))
        let scale = min(1, maxPixels.width / crop.width, maxPixels.height / crop.height)
        if scale < 0.999 { img = lanczos(img, scale: scale) }
        return renderLinear(img, context: detailContext)
    }

    static func renderLinear(_ image: CIImage, context: CIContext = Pipeline.context) -> LinearImage {
        let w = max(1, Int(image.extent.width)), h = max(1, Int(image.extent.height))
        var px = [Float](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { ptr in
            context.render(image, toBitmap: ptr.baseAddress!, rowBytes: w * 16,
                           bounds: CGRect(x: image.extent.minX, y: image.extent.minY, width: CGFloat(w), height: CGFloat(h)),
                           format: .RGBAf, colorSpace: linearSpace)
        }
        return LinearImage(width: w, height: h, pixels: px)
    }

    /// Decodes a frame once to an in-memory linear image (no geometry), so rotating and
    /// straightening can re-render from memory instead of decoding the RAW again.
    static func decodePreview(_ url: URL, maxDim: CGFloat = previewMaxDim) -> CIImage? {
        guard let src = sourceImage(url, maxDim: maxDim) else { return nil }
        let lin = renderLinear(toOrigin(src))
        let data = lin.pixels.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: lin.width * 16,
                       size: CGSize(width: lin.width, height: lin.height), format: .RGBAf, colorSpace: linearSpace)
    }

    /// Full oriented frame (uncropped) at preview resolution.
    static func loadPreview(_ url: URL, settings: EditSettings, maxDim: CGFloat = previewMaxDim) -> LinearImage? {
        guard let src = sourceImage(url, maxDim: maxDim) else { return nil }
        return renderLinear(applyGeometry(src, settings))
    }

    static func loadThumbnail(_ url: URL, settings: EditSettings, maxDim: Int) -> LinearImage? {
        guard let src = thumbnailSource(url, maxDim: maxDim) ?? sourceImage(url, maxDim: CGFloat(maxDim)) else { return nil }
        return renderLinear(applyGeometry(src, settings))
    }
}
