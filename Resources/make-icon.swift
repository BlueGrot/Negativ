// Renders the app icon: a white "N" whose two vertical strokes are strips of film with
// sprocket holes, on a black tile.
//   swift Resources/make-icon.swift <out.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Work in top-left coordinates.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255,
                                            CGFloat(hex & 255) / 255, a])!
}

// Tile: the macOS icon grid (824 pt square at 100 pt inset, ~185 pt corners).
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: color(0x000000, 0.45))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x0A0A0B))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
// Light-table glow behind the letter.
let glow = CGGradient(colorsSpace: space, colors: [color(0x2A2A2C), color(0x121213), color(0x070708)] as CFArray,
                      locations: [0, 0.55, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 512), endRadius: 560, options: [.drawsAfterEndLocation])
// Hairline inner edge.
ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.setStrokeColor(color(0xFFFFFF, 0.08))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// The N.
let left: CGFloat = 262, right: CGFloat = 762, top: CGFloat = 240, bottom: CGFloat = 784
let stem: CGFloat = 176      // film strip width
let drop: CGFloat = 250      // diagonal's height where it meets each stem
let leftStem = CGRect(x: left, y: top, width: stem, height: bottom - top)
let rightStem = CGRect(x: right - stem, y: top, width: stem, height: bottom - top)
// The diagonal spans between the stems' inner edges, from the top of the left to the bottom
// of the right, so the film strips keep all their holes.
let diagonal = CGMutablePath()
diagonal.move(to: CGPoint(x: leftStem.maxX, y: top))
diagonal.addLine(to: CGPoint(x: rightStem.minX, y: bottom - drop))
diagonal.addLine(to: CGPoint(x: rightStem.minX, y: bottom))
diagonal.addLine(to: CGPoint(x: leftStem.maxX, y: top + drop))
diagonal.closeSubpath()

// Sprocket holes down the outer edge of each stem, spread so the space above the first and
// below the last equals the space between holes.
let holeW: CGFloat = 44, holeH: CGFloat = 58, edge: CGFloat = 20
let height = bottom - top
let count = max(2, Int(((height - 32) / (holeH + 32)).rounded()))
let gap = (height - CGFloat(count) * holeH) / CGFloat(count + 1)
var holes: [CGRect] = []
for cx in [leftStem.minX + edge + holeW / 2, rightStem.maxX - edge - holeW / 2] {
    for i in 0..<count {
        let y = top + gap + CGFloat(i) * (holeH + gap)
        holes.append(CGRect(x: cx - holeW / 2, y: y, width: holeW, height: holeH))
    }
}

let letter = CGMutablePath()
letter.addRect(leftStem)
letter.addRect(rightStem)
letter.addPath(diagonal)

// Draw the letter into its own layer so the holes can be punched through it.
let layer = CGLayer(ctx, size: CGSize(width: size, height: size), auxiliaryInfo: nil)!
let l = layer.context!
l.translateBy(x: 0, y: CGFloat(size))
l.scaleBy(x: 1, y: -1)
l.saveGState()
l.addPath(letter)
l.clip()
let white = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xF1F1F1), color(0xD6D6D6)] as CFArray,
                       locations: [0, 0.5, 1])!
l.drawLinearGradient(white, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
l.restoreGState()
l.setBlendMode(.clear)
for h in holes {
    l.addPath(CGPath(roundedRect: h, cornerWidth: 10, cornerHeight: 10, transform: nil))
}
l.fillPath()

ctx.saveGState()
// Undo the flip for layer drawing (the layer has its own).
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.55))
ctx.draw(layer, at: .zero)
ctx.restoreGState()

let image = ctx.makeImage()!
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print(out.path)
