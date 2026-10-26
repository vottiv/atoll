import SwiftUI

/// Форма как у вырезанного острова на Mac: сверху «ушки» плавно вливаются в грань экрана
/// (вогнутое скругление), снизу обычное выпуклое.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.width / 4)
        let b = min(bottomRadius, rect.height / 2, (rect.width - 2 * t) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + t, y: rect.minY + t),
            control: CGPoint(x: rect.minX + t, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
            control: CGPoint(x: rect.minX + t, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
            control: CGPoint(x: rect.maxX - t, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - t, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel

    /// Размер самой формы. Окно уже подогнано под большее из состояний, форма плавно перетекает внутри.
    private var shapeSize: CGSize {
        if model.isExpanded { return model.expandedSize }
        let size = model.collapsedSize
        guard model.isHovered else { return size }
        // Наведение: остров чуть «выползает» за пределы физической области, как на iPhone.
        return CGSize(width: size.width + IslandMetrics.hoverGrowX * 2, height: size.height + IslandMetrics.hoverGrowY)
    }

    var body: some View {
        let collapsed = model.collapsedSize
        let expanded = model.expandedSize
        return ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                collapsedBody
                    .frame(width: collapsed.width, height: collapsed.height)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: model.toggleWidget)
                    .allowsHitTesting(!model.isExpanded)
                expandedBody
                    .padding(.horizontal, IslandMetrics.expandedTop + 14)
                    .padding(.bottom, 12)
                    .frame(width: expanded.width, height: expanded.height, alignment: .top)
                    .overlay(alignment: .top) {
                        // Нажатие на область островка (над камерой) сворачивает виджет.
                        Color.clear
                            .frame(width: model.notchWidth + 16, height: model.notchHeight)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: model.toggleWidget)
                    }
                    .allowsHitTesting(model.isExpanded)
            }
            .frame(width: shapeSize.width, height: shapeSize.height, alignment: .top)
            // Одна обложка «переезжает» из миниатюры в полный размер вместе с растущей формой.
            .overlay(alignment: .topLeading) { travellingArtwork }
            .overlay(alignment: .topLeading) { travellingEqualizer }
            .background { islandFill }
            .clipShape(islandShape)
            .overlay { islandChrome }
            // Анимация привязана к форме, а не к корневому контейнеру: изменение размера окна
            // не должно анимироваться, иначе остров растёт из угла, а не от центра.
            .animation(.spring(response: 0.5, dampingFraction: 0.74), value: model.isExpanded)
            .animation(.spring(response: 0.32, dampingFraction: 0.62), value: model.isHovered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var islandShape: NotchShape {
        model.isExpanded
            ? NotchShape(topRadius: IslandMetrics.expandedTop, bottomRadius: IslandMetrics.expandedBottom)
            : NotchShape(topRadius: IslandMetrics.collapsedTop, bottomRadius: IslandMetrics.collapsedBottom)
    }

    /// Цвета системные. Свёрнутый — как Dock: почти прозрачное стекло. Развёрнутый — как системные
    /// виджеты: то же стекло, но плотнее. Своих серых подложек нет.
    @ViewBuilder
    private var islandFill: some View {
        if #available(macOS 26.0, *), !model.usesFlatBackdrop {
            ZStack {
                // Почти невидимая подложка: полностью прозрачные пиксели окна пропускают клики сквозь себя.
                islandShape.fill(Color.white.opacity(0.07))
                Color.clear.glassEffect(model.isExpanded ? .regular : .clear, in: islandShape)
            }
        } else {
            islandShape.fill(Color(nsColor: NSColor(srgbRed: 0.80, green: 0.82, blue: 0.85, alpha: model.isExpanded ? 0.94 : 0.78)))
        }
    }

    /// Тонкая светлая кромка, как у системных виджетов. Верхний край не обводим: он сливается с гранью экрана.
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
        HStack(spacing: 0) {
            Color.clear.frame(width: IslandMetrics.artworkSide, height: IslandMetrics.artworkSide)
            Spacer(minLength: model.notchWidth + IslandMetrics.notchGap * 2)
            Color.clear.frame(width: EqualizerView.compactWidth, height: 14)
        }
        .padding(.horizontal, IslandMetrics.collapsedTop + IslandMetrics.sidePad)
    }

    /// Над физической границей острова (уровень камеры): иконка приложения-источника слева и
    /// эквалайзер справа. Ниже границы: крупная обложка и колонка с названием, таймлайном и кнопками.
    private var expandedBody: some View {
        VStack(spacing: 0) {
            // Иконка и эквалайзер стоят по центру боковых «крыльев» по обе стороны от камеры.
            HStack(spacing: 0) {
                sourceChips
                    // Иконка выезжает из-за камеры и встаёт по центру своего «крыла».
                    .offset(x: model.isExpanded ? 0 : badgeTravel)
                    .opacity(model.isExpanded ? 1 : 0)
                    .scaleEffect(model.isExpanded ? 1 : 0.8)
                    .animation(
                        model.isExpanded
                            ? .spring(response: 0.5, dampingFraction: 0.84).delay(0.04)
                            : .easeIn(duration: 0.16),
                        value: model.isExpanded
                    )
                    .frame(maxWidth: .infinity)
                Color.clear.frame(width: model.notchWidth)
                Color.clear
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, -14)
            .frame(height: model.notchHeight)

            HStack(alignment: .top, spacing: 14) {
                Color.clear.frame(width: IslandMetrics.expandedArtwork, height: IslandMetrics.expandedArtwork)

                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(titleText)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(artistText)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(model.notice != nil && model.noticeIsActionable ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                            .lineLimit(model.notice == nil ? 1 : 2)
                            .contentShape(Rectangle())
                            .onTapGesture { if model.notice != nil && model.noticeIsActionable { model.onNoticeAction() } }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(RollDown(expanded: model.isExpanded, travel: rollTravel, delay: 0.02))

                    Spacer(minLength: 4)

                    HStack(spacing: 8) {
                        Text(Self.format(model.displayedElapsed))
                            .frame(width: 34, alignment: .leading)
                        SeekBar(model: model)
                        Text(Self.formatRemaining(elapsed: model.displayedElapsed, duration: model.duration))
                            .frame(width: 40, alignment: .trailing)
                    }
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .modifier(RollDown(expanded: model.isExpanded, travel: rollTravel, delay: 0.05))

                    Spacer(minLength: 2)

                    HStack(spacing: 26) {
                        TransportButton(systemName: "backward.fill", size: 16, action: model.previousTrack)
                        TransportButton(
                            systemName: model.isPlaying ? "pause.fill" : "play.fill",
                            size: 19,
                            action: model.togglePlay
                        )
                        TransportButton(systemName: "forward.fill", size: 16, action: model.nextTrack)
                    }
                    .frame(maxWidth: .infinity)
                    .opacity(model.hasTrack ? 1 : 0.4)
                    .allowsHitTesting(model.hasTrack)
                    .modifier(RollDown(expanded: model.isExpanded, travel: rollTravel, delay: 0.05))
                }
                .frame(height: IslandMetrics.expandedArtwork)
            }
            .padding(.top, 14)
        }
    }

    /// Расстояние от центра левого «крыла» до края камеры: оттуда иконка начинает движение.
    private var badgeTravel: CGFloat {
        let total = model.expandedSize.width - 2 * (IslandMetrics.expandedTop + 14) + 28
        let wing = (total - model.notchWidth) / 2
        return wing / 2 + IslandMetrics.artworkSide / 2
    }

    /// Положение обложки в координатах формы: в свёрнутом виде слева у «уха», в развёрнутом — под линией камеры.
    private var travellingArtwork: some View {
        let expanded = model.isExpanded
        let bodyWidth = expanded ? model.expandedSize.width : model.collapsedSize.width
        let side = expanded ? IslandMetrics.expandedArtwork : IslandMetrics.artworkSide
        let inset = expanded
            ? IslandMetrics.expandedTop + 14
            : IslandMetrics.collapsedTop + IslandMetrics.sidePad
        let x = (shapeSize.width - bodyWidth) / 2 + inset
        let y = expanded
            ? model.notchHeight + 14
            : (model.collapsedSize.height - side) / 2
        return artwork(side: side, radius: expanded ? 12 : 6)
            .offset(x: x, y: y)
            .allowsHitTesting(false)
    }

    /// Насколько выше своего места стартуют название, таймлайн и кнопки: внутри физического острова, под обрезкой формы.
    private var rollTravel: CGFloat { model.notchHeight + 46 }

    /// Эквалайзер один на оба состояния: плавно едет от «уха» свёрнутого острова к центру правого «крыла» развёрнутого.
    private var travellingEqualizer: some View {
        let expanded = model.isExpanded
        let bodyWidth = expanded ? model.expandedSize.width : model.collapsedSize.width
        let eqWidth = EqualizerView.compactWidth
        let eqHeight: CGFloat = 14
        let inset: CGFloat
        if expanded {
            let pad = IslandMetrics.expandedTop + 14
            let wing = (bodyWidth - 2 * pad + 28 - model.notchWidth) / 2
            inset = pad - 14 + wing + model.notchWidth + (wing - eqWidth) / 2
        } else {
            inset = bodyWidth - (IslandMetrics.collapsedTop + IslandMetrics.sidePad) - eqWidth
        }
        let x = (shapeSize.width - bodyWidth) / 2 + inset
        let y = ((expanded ? model.notchHeight : model.collapsedSize.height) - eqHeight) / 2
        return EqualizerView(spectrum: model.spectrum, isPlaying: model.isPlaying, compact: true, leading: model.eqLeading, trailing: model.eqTrailing)
            .opacity(expanded && !model.hasTrack ? 0 : 1)
            .offset(x: x, y: y)
            .allowsHitTesting(false)
    }

    /// Иконки приложений, из которых идёт звук: выбранная крупнее и первая, остальные рядом.
    /// Нажатие на другую переключает виджет на неё, на выбранную — открывает приложение.
    private var sourceChips: some View {
        let chips = model.sources.sorted { lhs, rhs in
            (lhs.bundle == model.selectedSource ? 0 : 1) < (rhs.bundle == model.selectedSource ? 0 : 1)
        }
        return HStack(spacing: 6) {
            if chips.count < 2 {
                sourceBadge(side: IslandMetrics.artworkSide)
                    .contentShape(Rectangle())
                    .onTapGesture { if let bundle = chips.first?.bundle { model.tapSource(bundle) } }
            } else {
                ForEach(chips) { chip in
                    let isSelected = chip.bundle == model.selectedSource
                    chipIcon(chip, side: isSelected ? IslandMetrics.artworkSide : 20)
                        .opacity(isSelected ? 1 : 0.55)
                        .contentShape(Rectangle())
                        .onTapGesture { model.tapSource(chip.bundle) }
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: model.selectedSource)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: model.sources.map(\.bundle))
    }

    @ViewBuilder
    private func chipIcon(_ chip: SourceChip, side: CGFloat) -> some View {
        if let icon = chip.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: side, height: side)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.1))
                .frame(width: side, height: side)
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

    private var titleText: String {
        if model.hasTrack { return model.title }
        if model.needsPlayerAccess { return "Нет доступа к плееру" }
        return "Ничего не играет"
    }

    private var artistText: String {
        if let notice = model.notice { return notice }
        if model.hasTrack { return model.artist }
        if model.needsPlayerAccess { return "Нужен Универсальный доступ" }
        return "Запусти трек в любом плеере"
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

    static func format(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "0:00" }
        let total = max(0, Int(time.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func formatRemaining(elapsed: TimeInterval, duration: TimeInterval) -> String {
        let remaining = max(0, duration - elapsed)
        return "-" + format(remaining)
    }
}

struct EqualizerView: View {
    @ObservedObject var spectrum: SpectrumModel
    var isPlaying: Bool
    var compact: Bool
    var leading: NSColor
    var trailing: NSColor

    private var barCount: Int { SpectrumModel.bandCount }

    /// Ширина компактного эквалайзера: пять баров по 3 pt и четыре промежутка по 2,5 pt.
    static let compactWidth: CGFloat = CGFloat(SpectrumModel.bandCount) * 3 + CGFloat(SpectrumModel.bandCount - 1) * 2.5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { timeline in
            HStack(alignment: .center, spacing: compact ? 2.5 : 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    let color = barColor(index: index)
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.78), color],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(
                            width: compact ? 3 : 3.5,
                            height: height(index: index, date: timeline.date)
                        )
                }
            }
        }
        .frame(height: compact ? 14 : 18, alignment: .center)
    }

    private func barColor(index: Int) -> Color {
        let t = CGFloat(index) / CGFloat(barCount - 1)
        let start = leading.usingColorSpace(.deviceRGB) ?? leading
        let end = trailing.usingColorSpace(.deviceRGB) ?? trailing
        return Color(nsColor: NSColor(
            calibratedRed: start.redComponent + (end.redComponent - start.redComponent) * t,
            green: start.greenComponent + (end.greenComponent - start.greenComponent) * t,
            blue: start.blueComponent + (end.blueComponent - start.blueComponent) * t,
            alpha: 1
        ))
    }

    private func height(index: Int, date: Date) -> CGFloat {
        let maxHeight: CGFloat = compact ? 14 : 18
        let minHeight: CGFloat = compact ? 4 : 5
        let resting: [CGFloat] = [0.34, 0.58, 0.86, 0.5, 0.38]
        guard isPlaying else {
            return minHeight + resting[index] * (maxHeight - minHeight) * 0.45
        }
        if spectrum.isLive {
            // Реальный спектр системного звука: бары ритмично следуют за музыкой.
            let level = CGFloat(min(1, max(0, spectrum.levels[index])))
            return minHeight + level * (maxHeight - minHeight)
        }
        // Нет доступа к звуку: спокойная запасная анимация.
        let t = date.timeIntervalSinceReferenceDate
        let mixed = 0.7 * sin(t * 5.2 + Double(index) * 0.95) + 0.3 * sin(t * 2.3 + Double(index) * 1.4)
        let unit = min(1, max(0, 0.5 + 0.5 * mixed))
        return minHeight + CGFloat(unit) * (maxHeight - minHeight)
    }
}

struct SeekBar: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let progress = model.duration > 0 ? min(1, max(0, model.displayedElapsed / model.duration)) : 0
            let thickness: CGFloat = model.isScrubbing ? 6 : 4

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.22))
                    .frame(height: thickness)
                Capsule()
                    .fill(Color.primary.opacity(0.8))
                    .frame(width: max(thickness, width * progress), height: thickness)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        model.beginScrub(ratio: value.location.x / width)
                    }
                    .onEnded { value in
                        model.endScrub(ratio: value.location.x / width)
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        model.endScrub(ratio: value.location.x / width)
                    }
            )
        }
        .frame(height: 16)
    }
}

struct TransportButton: View {
    let systemName: String
    var size: CGFloat
    var weight: Font.Weight = .bold
    var color: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(color)
                .frame(width: size + 10, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportButtonStyle())
    }
}

struct TransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

enum ArtworkPalette {
    private struct Bucket {
        var hue: CGFloat
        var weight: CGFloat = 0
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
    }

    /// Серый запасной цвет: нет обложки или она без выраженных цветов.
    static let neutral = (
        NSColor(calibratedWhite: 0.62, alpha: 1),
        NSColor(calibratedWhite: 0.5, alpha: 1)
    )

    static func colors(from image: NSImage?) -> (NSColor, NSColor) {
        guard let image, let rep = sample(image, side: 28) else { return neutral }

        var buckets = (0..<24).map { Bucket(hue: CGFloat($0) / 24) }

        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                var hue: CGFloat = 0
                var saturation: CGFloat = 0
                var brightness: CGFloat = 0
                var alpha: CGFloat = 0
                color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                guard alpha > 0.4, saturation > 0.18, brightness > 0.18, brightness < 0.97 else { continue }
                let index = min(23, Int(hue * 24))
                // Популярность цвета: сколько пикселей обложки он занимает, с лёгким перевесом насыщенных.
                let weight = 0.5 + saturation
                buckets[index].weight += weight
                buckets[index].red += color.redComponent * weight
                buckets[index].green += color.greenComponent * weight
                buckets[index].blue += color.blueComponent * weight
            }
        }

        let ranked = buckets.filter { $0.weight > 0 }.sorted { $0.weight > $1.weight }
        guard let first = ranked.first else { return neutral }
        let primary = readable(average(first))
        let alternate = ranked.dropFirst().first { hueDistance($0.hue, first.hue) > 0.08 }
        let secondary = alternate.map { readable(average($0)) } ?? lighter(primary)
        return (primary, secondary)
    }

    private static func sample(_ image: NSImage, side: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: NSRect(x: 0, y: 0, width: side, height: side),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func average(_ bucket: Bucket) -> NSColor {
        NSColor(
            calibratedRed: bucket.red / bucket.weight,
            green: bucket.green / bucket.weight,
            blue: bucket.blue / bucket.weight,
            alpha: 1
        )
    }

    private static func hueDistance(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        let distance = abs(lhs - rhs)
        return min(distance, 1 - distance)
    }

    private static func readable(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(
            hue: hue,
            saturation: min(1, max(0.38, saturation)),
            brightness: min(0.98, max(0.6, brightness)),
            alpha: 1
        )
    }

    private static func lighter(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(
            hue: hue,
            saturation: max(0.35, saturation * 0.72),
            brightness: min(1, brightness + 0.16),
            alpha: 1
        )
    }
}

enum PreviewArtwork {
    static func make() -> NSImage {
        let side: CGFloat = 420
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else { return image }
        let colors = [
            CGColor(red: 1.0, green: 0.42, blue: 0.28, alpha: 1),
            CGColor(red: 0.72, green: 0.18, blue: 0.52, alpha: 1),
            CGColor(red: 0.09, green: 0.08, blue: 0.28, alpha: 1),
        ] as CFArray
        let locations: [CGFloat] = [0, 0.48, 1]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: side),
                end: CGPoint(x: side, y: 0),
                options: []
            )
        }

        context.setFillColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        context.fillEllipse(in: CGRect(x: 78, y: 70, width: 250, height: 250))
        context.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
        context.fillEllipse(in: CGRect(x: 176, y: 168, width: 56, height: 56))
        return image
    }
}


/// Блок выкатывается сверху из области физического острова вместе с растущей формой.
/// Положение идёт той же пружиной, что и форма, а прозрачность появляется чуть раньше, чтобы не было резкого появления.
struct RollDown: ViewModifier {
    var expanded: Bool
    var travel: CGFloat
    var delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(expanded ? 1 : 0)
            .animation(expanded ? .easeOut(duration: 0.24).delay(delay) : .easeIn(duration: 0.12), value: expanded)
            .offset(y: expanded ? 0 : -travel)
            .animation(expanded ? .spring(response: 0.54, dampingFraction: 0.86).delay(delay) : .easeIn(duration: 0.2), value: expanded)
    }
}
