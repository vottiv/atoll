import AppKit
import Combine
import Darwin
import QuartzCore
import SwiftUI

private let appDelegate = AppDelegate()

@main
struct IslandMain {
    static func main() {
        let app = NSApplication.shared
        app.delegate = appDelegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Диагностические файлы. В обычном запуске ничего не пишем: в логах были бы названия треков,
/// а предсказуемые имена в общем /tmp позволяют подменить файл ссылкой. Лог включается флагом
/// командной строки или `ATOLL_DEBUG=1` и лежит в закрытой папке пользователя.
enum DebugLog {
    static let enabled = ProcessInfo.processInfo.environment["ATOLL_DEBUG"] != nil
        || CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }

    private static let directory: String? = {
        guard let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let url = base.appendingPathComponent("Logs/Atoll", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        return url.path
    }()

    /// Путь для диагностики; когда она выключена, пишем в `/dev/null`.
    static func path(_ name: String) -> String {
        guard enabled, let directory else { return "/dev/null" }
        return directory + "/island-" + name
    }
}

struct SourceChip: Identifiable {
    var bundle: String
    var icon: NSImage?
    var id: String { bundle }
}

final class IslandModel: ObservableObject {
    @Published var isHovered = false
    @Published var isExpanded = false {
        didSet {
            guard oldValue != isExpanded else { return }
            fputs("ISLAND_STATE expanded=\(isExpanded ? 1 : 0)\n", stderr)
            onExpansionChange?(isExpanded)
            onChromeChange?()
        }
    }
    @Published var title = ""
    @Published var artist = ""
    @Published var artwork: NSImage?
    /// Иконка приложения, из которого идёт звук.
    @Published var sourceIcon: NSImage?
    private var sourceBundle: String?
    /// Все приложения, из которых сейчас идёт звук, в порядке появления.
    @Published var sources: [SourceChip] = []
    @Published var selectedSource: String?
    /// Подсказка вместо строки исполнителя (например, что нужно разрешить в браузере).
    @Published var notice: String?
    /// Подсказку можно нажать (например, чтобы разрешить управление браузером).
    @Published var noticeIsActionable = false
    @Published var eqLeading = ArtworkPalette.neutral.0
    @Published var eqTrailing = ArtworkPalette.neutral.1
    @Published var duration: TimeInterval = 0
    @Published var elapsed: TimeInterval = 0
    @Published var isPlaying = false
    @Published var isLiked = false
    @Published var hasTrack = false
    @Published var needsPlayerAccess = false
    @Published var isScrubbing = false
    @Published var notchWidth: CGFloat = 220
    @Published var notchHeight: CGFloat = 38
    let spectrum = SpectrumModel()

    /// Пока true, наведение не меняет размер. Нужно для стабильного скриншота.
    var locksExpansion = false
    var usesFlatBackdrop = false
    private var scrubElapsed: TimeInterval = 0

    var onToggle: () -> Void = {}
    var onNext: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onSeek: (TimeInterval) -> Void = { _ in }
    var onLike: () -> Void = {}
    var onSelectSource: (String) -> Void = { _ in }
    var onOpenSource: (String) -> Void = { _ in }
    var onNoticeAction: () -> Void = {}
    var onExpansionChange: ((Bool) -> Void)?
    /// Вызывается до раскрытия: окно должно стать большим до старта анимации формы.
    var onWillExpand: (() -> Void)?
    /// Растёт при каждой смене размера окна; по нему SwiftUI отключает анимацию контейнера.
    @Published var windowEpoch = 0
    var onChromeChange: (() -> Void)?
    var onContentChange: (() -> Void)?
    private var trackKey = ""

    var displayedElapsed: TimeInterval {
        isScrubbing ? scrubElapsed : elapsed
    }

    var collapsedSize: NSSize {
        let side = IslandMetrics.artworkSide + IslandMetrics.sidePad + IslandMetrics.notchGap
        return NSSize(width: notchWidth + (side + IslandMetrics.collapsedTop) * 2, height: notchHeight + IslandMetrics.lip)
    }

    var expandedSize: NSSize {
        NSSize(width: notchWidth + (IslandMetrics.expandedSlack + IslandMetrics.horizontalInset + IslandMetrics.expandedTop) * 2, height: notchHeight + IslandMetrics.expandedBody)
    }

    /// Свёрнутое окно чуть больше острова: запас под «выползание» при наведении.
    var collapsedWindowSize: NSSize {
        NSSize(width: collapsedSize.width + IslandMetrics.hoverGrowX * 2, height: collapsedSize.height + IslandMetrics.hoverGrowY)
    }

    var windowSize: NSSize {
        isExpanded ? expandedSize : collapsedWindowSize
    }

    func setHovered(_ hovering: Bool) {
        guard isHovered != hovering else { return }
        fputs("ISLAND_STATE hovered=\(hovering ? 1 : 0)\n", stderr)
        isHovered = hovering
        onChromeChange?()
    }

    func toggleWidget() {
        fputs("ISLAND_STATE toggle expanded=\(isExpanded ? 1 : 0)\n", stderr)
        isExpanded ? closeWidget() : openWidget()
    }

    func openWidget() {
        guard !locksExpansion, !isExpanded else { return }
        onWillExpand?()
        // Даём окну перерисоваться в большом размере отдельным кадром, затем запускаем анимацию формы.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.isExpanded = true
        }
    }

    func closeWidget() {
        guard !locksExpansion else { return }
        isExpanded = false
    }

    func togglePlay() {
        guard hasTrack else { return }
        isPlaying.toggle()
        onToggle()
    }

    func nextTrack() {
        guard hasTrack else { return }
        onNext()
    }

    func previousTrack() {
        guard hasTrack else { return }
        onPrevious()
    }

    func toggleLike() {
        guard hasTrack else { return }
        isLiked.toggle()
        onLike()
    }

    func beginScrub(ratio: Double) {
        guard duration > 0 else { return }
        isScrubbing = true
        scrubElapsed = duration * clamp(ratio)
    }

    func endScrub(ratio: Double) {
        guard duration > 0 else { return }
        let target = duration * clamp(ratio)
        scrubElapsed = target
        elapsed = target
        isScrubbing = false
        onSeek(target)
    }

    func applyTrack(
        title: String,
        artist: String,
        duration: TimeInterval,
        elapsed: TimeInterval,
        isPlaying: Bool,
        artwork: NSImage?
    ) {
        self.title = title
        self.artist = artist
        self.duration = duration
        let key = title + "\u{1f}" + artist
        if key != trackKey {
            trackKey = key
            isLiked = false
        }
        self.isPlaying = isPlaying
        let appeared = !hasTrack
        self.hasTrack = true
        if appeared { onContentChange?() }
        if self.artwork !== artwork {
            self.artwork = artwork
            refreshPalette(from: artwork)
        }
        if !isScrubbing {
            self.elapsed = elapsed
        }
    }

    func setSource(bundleID: String?) {
        guard bundleID != sourceBundle else { return }
        sourceBundle = bundleID
        sourceIcon = bundleID.flatMap(Self.appIcon)
    }

    func setSources(_ bundles: [String], selected: String?) {
        let chips = bundles.map { SourceChip(bundle: $0, icon: Self.appIcon(bundle: $0)) }
        if chips.map(\.bundle) != sources.map(\.bundle) { sources = chips }
        if selectedSource != selected { selectedSource = selected }
    }

    /// Нажатие на иконку: чужая — переключает виджет на этот источник, выбранная — открывает приложение.
    func tapSource(_ bundle: String) {
        if bundle == selectedSource {
            onOpenSource(bundle)
        } else {
            selectedSource = bundle
            onSelectSource(bundle)
        }
    }

    private static var iconCache: [String: NSImage] = [:]

    static func appIcon(bundle: String) -> NSImage? {
        if let cached = iconCache[bundle] { return cached }
        var url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        if url == nil, bundle.hasSuffix(".helper") {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: String(bundle.dropLast(7)))
        }
        guard let url else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundle] = icon
        return icon
    }

    func clearTrack() {
        let hadTrack = hasTrack
        title = ""
        artist = ""
        artwork = nil
        refreshPalette(from: nil)
        duration = 0
        elapsed = 0
        isPlaying = false
        isLiked = false
        hasTrack = false
        isScrubbing = false
        trackKey = ""
        setSource(bundleID: nil)
        notice = nil
        if hadTrack { onContentChange?() }
    }

    func loadPreview() {
        title = "Night Drive"
        artist = "Harbor"
        duration = 214
        elapsed = 78
        isPlaying = true
        hasTrack = true
        artwork = PreviewArtwork.make()
        refreshPalette(from: artwork)
        setSources(["com.apple.Music", "com.apple.Safari"], selected: "com.apple.Music")
        setSource(bundleID: "com.apple.Music")
        onToggle = { [weak self] in self?.isPlaying.toggle() }
        onSeek = { [weak self] time in self?.elapsed = time }
        onNext = {}
        onPrevious = {}
    }

    private func clamp(_ ratio: Double) -> Double {
        min(1, max(0, ratio))
    }

    private func refreshPalette(from image: NSImage?) {
        let colors = ArtworkPalette.colors(from: image)
        eqLeading = colors.0
        eqTrailing = colors.1
    }
}

enum IslandMetrics {
    static let artworkSide: CGFloat = 26
    static let expandedArtwork: CGFloat = 92
    /// От края тела острова до обложки слева и до эквалайзера справа: одинаково.
    static let sidePad: CGFloat = 9
    /// Зазор между контентом и физической камерой.
    static let notchGap: CGFloat = 4
    static let horizontalInset: CGFloat = 10
    static let lip: CGFloat = 0
    static let expandedBody: CGFloat = 122
    static let expandedSlack: CGFloat = 74
    /// Насколько остров выползает при наведении (по бокам и вниз).
    static let hoverGrowX: CGFloat = 5
    static let hoverGrowY: CGFloat = 3
    static let collapsedTop: CGFloat = 7
    static let collapsedBottom: CGFloat = 12
    static let expandedTop: CGFloat = 14
    static let expandedBottom: CGFloat = 24
}

enum DisplayLayout {
    static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first(where: isBuiltIn)
    }

    static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return false
        }
        return CGDisplayIsBuiltin(number) != 0
    }

    static func notchMetrics(on screen: NSScreen) -> (width: CGFloat, height: CGFloat) {
        let height = screen.safeAreaInsets.top
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX + 40 {
            return (right.minX - left.maxX, height > 1 ? height : 38)
        }
        return (220, height > 1 ? height : 0)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = IslandModel()
    private var windowController: IslandWindowController?
    private var nowPlaying: NowPlayingService?
    private var outsideClickMonitor: Any?
    private var spectrumMonitor: AudioSpectrum?
    private var demoRecorder: DemoRecorder?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--ax") {
            DesktopPlayerReader.dump()
            exit(0)
        }
        if args.contains("--probe") {
            DesktopPlayerReader.probe()
            exit(0)
        }
        if args.contains("--press-toggle") {
            DesktopPlayerReader.press(.toggle)
            exit(0)
        }
        if args.contains("--press-next") {
            DesktopPlayerReader.press(.next)
            exit(0)
        }
        if args.contains("--press-prev") {
            DesktopPlayerReader.press(.previous)
            exit(0)
        }
        if args.contains("--media-test") {
            DesktopPlayerReader.sendMediaKey(.play)
            exit(0)
        }
        if args.contains("--check") {
            DesktopPlayerReader.controlCheck()
            exit(0)
        }
        if args.contains("--status") {
            try? DesktopPlayerReader.statusLine().write(toFile: DebugLog.path("status.txt"), atomically: true, encoding: .utf8)
            exit(0)
        }
        if args.contains("--seek-probe") {
            DesktopPlayerReader.seekProbe()
            exit(0)
        }
        if args.contains("--seek-test") {
            DesktopPlayerReader.seek(ratio: 0.2, duration: 0)
            exit(0)
        }
        if args.contains("--shot") {
            model.locksExpansion = true
        }
        if args.contains("--snapshot") {
            model.loadPreview()
            do {
                try SnapshotWriter.write(model: model)
            } catch {
                fputs("snapshot failed: \(error)\n", stderr)
                exit(1)
            }
            exit(0)
        }
        if args.contains("--preview") {
            model.loadPreview()
        } else if let nowPlaying = NowPlayingService(model: model) {
            self.nowPlaying = nowPlaying
            model.onToggle = { [weak self] in self?.nowPlaying?.toggle() }
            model.onNext = { [weak self] in self?.nowPlaying?.next() }
            model.onPrevious = { [weak self] in self?.nowPlaying?.previous() }
            model.onSeek = { [weak self] time in self?.nowPlaying?.seek(to: time) }
            model.onLike = { [weak self] in self?.nowPlaying?.like() }
            model.onSelectSource = { [weak self] in self?.nowPlaying?.select($0) }
            model.onOpenSource = { [weak self] in self?.nowPlaying?.openSource($0) }
            model.onNoticeAction = { [weak self] in self?.nowPlaying?.confirmBrowserAccess() }
        }

        if args.contains("--expanded") {
            model.isExpanded = true
            model.locksExpansion = true
        } else if args.contains("--hovered") {
            model.isHovered = true
            model.locksExpansion = true
        } else if args.contains("--collapsed") {
            model.isExpanded = false
            model.locksExpansion = true
        }

        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "local.island.notch")
        where app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app.forceTerminate()
        }

        let controller = IslandWindowController(model: model)
        windowController = controller
        controller.start()
        nowPlaying?.start()
        watchClicksOutside()
        // Звук снимаем только пока играет музыка.
        let monitor = AudioSpectrum(model: model.spectrum)
        spectrumMonitor = monitor
        model.$isPlaying
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { playing in
                if playing { monitor.start() } else { monitor.stop() }
            }
            .store(in: &cancellables)
        if let flag = args.firstIndex(of: "--record"), args.indices.contains(flag + 1) {
            let recorder = DemoRecorder(model: model, panel: controller.panel, output: URL(fileURLWithPath: args[flag + 1]))
            demoRecorder = recorder
            recorder.run()
        }
        if args.contains("--cycle") {
            // Отладка анимации: сам раскрывает и сворачивает островок каждые 3 секунды.
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                self?.model.toggleWidget()
            }
        }
        if args.contains("--selftest") {
            runSelfTest()
        }
        if args.contains("--shot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                self?.captureOwnWindow(named: "collapsed")
                self?.model.isExpanded = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.captureOwnWindow(named: "expanded")
                    exit(0)
                }
            }
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "q" {
                NSApp.terminate(nil)
                return nil
            }
            return event
        }
    }

    /// Гоняет те же вызовы, что и кнопки виджета, и сверяет результат с реальным плеером.
    private func runSelfTest() {
        guard let truth = MediaRemoteBridge() else {
            print("SELFTEST FAIL bridge missing")
            exit(1)
        }
        let model = model
        func snapshot() async -> MediaRemoteBridge.Snapshot? {
            await withCheckedContinuation { continuation in
                truth.fetch { continuation.resume(returning: $0) }
            }
        }
        func number(_ snap: MediaRemoteBridge.Snapshot?, _ key: String) -> Double {
            (snap?.info[key] as? NSNumber)?.doubleValue ?? 0
        }
        func title(_ snap: MediaRemoteBridge.Snapshot?) -> String {
            snap?.info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        }
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failed += 1 }
            print("SELFTEST \(ok ? "PASS" : "FAIL") \(name) \(detail)")
            fflush(stdout)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            let start = await snapshot()
            check("track visible", model.hasTrack && !model.title.isEmpty, "title=\(model.title)")
            check("state matches player", start?.isPlaying == model.isPlaying, "player=\(start?.isPlaying ?? false) model=\(model.isPlaying)")

            if model.isPlaying {
                // Время на таймлайне не должно скакать назад при опросе плеера.
                var last = model.elapsed
                var worstBack = 0.0
                var worstForward = 0.0
                for _ in 0..<140 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    let now = model.elapsed
                    worstBack = min(worstBack, now - last)
                    worstForward = max(worstForward, now - last)
                    last = now
                }
                check("timeline smooth", worstBack > -0.05 && worstForward < 0.6, String(format: "worstBack=%.2f worstForward=%.2f", worstBack, worstForward))
            }

            let wasPlaying = start?.isPlaying ?? false
            model.togglePlay()
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            let toggled = await snapshot()
            check("play/pause", toggled?.isPlaying == !wasPlaying, "before=\(wasPlaying) after=\(toggled?.isPlaying ?? false) model=\(model.isPlaying)")
            model.togglePlay()
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            let restored = await snapshot()
            check("play/pause back", restored?.isPlaying == wasPlaying, "after=\(restored?.isPlaying ?? false)")

            let duration = number(restored, "kMRMediaRemoteNowPlayingInfoDuration")
            if duration > 30 {
                // Сначала далеко вперёд, затем назад: старое (большее) время не должно мелькать после перемотки.
                model.beginScrub(ratio: 0.7)
                model.endScrub(ratio: 0.7)
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                let target = duration * 0.25
                model.beginScrub(ratio: 0.25)
                model.endScrub(ratio: 0.25)
                var highest = 0.0
                for _ in 0..<70 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    highest = max(highest, model.elapsed)
                }
                check("seek does not flash old time", highest < target + 6, String(format: "target=%.0f highestShown=%.1f (old=%.0f)", target, highest, duration * 0.7))
                let sought = await snapshot()
                let elapsed = number(sought, "kMRMediaRemoteNowPlayingInfoElapsedTime")
                check("seek", abs(elapsed - duration * 0.25) < 4, "target=\(Int(duration * 0.25)) actual=\(Int(elapsed))")
            } else {
                check("seek", false, "duration unknown")
            }

            let before = title(await snapshot())
            model.nextTrack()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            let afterNext = await snapshot()
            check("next", title(afterNext) != before || number(afterNext, "kMRMediaRemoteNowPlayingInfoElapsedTime") < 5, "\(before) -> \(title(afterNext)) elapsed=\(Int(number(afterNext, "kMRMediaRemoteNowPlayingInfoElapsedTime")))")
            model.previousTrack()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            let afterPrev = await snapshot()
            check("previous", title(afterPrev) != title(afterNext) || number(afterPrev, "kMRMediaRemoteNowPlayingInfoElapsedTime") < 5, "\(title(afterNext)) -> \(title(afterPrev)) elapsed=\(Int(number(afterPrev, "kMRMediaRemoteNowPlayingInfoElapsedTime")))")
            print("SELFTEST DONE failed=\(failed)")
            fflush(stdout)
            exit(failed == 0 ? 0 : 1)
        }
    }

    private func captureOwnWindow(named name: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let owned = info.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }
        guard let match = owned.max(by: { lhs, rhs in
            let left = (lhs[kCGWindowBounds as String] as? [String: Any])?["Height"] as? NSNumber
            let right = (rhs[kCGWindowBounds as String] as? [String: Any])?["Height"] as? NSNumber
            return (left?.doubleValue ?? 0) < (right?.doubleValue ?? 0)
        }), let number = (match[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
           let image = CGWindowListCreateImage(.null, .optionIncludingWindow, number, [.boundsIgnoreFraming, .bestResolution]) else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: DebugLog.path("shot-\(name).png")))
    }

    private func watchClicksOutside() {
        let handler: (NSEvent) -> Void = { [weak self] _ in
            guard let self, self.model.isExpanded else { return }
            guard let panel = self.windowController?.panel else { return }
            if panel.frame.contains(NSEvent.mouseLocation) { return }
            self.model.closeWidget()
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler)
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.model.isExpanded, let panel = self.windowController?.panel else {
                return event
            }
            let point = NSEvent.mouseLocation
            if !panel.frame.contains(point) {
                self.model.closeWidget()
            }
            return event
        }
    }
}

final class IslandWindowController {
    let panel: IslandPanel
    private let model: IslandModel
    private var screenObserver: NSObjectProtocol?
    private var windowIsLarge = false
    private var collapseWork: DispatchWorkItem?

    init(model: IslandModel) {
        self.model = model
        panel = IslandPanel()
        configurePanel()
        windowIsLarge = model.isExpanded
        model.onWillExpand = { [weak self] in
            guard let self else { return }
            self.collapseWork?.cancel()
            self.windowIsLarge = true
            self.layout(animated: false)
        }
        model.onExpansionChange = { [weak self] expanded in
            guard let self else { return }
            self.collapseWork?.cancel()
            if expanded {
                // Окно сразу нужного размера, дальше форма плавно растёт внутри него.
                self.windowIsLarge = true
                self.layout(animated: false)
                self.panel.makeKey()
            } else {
                // Окно сжимаем только после того, как форма доехала.
                let work = DispatchWorkItem { [weak self] in
                    self?.windowIsLarge = false
                    self?.layout(animated: false)
                }
                self.collapseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
            }
        }
    }

    func start() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.layout(animated: false)
        }
        layout(animated: false)
    }

    private func configurePanel() {
        let hosting = IslandHostingView(rootView: IslandView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        let container = IslandContainer(model: model)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
    }

    private func layout(animated: Bool) {
        guard let screen = DisplayLayout.builtInScreen() else {
            panel.orderOut(nil)
            return
        }

        let metrics = DisplayLayout.notchMetrics(on: screen)
        model.notchWidth = metrics.width
        model.notchHeight = metrics.height > 1 ? metrics.height : 32

        let size = windowIsLarge ? model.expandedSize : model.collapsedWindowSize
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )

        panel.setFrame(frame, display: true)
        model.windowEpoch += 1

        panel.level = .statusBar
        panel.hasShadow = false
        panel.orderFrontRegardless()
        let viewSize = panel.contentView?.bounds.size ?? .zero
        fputs(
            String(format: "ISLAND_FRAME %.0fx%.0f view=%.0fx%.0f y=%.0f expanded=%d\n", frame.width, frame.height, viewSize.width, viewSize.height, frame.origin.y, model.isExpanded ? 1 : 0),
            stderr
        )
    }
}

final class IslandPanel: NSPanel {
    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 336, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: backingStoreType,
            defer: flag
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

final class IslandContainer: NSView {
    private let model: IslandModel
    private var tracking: NSTrackingArea?

    init(model: IslandModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        model.setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        model.setHovered(false)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Закрыть Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
}
