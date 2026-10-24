import AppKit
import SwiftUI

@MainActor
enum SnapshotWriter {
    static func write(model: IslandModel) throws {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        model.notchWidth = 220
        model.notchHeight = 38
        model.locksExpansion = true
        model.usesFlatBackdrop = true

        try writeScene(model: model, expanded: false, hovered: false, to: folder.appendingPathComponent("collapsed.png"))
        try writeScene(model: model, expanded: false, hovered: true, to: folder.appendingPathComponent("hovered.png"))
        try writeScene(model: model, expanded: true, hovered: false, to: folder.appendingPathComponent("expanded.png"))
        print("SNAPSHOT \(folder.path)")
        fflush(stdout)
    }

    private static func writeScene(model: IslandModel, expanded: Bool, hovered: Bool, to url: URL) throws {
        model.isExpanded = expanded
        model.isHovered = hovered
        let islandSize = model.windowSize
        let scene = NSSize(width: 980, height: expanded ? 340 : 190)
        guard let island = renderIsland(model: model, size: islandSize) else {
            throw NSError(domain: "Island", code: 1, userInfo: [NSLocalizedDescriptionKey: "render failed"])
        }
        guard let sceneImage = compose(island: island, islandSize: islandSize, scene: scene) else {
            throw NSError(domain: "Island", code: 2, userInfo: [NSLocalizedDescriptionKey: "compose failed"])
        }
        guard let data = pngData(sceneImage) else {
            throw NSError(domain: "Island", code: 3, userInfo: [NSLocalizedDescriptionKey: "png failed"])
        }
        try data.write(to: url)
    }

    private static func renderIsland(model: IslandModel, size: NSSize) -> NSImage? {
        let view = IslandView(model: model)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = false
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        guard let cgImage = renderer.cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: size)
    }

    private static func compose(island: NSImage, islandSize: NSSize, scene: NSSize) -> NSImage? {
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(scene.width * scale),
            pixelsHigh: Int(scene.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = scene

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.setAllowsAntialiasing(true)

        drawWallpaper(in: NSRect(origin: .zero, size: scene), context: cg)
        drawMenuBar(in: NSRect(x: 0, y: scene.height - 38, width: scene.width, height: 38))

        let islandRect = NSRect(
            x: (scene.width - islandSize.width) / 2,
            y: scene.height - islandSize.height,
            width: islandSize.width,
            height: islandSize.height
        )
        island.draw(in: islandRect, from: .zero, operation: .sourceOver, fraction: 1)
        drawCamera(scene: scene)

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: scene)
        image.addRepresentation(rep)
        return image
    }

    private static func drawWallpaper(in rect: NSRect, context: CGContext) {
        let colors = [
            CGColor(red: 0.16, green: 0.20, blue: 0.27, alpha: 1),
            CGColor(red: 0.33, green: 0.40, blue: 0.48, alpha: 1),
            CGColor(red: 0.12, green: 0.16, blue: 0.22, alpha: 1),
        ] as CFArray
        let locations: [CGFloat] = [0, 0.55, 1]
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: locations
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.maxY),
                end: CGPoint(x: rect.maxX, y: rect.minY),
                options: []
            )
        }

    }

    private static func drawMenuBar(in rect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        rect.fill()

        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]
        let left = "Finder     Файл     Правка     Вид" as NSString
        left.draw(at: NSPoint(x: 16, y: rect.minY + 11), withAttributes: attrs)

        let clock = "22:48" as NSString
        let clockSize = clock.size(withAttributes: attrs)
        clock.draw(
            at: NSPoint(x: rect.maxX - clockSize.width - 18, y: rect.minY + 11),
            withAttributes: attrs
        )
    }

    /// Только на снимке: на самом Mac здесь физическая камера, в окне её нет.
    private static func drawCamera(scene: NSSize) {
        let center = NSPoint(x: scene.width / 2, y: scene.height - 18)
        let lens = NSRect(x: center.x - 5.5, y: center.y - 5.5, width: 11, height: 11)
        NSColor(calibratedWhite: 0.2, alpha: 1).setFill()
        NSBezierPath(ovalIn: lens).fill()
        NSColor(calibratedWhite: 0.05, alpha: 1).setFill()
        NSBezierPath(ovalIn: lens.insetBy(dx: 2.4, dy: 2.4)).fill()
        NSColor.white.withAlphaComponent(0.7).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 1.1, y: center.y + 0.8, width: 2.2, height: 2.2)).fill()
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
