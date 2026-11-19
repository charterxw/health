import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

// Code-drawn vector mark, rendered as opaque PNGs for the iPhone asset catalog.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let catalog = root.appendingPathComponent("App/Assets.xcassets")
let folder = catalog.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
var images: [[String: String]] = []
var sizes: [(Int, Int, String)] = []
for size in [20, 29, 40, 60] { for scale in [2, 3] { sizes.append((size, scale, "iphone")) } }
sizes.append((1024, 1, "ios-marketing"))
for (size, scale, idiom) in sizes {
    let pixels = size * scale
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.setFillColor(CGColor(srgbRed: 0.02, green: 0.40, blue: 0.85, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    for rect in [CGRect(x: 210, y: 476, width: 604, height: 72),
                 CGRect(x: 270, y: 344, width: 82, height: 336),
                 CGRect(x: 672, y: 344, width: 82, height: 336),
                 CGRect(x: 174, y: 408, width: 72, height: 208),
                 CGRect(x: 778, y: 408, width: 72, height: 208)] {
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 28, cornerHeight: 28, transform: nil))
        context.fillPath()
    }
    let filename = "icon-\(size)@\(scale)x.png"
    let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent(filename) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
    images.append(["filename": filename, "idiom": idiom, "scale": "\(scale)x", "size": "\(size)x\(size)"])
}
let info: [String: Any] = ["info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]).write(to: catalog.appendingPathComponent("Contents.json"))
var contents = info; contents["images"] = images
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("Contents.json"))
print("Generated opaque iPhone app icons.")
