import AppKit
import SwiftUI

/// Остров для внешних мониторов: у них нет выреза, поэтому свёрнутый вид — плашка по центру верхней грани
/// с обложкой, «исполнитель — трек» и эквалайзером, а по нажатию раскрывается тот же плеер, что и на ноутбуке.
/// Данные о треке общие с `IslandModel`; раскрытие и наведение у каждого монитора свои.
final class ExternalIslandState: ObservableObject {
    @Published var isHovered = false
    @Published var isExpanded = false {
        didSet {
            guard oldValue != isExpanded else { return }
            onExpansionChange?(isExpanded)
        }
    }

    /// Вызывается до раскрытия: окно должно стать большим до старта анимации формы.
    var onWillExpand: (() -> Void)?
    var onExpansionChange: ((Bool) -> Void)?

    func toggle() {
        isExpanded ? close() : open()
    }

    func open() {
        guard !isExpanded else { return }
        onWillExpand?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.isExpanded = true
        }
    }

    func close() {
        isExpanded = false
    }
}

enum ExternalMetrics {
    static let collapsed = CGSize(width: 380, height: 32)
    static let expanded = CGSize(width: 440, height: 156)
    static let collapsedArtwork: CGFloat = 22
    /// Высота верхней полосы развёрнутого вида: там иконка источника и эквалайзер.
    static let header: CGFloat = 32

    static var collapsedWindow: CGSize {
        CGSize(width: collapsed.width + IslandMetrics.hoverGrowX * 2, height: collapsed.height + IslandMetrics.hoverGrowY)
    }
}

struct ExternalIslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var state: ExternalIslandState

    private var shapeSize: CGSize {
        if state.isExpanded { return ExternalMetrics.expanded }
        let size = ExternalMetrics.collapsed
        guard state.isHovered else { return size }
        return CGSize(width: size.width + IslandMetrics.hoverGrowX * 2, height: size.height + IslandMetrics.hoverGrowY)
    }

    private var islandShape: NotchShape {
        state.isExpanded
            ? NotchShape(topRadius: IslandMetrics.expandedTop, bottomRadius: IslandMetrics.expandedBottom)
            : NotchShape(topRadius: IslandMetrics.collapsedTop, bottomRadius: IslandMetrics.collapsedBottom)
    }

    var body: some View {
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                collapsedBody
                    .frame(width: ExternalMetrics.collapsed.width, height: ExternalMetrics.collapsed.height)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: state.toggle)
                    .opacity(state.isExpanded ? 0 : 1)
                    .animation(.easeOut(duration: 0.14), value: state.isExpanded)
                    .allowsHitTesting(!state.isExpanded)
                expandedBody
                    .frame(width: ExternalMetrics.expanded.width, height: ExternalMetrics.expanded.height, alignment: .top)
                    .opacity(state.isExpanded ? 1 : 0)
                    .allowsHitTesting(state.isExpanded)
            }
            .frame(width: shapeSize.width, height: shapeSize.height, alignment: .top)
            // Одна обложка и один эквалайзер «переезжают» из плашки в плеер вместе с растущей формой.
            .overlay(alignment: .topLeading) { travellingArtwork }
            .overlay(alignment: .topLeading) { travellingEqualizer }
            .background { islandFill }
            .clipShape(islandShape)
            .overlay { islandChrome }
            .animation(.spring(response: 0.5, dampingFraction: 0.74), value: state.isExpanded)
            .animation(.spring(response: 0.32, dampingFraction: 0.62), value: state.isHovered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var islandFill: some View {
        if #available(macOS 26.0, *) {
            ZStack {
                // Почти невидимая подложка: полностью прозрачные пиксели окна пропускают клики сквозь себя.
                islandShape.fill(Color.white.opacity(0.07))
                Color.clear.glassEffect(state.isExpanded ? .regular : .clear, in: islandShape)
            }
        } else {
            islandShape.fill(Color(nsColor: NSColor(srgbRed: 0.80, green: 0.82, blue: 0.85, alpha: state.isExpanded ? 0.94 : 0.78)))
        }
    }

    private var islandChrome: some View {
        let colors: [Color] = [Color.white.opacity(0.55), Color.white.opacity(0.12), Color.white.opacity(0.3)]
        return islandShape
            .stroke(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom), lineWidth: 2)
            .clipShape(islandShape)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 16)
                    Color.black
                }
            }
            .allowsHitTesting(false)
    }

    private var collapsedBody: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: ExternalMetrics.collapsedArtwork, height: ExternalMetrics.collapsedArtwork)
            MarqueeText(text: summary)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: EqualizerView.compactWidth, height: 14)
        }
        .padding(.horizontal, IslandMetrics.collapsedTop + IslandMetrics.sidePad)
    }

    private var expandedBody: some View {
        let pad = IslandMetrics.expandedTop + 14
        return VStack(spacing: 0) {
            HStack {
                sourceBadge(side: IslandMetrics.artworkSide)
                    // Иконка выезжает из центра плашки к левому краю.
                    .offset(x: state.isExpanded ? 0 : 60)
                    .opacity(state.isExpanded ? 1 : 0)
                    .scaleEffect(state.isExpanded ? 1 : 0.8)
                    .animation(
                        state.isExpanded
                            ? .spring(response: 0.5, dampingFraction: 0.84).delay(0.04)
                            : .easeIn(duration: 0.16),
                        value: state.isExpanded
                    )
                Spacer()
                Color.clear.frame(width: EqualizerView.compactWidth, height: 14)
            }
            .padding(.horizontal, pad)
            .frame(height: ExternalMetrics.header)
            .contentShape(Rectangle())
            .onTapGesture(perform: state.toggle)

            HStack(alignment: .top, spacing: 14) {
                Color.clear.frame(width: IslandMetrics.expandedArtwork, height: IslandMetrics.expandedArtwork)

                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        MarqueeText(text: model.displayTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        if model.notice == nil {
                            MarqueeText(text: model.displaySubtitle)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(model.displaySubtitle)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(model.noticeIsActionable ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                                .lineLimit(2)
                                .contentShape(Rectangle())
                                .onTapGesture { if model.noticeIsActionable { model.onNoticeAction() } }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(RollDown(expanded: state.isExpanded, travel: rollTravel, delay: 0.02))

                    Spacer(minLength: 4)

                    HStack(spacing: 8) {
                        Text(IslandView.format(model.displayedElapsed))
                            .frame(width: 34, alignment: .leading)
                        SeekBar(model: model)
                        Text(IslandView.formatRemaining(elapsed: model.displayedElapsed, duration: model.duration))
                            .frame(width: 40, alignment: .trailing)
                    }
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .modifier(RollDown(expanded: state.isExpanded, travel: rollTravel, delay: 0.05))

                    Spacer(minLength: 2)

                    // Основной блок строго по центру колонки, реакции симметрично по краям от него.
                    HStack(spacing: 30) {
                        TransportButton(
                            systemName: model.isDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                            size: 14,
                            weight: .semibold,
                            color: model.isDisliked ? .primary : .secondary,
                            action: model.toggleDislike
                        )
                        HStack(spacing: 26) {
                            TransportButton(systemName: "backward.fill", size: 16, action: model.previousTrack)
                            TransportButton(
                                systemName: model.isPlaying ? "pause.fill" : "play.fill",
                                size: 19,
                                action: model.togglePlay
                            )
                            TransportButton(systemName: "forward.fill", size: 16, action: model.nextTrack)
                        }
                        TransportButton(
                            systemName: model.isLiked ? "heart.fill" : "heart",
                            size: 14,
                            weight: .semibold,
                            color: model.isLiked ? .primary : .secondary,
                            action: model.toggleLike
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .opacity(model.hasTrack ? 1 : 0.4)
                    .allowsHitTesting(model.hasTrack)
                    .modifier(RollDown(expanded: state.isExpanded, travel: rollTravel, delay: 0.05))
                }
                .frame(height: IslandMetrics.expandedArtwork)
            }
            .padding(.horizontal, pad)
            .padding(.top, 2)
        }
    }

    /// Насколько выше своего места стартуют название, таймлайн и кнопки: под обрезкой формы, за верхней гранью.
    private var rollTravel: CGFloat { ExternalMetrics.header + 46 }

    private var travellingArtwork: some View {
        let expanded = state.isExpanded
        let bodyWidth = expanded ? ExternalMetrics.expanded.width : ExternalMetrics.collapsed.width
        let side = expanded ? IslandMetrics.expandedArtwork : ExternalMetrics.collapsedArtwork
        let inset = expanded
            ? IslandMetrics.expandedTop + 14
            : IslandMetrics.collapsedTop + IslandMetrics.sidePad
        let x = (shapeSize.width - bodyWidth) / 2 + inset
        let y = expanded
            ? ExternalMetrics.header + 2
            : (ExternalMetrics.collapsed.height - side) / 2
        return artwork(side: side, radius: expanded ? 12 : 6)
            .offset(x: x, y: y)
            .allowsHitTesting(false)
    }

    private var travellingEqualizer: some View {
        let expanded = state.isExpanded
        let bodyWidth = expanded ? ExternalMetrics.expanded.width : ExternalMetrics.collapsed.width
        let eqWidth = EqualizerView.compactWidth
        let inset = expanded
            ? IslandMetrics.expandedTop + 14
            : IslandMetrics.collapsedTop + IslandMetrics.sidePad
        let x = (shapeSize.width - bodyWidth) / 2 + bodyWidth - inset - eqWidth
        let y = (ExternalMetrics.header - 14) / 2
        return EqualizerView(spectrum: model.spectrum, isPlaying: model.isPlaying, compact: true, leading: model.eqLeading, trailing: model.eqTrailing)
            .offset(x: x, y: y)
            .allowsHitTesting(false)
    }

    private var summary: String {
        guard model.hasTrack else { return model.displayTitle }
        return model.artist.isEmpty ? model.title : model.artist + " — " + model.title
    }

    @ViewBuilder
    private func artwork(side: CGFloat, radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if let image = model.artwork {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .clipShape(shape)
        } else {
            shape
                .fill(Color.white.opacity(0.12))
                .frame(width: side, height: side)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.42, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.85))
                )
        }
    }

    @ViewBuilder
    private func sourceBadge(side: CGFloat) -> some View {
        if let icon = model.sourceIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: side, height: side)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.1))
                .frame(width: side, height: side)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.46, weight: .semibold))
                        .foregroundStyle(.secondary)
                )
        }
    }
}

extension IslandModel {
    var displayTitle: String {
        if hasTrack { return title }
        if needsPlayerAccess { return "Нет доступа к плееру" }
        return "Ничего не играет"
    }

    var displaySubtitle: String {
        if let notice { return notice }
        if hasTrack { return artist }
        if needsPlayerAccess { return "Нужен Универсальный доступ" }
        return "Запусти трек в любом плеере"
    }
}

/// Окно острова на одном внешнем мониторе.
final class ExternalIslandController {
    let panel = IslandPanel()
    let state = ExternalIslandState()
    private var windowIsLarge = false
    private var collapseWork: DispatchWorkItem?

    init(model: IslandModel) {
        let hosting = IslandHostingView(rootView: ExternalIslandView(model: model, state: state))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        let state = state
        let container = IslandContainer { state.isHovered = $0 }
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

        state.onWillExpand = { [weak self] in
            guard let self else { return }
            self.collapseWork?.cancel()
            self.windowIsLarge = true
            self.layout()
        }
        state.onExpansionChange = { [weak self] expanded in
            guard let self else { return }
            self.collapseWork?.cancel()
            if expanded {
                self.windowIsLarge = true
                self.layout()
                self.panel.makeKey()
            } else {
                let work = DispatchWorkItem { [weak self] in
                    self?.windowIsLarge = false
                    self?.layout()
                }
                self.collapseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
            }
        }
    }

    private var screen: NSScreen?

    func place(on screen: NSScreen) {
        self.screen = screen
        layout()
    }

    private func layout() {
        guard let screen else { return }
        let size = windowIsLarge ? ExternalMetrics.expanded : ExternalMetrics.collapsedWindow
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        panel.level = .statusBar
        panel.hasShadow = false
        panel.orderFrontRegardless()
    }

    func close() {
        collapseWork?.cancel()
        panel.orderOut(nil)
    }
}

/// Держит по острову на каждый подключённый внешний монитор и следит за их подключением и отключением.
final class ExternalIslandManager {
    private let model: IslandModel
    private var controllers: [CGDirectDisplayID: ExternalIslandController] = [:]
    private var observer: NSObjectProtocol?
    private var monitors: [Any] = []

    init(model: IslandModel) {
        self.model = model
    }

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sync()
        }
        let outside: (NSEvent) -> Void = { [weak self] _ in self?.closeIfOutside() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: outside) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            self?.closeIfOutside()
            return event
        }) {
            monitors.append(local)
        }
        sync()
    }

    private func sync() {
        var present: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens where !DisplayLayout.isBuiltIn(screen) {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            present[number] = screen
        }
        for (id, controller) in controllers where present[id] == nil {
            controller.close()
            controllers[id] = nil
        }
        for (id, screen) in present {
            let controller = controllers[id] ?? ExternalIslandController(model: model)
            controllers[id] = controller
            controller.place(on: screen)
        }
    }

    private func closeIfOutside() {
        guard !DesktopPlayerReader.isClicking else { return }
        let point = NSEvent.mouseLocation
        for controller in controllers.values where controller.state.isExpanded && !controller.panel.frame.contains(point) {
            controller.state.close()
        }
    }
}

/// Однострочный текст: если не помещается, после паузы плавно едет справа налево по кругу.
/// Шрифт и цвет задаются снаружи, как у обычного `Text`.
struct MarqueeText: View {
    var text: String
    /// Скорость в pt/с, пауза в начале цикла и зазор между повторами.
    var speed: CGFloat = 32
    var pause: Double = 2
    var gap: CGFloat = 36

    @State private var textWidth: CGFloat = 0
    @State private var startedAt = Date()

    private struct WidthKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    var body: some View {
        // Скрытая копия задаёт высоту строки; сама строка рисуется поверх и обрезается по ширине.
        Text(text)
            .lineLimit(1)
            .opacity(0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    let overflows = textWidth > geo.size.width + 0.5
                    Group {
                        if overflows {
                            TimelineView(.animation) { timeline in
                                HStack(spacing: gap) {
                                    Text(text).lineLimit(1).fixedSize()
                                    Text(text).lineLimit(1).fixedSize()
                                }
                                .offset(x: offset(at: timeline.date))
                            }
                            .mask(edgeFade)
                        } else {
                            Text(text).lineLimit(1).fixedSize()
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                    .clipped()
                }
            }
            .background(alignment: .leading) {
                Text(text)
                    .lineLimit(1)
                    .fixedSize()
                    .hidden()
                    .background(GeometryReader { Color.clear.preference(key: WidthKey.self, value: $0.size.width) })
            }
            .onPreferenceChange(WidthKey.self) { textWidth = $0 }
            .onChange(of: text) { startedAt = Date() }
    }

    private func offset(at date: Date) -> CGFloat {
        let travel = textWidth + gap
        let cycle = pause + Double(travel / speed)
        let time = date.timeIntervalSince(startedAt).truncatingRemainder(dividingBy: cycle)
        return -CGFloat(max(0, time - pause)) * speed
    }

    private var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 8)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 12)
        }
    }
}
