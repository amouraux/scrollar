import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// The supplied artwork has a transparent background; an app icon must be opaque. Put the symbol,
// slightly enlarged and centred, on a white background that cools very slightly towards the foot,
// so it does not dissolve into a white dock.
let args = CommandLine.arguments
let source = URL(fileURLWithPath: args[1]) as CFURL
let out = URL(fileURLWithPath: args[2]) as CFURL
guard let src = CGImageSourceCreateWithURL(source, nil), let art = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("cannot read"); exit(1) }

let size = 1024
let space = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.interpolationQuality = .high

let top = CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1)
let foot = CGColor(red: 0.90, green: 0.94, blue: 0.99, alpha: 1)
let gradient = CGGradient(colorsSpace: space, colors: [top, foot] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// The symbol's box in the artwork is x 279...973, y 283...1015 of 1254; its centre is (626, 649) from the top.
let scale = 1.05
let artW = Double(art.width) * scale, artH = Double(art.height) * scale
let centreFromBottom = Double(art.height) - 649
let x0 = Double(size) / 2 - 626 * scale
let y0 = Double(size) / 2 - centreFromBottom * scale
ctx.draw(art, in: CGRect(x: x0, y: y0, width: artW, height: artH))

guard let result = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(out, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, result, nil)
guard CGImageDestinationFinalize(dest) else { print("write failed"); exit(1) }
print("wrote \(size)x\(size)")
