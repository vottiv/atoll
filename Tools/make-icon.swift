import AppKit

// Иконка Atoll: кольцо атолла и «островок»-капсула в центре на спокойном градиенте.
// Запуск: swift Tools/make-icon.swift  -> Resources/Atoll.icns
let size: CGFloat = 1024
let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a) }
func gradient(_ stops: [CGColor]) -> CGGradient { CGGradient(colorsSpace: space, colors: stops as CFArray, locations: nil)! }

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0, 0, 0, 0.4))
ctx.addPath(tilePath); ctx.setFillColor(color(20, 24, 60)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
ctx.drawLinearGradient(gradient([color(52, 214, 200), color(40, 110, 230), color(70, 50, 190)]),
                       start: CGPoint(x: 140, y: 924), end: CGPoint(x: 884, y: 100), options: [])

// Кольцо атолла.
let center = CGPoint(x: 512, y: 500)
let radius: CGFloat = 255
let ringWidth: CGFloat = 70
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(10, 20, 80, 0.4))
ctx.setStrokeColor(color(255, 255, 255, 0.97))
ctx.setLineWidth(ringWidth)
ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
ctx.restoreGState()

// «Вырез»: тёмная капсула, перекрывающая кольцо сверху.
let pill = CGRect(x: 512 - 120, y: center.y + radius - 34, width: 240, height: 68)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: color(0, 0, 20, 0.5))
ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 34, cornerHeight: 34, transform: nil))
ctx.setFillColor(color(12, 14, 40)); ctx.fillPath()
ctx.restoreGState()

// Мягкий блик сверху.
ctx.drawLinearGradient(gradient([color(255, 255, 255, 0.18), color(255, 255, 255, 0)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 540), options: [])
ctx.restoreGState()

guard let image = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
let fm = FileManager.default
let set = "/tmp/Atoll.iconset"
try? fm.removeItem(atPath: set)
try fm.createDirectory(atPath: set, withIntermediateDirectories: true)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/icon-1024.png"))
for (name, px) in [("16", 16), ("16@2x", 32), ("32", 32), ("32@2x", 64), ("128", 128), ("128@2x", 256), ("256", 256), ("256@2x", 512), ("512", 512), ("512@2x", 1024)] {
    let target = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSImage(cgImage: image, size: NSSize(width: size, height: size)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try target.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set, "-o", "Resources/Atoll.icns"]
try p.run(); p.waitUntilExit()
