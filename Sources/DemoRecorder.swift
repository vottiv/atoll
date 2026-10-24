import AppKit
import SwiftUI

/// Запись демо-анимации для README: `Atoll --preview --record <папка>`.
/// Остров рисуется настоящий, с живым стеклом, поверх собственного фона вместо чужих окон:
/// в кадр не попадает ничего личного. Кадры и кадры-превью лежат в указанной папке.
@MainActor
final class DemoRecorder {
    private let model: IslandModel
    private let panel: NSPanel
    private let output: URL
    private var frames: [(time: CFTimeInterval, image: CGImage)] = []
    private var windows: [NSWindow] = []
    private var timer: Timer?
    private var startedAt: CFTimeInterval = 0

    private let regionSize = CGSize(width: 620, height: 250)

    init(model: IslandModel, panel: NSPanel, output: URL) {
        self.model = model
        self.panel = panel
        self.output = output
    }

    func run() {
        guard let screen = DisplayLayout.builtInScreen() ?? NSScreen.main else { exit(1) }
        try? FileManager.default.createDirectory(at: output.appendingPathComponent("frames"), withIntermediateDirectories: true)
        let region = NSRect(
            x: screen.frame.midX - regionSize.width / 2,
            y: screen.frame.maxY - regionSize.height,
            width: regionSize.width,
            height: regionSize.height
        )
        // Фон под островом, чтобы стекло отражало красивую сцену, а не рабочий стол.
        let backdrop = makeWindow(region, level: .statusBar, view: DemoBackdrop(notchHeight: model.notchHeight))
        windows.append(backdrop)
        backdrop.orderFrontRegardless()
        panel.orderFrontRegardless()
        // Физический вырез: поверх всего, как настоящий.
        let notchFrame = NSRect(
            x: screen.frame.midX - model.notchWidth / 2,
            y: screen.frame.maxY - model.notchHeight,
            width: model.notchWidth,
            height: model.notchHeight
        )
        let notch = makeWindow(notchFrame, level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1), view: DemoNotch())
        windows.append(notch)
        notch.orderFrontRegardless()

        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let captureRect = CGRect(x: region.minX, y: primaryHeight - region.maxY, width: region.width, height: region.height)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.startedAt = CACurrentMediaTime()
            self.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.capture(captureRect)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.model.openWidget() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { self.model.closeWidget() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.4) { self.finish() }
        }
    }

    private func makeWindow<V: View>(_ frame: NSRect, level: NSWindow.Level, view: V) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = level
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: view)
        window.setFrame(frame, display: true)
        return window
    }

    private func capture(_ rect: CGRect) {
        guard let image = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else { return }
        frames.append((CACurrentMediaTime() - startedAt, image))
    }

    private func finish() {
        timer?.invalidate()
        guard !frames.isEmpty else { exit(1) }
        let fps = 30.0
        let total = frames.last!.time
        var index = 0
        var written = 0
        var step = 0
        while Double(step) / fps <= total {
            let t = Double(step) / fps
            while index + 1 < frames.count, frames[index + 1].time <= t { index += 1 }
            write(frames[index].image, to: output.appendingPathComponent(String(format: "frames/f%04d.png", written)))
            written += 1
            step += 1
        }
        if let still = frames.last(where: { $0.time < 0.5 }) {
            write(still.image, to: output.appendingPathComponent("still-collapsed.png"))
        }
        if let still = frames.last(where: { $0.time < 3.4 }) {
            write(still.image, to: output.appendingPathComponent("still-expanded.png"))
        }
        print("RECORDED \(written) frames captured=\(frames.count) to \(output.path)")
        fflush(stdout)
        exit(0)
    }

    private func write(_ image: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

private struct DemoBackdrop: View {
    var notchHeight: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.09, blue: 0.24), Color(red: 0.18, green: 0.10, blue: 0.36), Color(red: 0.05, green: 0.22, blue: 0.34)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle().fill(Color(red: 1.0, green: 0.45, blue: 0.35)).frame(width: 230, height: 230).blur(radius: 60).offset(x: -190, y: 90)
            Circle().fill(Color(red: 0.2, green: 0.8, blue: 0.9)).frame(width: 260, height: 260).blur(radius: 70).offset(x: 200, y: 110)
            Circle().fill(Color(red: 0.75, green: 0.35, blue: 1.0)).frame(width: 200, height: 200).blur(radius: 60).offset(x: 20, y: 150)
            // Строка меню, как на реальном Mac.
            HStack(spacing: 18) {
                Text("").font(.system(size: 13, weight: .bold))
                Text("Finder").font(.system(size: 13, weight: .semibold))
                Text("File").font(.system(size: 13))
                Text("Edit").font(.system(size: 13))
                Text("View").font(.system(size: 13))
                Spacer()
                Text("22:48").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 16)
            .frame(height: notchHeight)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.28))
        }
        .clipped()
    }
}

private struct DemoNotch: View {
    var body: some View {
        ZStack {
            UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12)
                .fill(Color.black)
            Circle().fill(Color(white: 0.12)).frame(width: 11, height: 11)
            Circle().fill(Color(red: 0.2, green: 0.3, blue: 0.5)).frame(width: 5, height: 5)
        }
    }
}
