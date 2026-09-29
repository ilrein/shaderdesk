// Composites the rendered icon art into a macOS app icon (squircle, rim light,
// sheen, shadow) and writes a 1024 px PNG.  usage: make-icon <art.png> <out.png>
import AppKit

let args = CommandLine.arguments
let art = NSImage(contentsOfFile: args[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let S = 1024.0, inset = 100.0, side = S - inset * 2, radius = side * 0.225
let body = CGRect(x: inset, y: inset, width: side, height: side)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

// drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.45))
ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
ctx.restoreGState()

// the art, clipped
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
ctx.draw(art, in: body)
// soft sheen from the top, like light on glass
let sheen = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0.0)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY + 40), options: [])
ctx.restoreGState()

// rim light: brighter along the top edge, fading down the sides
ctx.saveGState()
ctx.addPath(shape); ctx.setLineWidth(4); ctx.replacePathWithStrokedPath(); ctx.clip()
let rim = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 1, alpha: 0.35), CGColor(gray: 1, alpha: 0.06), CGColor(gray: 1, alpha: 0.12)] as CFArray,
                     locations: [0, 0.55, 1])!
ctx.drawLinearGradient(rim, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
ctx.restoreGState()

let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
