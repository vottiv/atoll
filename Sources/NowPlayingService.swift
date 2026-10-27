import AppKit
import ApplicationServices
import Darwin
import Foundation

/// Читает системный Now Playing через MediaRemote и шлёт команды плееру.
/// Источников может быть несколько сразу (Яндекс Музыка и YouTube в браузере): виджет показывает
/// выбранный, остальные лежат рядом иконками. Играть одновременно из виджета может только один.
final class NowPlayingService {
    private let model: IslandModel
    private let bridge: MediaRemoteBridge
    private var timer: Timer?
    private var sample = Sample()
    private var lastRefresh = Date.distantPast
    private var refreshing = false
    private var emptyStreak = 0
    /// Последняя перемотка: пока плеер не подтвердил новое время, его старые ответы игнорируем.
    private var pendingSeek: (target: TimeInterval, at: Date)?
    private var loggedState = ""

    private static let yandexBundle = "ru.yandex.desktop.music"

    private struct Source {
        var bundle: String
        var title: String
        var artist: String
        var duration: TimeInterval
        var elapsed: TimeInterval
        var rate: Double
        var isPlaying: Bool
        var artwork: NSImage?
    }

    private var sources: [Source] = []
    /// Порядок, в котором источники появились: иконки не прыгают местами при каждом обновлении.
    private var order: [String] = []
    /// Приложение, которому MediaRemote адресует команды: только ему можно слать play/pause напрямую.
    private var activeBundle: String?
    private var selected: String?
    private var wasPlaying: Set<String> = []
    private var artworkCache: [String: (token: Int, title: String, image: NSImage)] = [:]
    private var noticeToken = 0
    private var pendingBrowserAction: (Source, BrowserControl.Action)?
    /// Подсказка относится к одному источнику и одному треку: в другом плеере её быть не должно.
    private var noticeOwner: (bundle: String, title: String)?

    private struct Sample {
        var duration: TimeInterval = 0
        var elapsed: TimeInterval = 0
        var rate: Double = 0
        var takenAt = Date()
    }

    private enum Command: UInt32 {
        case play = 0
        case pause = 1
        case nextTrack = 4
        case previousTrack = 5
        case like = 21
        case dislike = 22
    }

    init?(model: IslandModel) {
        guard let bridge = MediaRemoteBridge() else { return nil }
        self.model = model
        self.bridge = bridge
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        let names = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        ]
        for name in names {
            center.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: Выбор источника

    func select(_ bundle: String) {
        guard sources.contains(where: { $0.bundle == bundle }) else { return }
        selected = bundle
        pendingSeek = nil
        publishSelection()
    }

    func openSource(_ bundle: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.activate()
    }

    private var current: Source? {
        sources.first { $0.bundle == selected }
    }

    // MARK: Управление

    /// Play на выбранном источнике: остальные играющие ставим на паузу, этот запускаем.
    func toggle() {
        guard let source = current else { return }
        if source.isPlaying {
            setPlaying(false, source)
        } else {
            let others = sources.filter { $0.bundle != source.bundle && $0.isPlaying }
            others.forEach { setPlaying(false, $0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + (others.isEmpty ? 0 : 0.4)) { [weak self] in
                self?.setPlaying(true, source)
            }
        }
        scheduleRefresh()
    }

    func next() {
        guard let source = current else { return }
        if source.bundle == activeBundle {
            bridge.send(command: Command.nextTrack.rawValue)
        } else if source.bundle == Self.yandexBundle {
            performDesktop(.next)
        } else {
            runBrowser(source, .next)
        }
        scheduleRefresh()
    }

    func previous() {
        guard let source = current else { return }
        if source.bundle == activeBundle {
            bridge.send(command: Command.previousTrack.rawValue)
        } else if source.bundle == Self.yandexBundle {
            performDesktop(.previous)
        } else {
            runBrowser(source, .previous)
        }
        scheduleRefresh()
    }

    func like() {
        if current?.bundle == Self.yandexBundle {
            react(.like)
        } else {
            bridge.send(command: Command.like.rawValue)
        }
    }

    func dislike() {
        if current?.bundle == Self.yandexBundle {
            react(.dislike)
        } else {
            bridge.send(command: Command.dislike.rawValue)
        }
    }

    /// Яндекс Музыка не отвечает на лайк из MediaRemote, поэтому жмём её кнопку в окне.
    private func react(_ reaction: DesktopPlayerReader.Reaction) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            DesktopPlayerReader.react(reaction)
            DispatchQueue.main.async { self?.syncReaction(after: 0.5) }
        }
    }

    /// Подтягивает состояние лайка из окна Яндекс Музыки: само приложение его через Accessibility не отдаёт,
    /// поэтому смотрим, закрашено ли сердечко. Дизлайк так не прочесть: после него трек пропускается.
    func syncReaction(after delay: TimeInterval = 0.8) {
        guard current?.bundle == Self.yandexBundle else { return }
        let key = model.title
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let coverage = DesktopPlayerReader.reactionCoverage() else { return }
            let liked = coverage.like > DesktopPlayerReader.filledHeartCoverage
            DispatchQueue.main.async {
                guard let model = self?.model, model.title == key, model.isLiked != liked else { return }
                model.isLiked = liked
                if liked { model.isDisliked = false }
            }
        }
    }

    func seek(to seconds: TimeInterval) {
        guard let source = current else { return }
        let target = max(0, seconds)
        pendingSeek = (target, Date())
        sample.elapsed = target
        sample.takenAt = Date()
        model.elapsed = target
        if source.bundle == activeBundle {
            bridge.seek(to: target)
            scheduleRefresh()
        } else if source.bundle == Self.yandexBundle, sample.duration > 0 {
            let ratio = target / sample.duration
            let duration = sample.duration
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                DesktopPlayerReader.seek(ratio: ratio, duration: duration)
                DispatchQueue.main.async { self?.refresh() }
            }
        } else {
            runBrowser(source, .seek(target))
            scheduleRefresh()
        }
    }

    private func setPlaying(_ play: Bool, _ source: Source) {
        if source.bundle == activeBundle {
            bridge.send(command: (play ? Command.play : Command.pause).rawValue)
        } else if source.bundle == Self.yandexBundle {
            if source.isPlaying != play { performDesktop(.toggle) }
        } else {
            runBrowser(source, play ? .play : .pause)
        }
    }

    private func performDesktop(_ control: DesktopPlayerReader.Control) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            DesktopPlayerReader.press(control)
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    /// Не активный в MediaRemote браузер адресно не достать, поэтому говорим со вкладкой напрямую.
    private func runBrowser(_ source: Source, _ action: BrowserControl.Action) {
        BrowserControl.run(bundle: source.bundle, title: source.title, action: action) { [weak self] problem in
            guard let problem else { return }
            DispatchQueue.main.async { self?.handle(problem, source: source, retry: action) }
        }
    }

    private func handle(_ problem: BrowserControl.Problem, source: Source, retry action: BrowserControl.Action) {
        let name = appName(source.bundle)
        switch problem {
        case .javaScriptDisabled:
            pendingBrowserAction = (source, action)
            showNotice("Нажми, чтобы разрешить управление в \(name)", for: source, actionable: true)
        case .automationDenied:
            showNotice("Разреши Atoll управлять \(name): Настройки → Конфиденциальность → Автоматизация", for: source)
        case .tabNotFound:
            showNotice("Вкладка с этим треком не найдена", for: source)
        case .failed:
            showNotice("Не удалось управлять \(name)", for: source)
        }
    }

    private func appName(_ bundle: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return "браузере" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Нажатие на подсказку: спрашиваем согласие и включаем пункт меню браузера.
    func confirmBrowserAccess() {
        guard let (source, action) = pendingBrowserAction else { return }
        let name = appName(source.bundle)
        let alert = NSAlert()
        alert.messageText = "Разрешить Atoll управлять вкладками в \(name)?"
        alert.informativeText = "Чтобы ставить видео на паузу, пока активен другой плеер, Atoll включит в \(name) пункт «Вид → Разработчикам → Разрешить JavaScript из событий Apple». После этого любая программа с доступом к Автоматизации сможет выполнять скрипты в твоих вкладках. Выключить пункт можно там же в любой момент."
        alert.addButton(withTitle: "Включить")
        alert.addButton(withTitle: "Отмена")
        alert.window.level = .statusBar
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.notice = nil
        BrowserControl.enableJavaScript(bundle: source.bundle) { [weak self] enabled in
            DispatchQueue.main.async {
                guard let self else { return }
                if enabled {
                    self.pendingBrowserAction = nil
                    self.runBrowser(source, action)
                    self.scheduleRefresh()
                } else {
                    self.showNotice("Включи вручную: Вид → Разработчикам → Разрешить JavaScript из событий Apple", for: source)
                }
            }
        }
    }

    private func showNotice(_ text: String, for source: Source, actionable: Bool = false) {
        // Показываем, только пока выбран тот же источник и трек.
        guard current?.bundle == source.bundle, current?.title == source.title else { return }
        noticeToken += 1
        let token = noticeToken
        noticeOwner = (source.bundle, source.title)
        model.noticeIsActionable = actionable
        model.notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + (actionable ? 12 : 5)) { [weak self] in
            guard let self, self.noticeToken == token else { return }
            self.model.notice = nil
        }
    }

    private func scheduleRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: Чтение

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        lastRefresh = Date()
        bridge.fetchAll { [weak self] overview in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                // Сбой запроса — не повод стирать трек.
                guard let overview else { return }
                self.apply(overview)
            }
        }
    }

    private func tick() {
        if Date().timeIntervalSince(lastRefresh) >= 1 {
            refresh()
        }
        guard model.hasTrack, !model.isScrubbing, sample.duration > 0 else { return }
        let delta = min(30, max(0, Date().timeIntervalSince(sample.takenAt)))
        let predicted = sample.elapsed + delta * sample.rate
        let upper = sample.duration > 0 ? sample.duration : predicted
        model.elapsed = min(max(0, predicted), upper)
    }

    private func apply(_ overview: MediaRemoteBridge.Overview) {
        activeBundle = overview.activeBundleID
        var found: [Source] = []
        for client in overview.clients {
            guard let source = makeSource(client, overview: overview) else { continue }
            if let index = found.firstIndex(where: { $0.bundle == source.bundle }) {
                if source.isPlaying && !found[index].isPlaying { found[index] = source }
            } else {
                found.append(source)
            }
        }

        // Яндекс Музыка иногда не видна в MediaRemote: читаем её через Универсальный доступ.
        if !found.contains(where: { $0.bundle == Self.yandexBundle }), let track = DesktopPlayerReader.currentTrack() {
            found.append(Source(
                bundle: Self.yandexBundle,
                title: track.title,
                artist: track.artist,
                duration: track.duration,
                elapsed: track.elapsed,
                rate: track.isPlaying && track.duration > 0 ? 1 : 0,
                isPlaying: track.isPlaying,
                artwork: track.artwork
            ))
        }

        for source in found where !order.contains(source.bundle) { order.append(source.bundle) }
        found.sort { (order.firstIndex(of: $0.bundle) ?? 0) < (order.firstIndex(of: $1.bundle) ?? 0) }

        guard !found.isEmpty else {
            // Пустой ответ бывает мимолётным (смена трека): очищаем только после нескольких подряд.
            emptyStreak += 1
            if model.hasTrack && emptyStreak < 3 { return }
            sources = []
            selected = nil
            wasPlaying = []
            sample = Sample()
            model.setSources([], selected: nil)
            model.clearTrack()
            logState()
            return
        }
        emptyStreak = 0
        sources = found

        // Запустили воспроизведение где-то ещё — переключаемся туда сами.
        let playingNow = Set(found.filter(\.isPlaying).map(\.bundle))
        let started = playingNow.subtracting(wasPlaying)
        wasPlaying = playingNow
        if let selectedBundle = selected, !found.contains(where: { $0.bundle == selectedBundle }) {
            selected = nil
        }
        if let started = started.first(where: { $0 == activeBundle }) ?? started.first, started != selected {
            selected = started
        }
        if selected == nil {
            selected = found.first(where: { $0.bundle == activeBundle })?.bundle
                ?? found.first(where: \.isPlaying)?.bundle
                ?? found.first?.bundle
        }
        publishSelection()
    }

    private func makeSource(_ client: MediaRemoteBridge.Client, overview: MediaRemoteBridge.Overview) -> Source? {
        let dict = client.info
        let title = string(dict, "kMRMediaRemoteNowPlayingInfoTitle")
        guard !title.isEmpty else { return nil }
        let rateValue = number(dict, "kMRMediaRemoteNowPlayingInfoPlaybackRate") ?? 0
        let isActive = client.bundleID == overview.activeBundleID
        let playing = rateValue > 0.01 || (isActive && overview.activeIsPlaying)
        let rate = playing ? (rateValue > 0.01 ? rateValue : 1) : 0
        let duration = number(dict, "kMRMediaRemoteNowPlayingInfoDuration") ?? 0
        let elapsed = number(dict, "kMRMediaRemoteNowPlayingInfoElapsedTime") ?? 0
        let timestamp = dict["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date ?? Date()
        // Время в ответе снято в `timestamp`, а не сейчас: достраиваем до текущего момента,
        // иначе таймлайн каждую секунду откатывается назад и мерцает.
        var current = elapsed + max(0, Date().timeIntervalSince(timestamp)) * rate
        if duration > 0 { current = min(current, duration) }

        let artist = string(dict, "kMRMediaRemoteNowPlayingInfoArtist")
        let album = string(dict, "kMRMediaRemoteNowPlayingInfoAlbum")
        return Source(
            bundle: client.bundleID,
            title: title,
            artist: artist.isEmpty ? album : artist,
            duration: duration,
            elapsed: current,
            rate: rate,
            isPlaying: playing,
            artwork: artwork(for: client.bundleID, title: title, data: dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data)
        )
    }

    /// Обложку отдают только для активного клиента, остальным показываем последнюю виденную для того же трека.
    private func artwork(for bundle: String, title: String, data: Data?) -> NSImage? {
        if let data, !data.isEmpty {
            let token = dataHash(data)
            if let cached = artworkCache[bundle], cached.token == token { return cached.image }
            if let image = NSImage(data: data) {
                artworkCache[bundle] = (token, title, image)
                return image
            }
        }
        if let cached = artworkCache[bundle], cached.title == title { return cached.image }
        return nil
    }

    /// Показывает выбранный источник в виджете.
    private func publishSelection() {
        model.setSources(sources.map(\.bundle), selected: selected)
        guard let source = current else { return }
        if let owner = noticeOwner, owner.bundle != source.bundle || owner.title != source.title {
            noticeOwner = nil
            model.notice = nil
        }
        let shownElapsed = reconcileAfterSeek(source.elapsed, playing: source.isPlaying, duration: source.duration)
        sample = Sample(duration: source.duration, elapsed: shownElapsed, rate: source.rate, takenAt: Date())
        model.needsPlayerAccess = false
        model.setSource(bundleID: source.bundle)
        model.applyTrack(
            title: source.title,
            artist: source.artist,
            duration: source.duration,
            elapsed: shownElapsed,
            isPlaying: source.isPlaying,
            artwork: source.artwork
        )
        logState()
    }

    /// Плеер после перемотки ещё 1–2 секунды может отдавать старое время. Пока ответ не совпал
    /// с ожидаемым, показываем время от цели перемотки, чтобы цифры не мигали назад.
    private func reconcileAfterSeek(_ reported: TimeInterval, playing: Bool, duration: TimeInterval) -> TimeInterval {
        guard let pending = pendingSeek else { return reported }
        let age = Date().timeIntervalSince(pending.at)
        guard age < 5 else {
            pendingSeek = nil
            return reported
        }
        var expected = pending.target + (playing ? age : 0)
        if duration > 0 { expected = min(expected, duration) }
        if abs(reported - expected) <= 2 {
            pendingSeek = nil
            return reported
        }
        return expected
    }

    private func logState() {
        let line = "title=\(model.title) artist=\(model.artist) source=\(selected ?? "-") active=\(activeBundle ?? "-") sources=\(sources.map(\.bundle)) playing=\(model.isPlaying) art=\(model.artwork != nil)"
        guard line != loggedState else { return }
        loggedState = line
        try? (line + "\n").write(toFile: DebugLog.path("player.log"), atomically: false, encoding: .utf8)
    }

    private func string(_ dict: [String: Any], _ key: String) -> String {
        if let value = dict[key] as? String { return value }
        if let value = dict[key] as? NSString { return value as String }
        return ""
    }

    private func number(_ dict: [String: Any], _ key: String) -> Double? {
        (dict[key] as? NSNumber)?.doubleValue
    }

    private func dataHash(_ data: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(data.count)
        hasher.combine(data.prefix(128))
        return hasher.finalize()
    }
}

/// Управление вкладкой браузера напрямую: MediaRemote адресует команды только активному клиенту,
/// а второй играющий источник (например, YouTube, пока играет Яндекс Музыка) так не достать.
/// Нужен включённый в браузере пункт «Разрешить JavaScript из событий Apple».
enum BrowserControl {
    enum Action {
        case play
        case pause
        case next
        case previous
        case seek(TimeInterval)
    }

    enum Problem {
        case javaScriptDisabled
        case automationDenied
        case tabNotFound
        case failed
    }

    /// Идентификатор попадает прямо в текст скрипта, поэтому принимаем только обычный bundle ID.
    private static func isSafe(_ bundle: String) -> Bool {
        bundle.range(of: "^[A-Za-z0-9.-]{1,100}$", options: .regularExpression) != nil
    }

    /// Включает в браузере пункт «Разрешить JavaScript из событий Apple» через меню. Зовём только после согласия пользователя.
    static func enableJavaScript(bundle: String, completion: @escaping (Bool) -> Void) {
        guard isSafe(bundle), bundle != "com.apple.Safari" else {
            completion(false)
            return
        }
        let script = """
        tell application "System Events"
          tell (first process whose bundle identifier is "\(bundle)")
            set bar to menu bar 1
            repeat with spec in {{"Вид", "Разработчикам", "Разрешить JavaScript из событий Apple"}, {"View", "Developer", "Allow JavaScript from Apple Events"}}
              try
                set m to menu item (item 3 of spec) of menu 1 of menu item (item 2 of spec) of menu 1 of menu bar item (item 1 of spec) of bar
                if (value of attribute "AXMenuItemMarkChar" of m) is missing value then click m
                return "ok"
              end try
            end repeat
          end tell
        end tell
        return "fail"
        """
        DispatchQueue.global(qos: .userInitiated).async {
            completion(runScript(script).output.contains("ok"))
        }
    }

    private static func runScript(_ script: String) -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (-1, "", "") }
        process.waitUntilExit()
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output, error)
    }

    static func run(bundle: String, title: String, action: Action, completion: @escaping (Problem?) -> Void) {
        guard isSafe(bundle) else {
            completion(.failed)
            return
        }
        let script = appleScript(bundle: bundle, title: title, javaScript: javaScript(for: action))
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runScript(script)
            if result.status != 0 {
                completion(result.error.contains("(-1743)") ? .automationDenied : .javaScriptDisabled)
            } else if result.output.contains("nomatch") {
                completion(.tabNotFound)
            } else {
                completion(nil)
            }
        }
    }

    private static func javaScript(for action: Action) -> String {
        let media = "var m=document.querySelector('video')||document.querySelector('audio');"
        switch action {
        case .play: return "(function(){\(media)if(m)m.play();})()"
        case .pause: return "(function(){document.querySelectorAll('video,audio').forEach(function(m){m.pause();});})()"
        case .next: return "(function(){var b=document.querySelector('.ytp-next-button');if(b)b.click();})()"
        case .previous: return "(function(){\(media)if(m)m.currentTime=0;})()"
        case .seek(let seconds):
            let value = seconds.isFinite ? Int(min(max(seconds, 0), 86_400)) : 0
            return "(function(){\(media)if(m)m.currentTime=\(value);})()"
        }
    }

    private static func appleScript(bundle: String, title: String, javaScript: String) -> String {
        let needle = escape(String(title.prefix(24)).filter { !$0.isNewline })
        let js = escape(javaScript)
        if bundle == "com.apple.Safari" {
            return """
            tell application id "\(bundle)"
              repeat with w in windows
                repeat with t in tabs of w
                  if (name of t) contains "\(needle)" then
                    do JavaScript "\(js)" in t
                    return "ok"
                  end if
                end repeat
              end repeat
            end tell
            return "nomatch"
            """
        }
        return """
        tell application id "\(bundle)"
          repeat with w in windows
            repeat with t in tabs of w
              if (title of t) contains "\(needle)" then
                execute t javascript "\(js)"
                return "ok"
              end if
            end repeat
          end repeat
        end tell
        return "nomatch"
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum DesktopPlayerReader {
    struct Track {
        var title: String
        var artist: String
        var isPlaying: Bool
        var elapsed: TimeInterval
        var duration: TimeInterval
        var artwork: NSImage?
        var albumID: String?
    }

    enum Control {
        case toggle
        case next
        case previous
    }

    private static let bundleID = "ru.yandex.desktop.music"
    private static var didPrompt = false
    private static var cache: (date: Date, track: Track?)?
    private static var logged = ""

    static var playerIsRunning: Bool {
        application() != nil
    }

    static func dump() {
        var lines: [String] = ["trusted=\(AXIsProcessTrusted())"]
        guard AXIsProcessTrusted(), let window = mainWindow() else {
            lines.append("no-window")
            try? lines.joined(separator: "\n").write(toFile: DebugLog.path("ax-dump.txt"), atomically: true, encoding: .utf8)
            return
        }
        showPlayerWindow(window.element)
        Thread.sleep(forTimeInterval: 0.55)
        lines.append("window=\(rect(window.frame))")
        var remaining = 6000
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 32, remaining > 0 else { return }
            remaining -= 1
            let description = stringAttribute(element, kAXDescriptionAttribute)
            let role = stringAttribute(element, kAXRoleAttribute)
            let node = frame(of: element) ?? .zero
            let nearBar = node.minY > 1700 && node.minY < 1900
            let value = nearBar && role == (kAXStaticTextRole as String) ? describe(element, kAXValueAttribute) : ""
            if description == "Плеер"
                || description.hasPrefix("Альбом")
                || description.localizedCaseInsensitiveContains("таймкод")
                || description.localizedCaseInsensitiveContains("пауз")
                || description.localizedCaseInsensitiveContains("следующ")
                || role == (kAXSliderRole as String)
                || (nearBar && (!description.isEmpty || !value.isEmpty)) {
                lines.append("d\(depth) \(role) d=\(description) v=\(value) \(rect(node))")
            }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success else { return }
            for child in axElements(children) { visit(child, depth: depth + 1) }
        }
        visit(window.element, depth: 0)
        lines.append("remaining=\(remaining)")
        try? lines.joined(separator: "\n").write(toFile: DebugLog.path("ax-dump.txt"), atomically: true, encoding: .utf8)
    }

    /// Диагностика: пишет AX-дерево плеера, кнопки окна, кадр обложки и тест скриншота в /tmp/island-ax-probe.txt
    static func probe() {
        var lines: [String] = []
        lines.append("trusted=\(AXIsProcessTrusted()) app=\(application() != nil)")
        defer { writeProbe(lines) }
        guard let app = application() else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        var windowsValue: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        let windows = axElements(windowsValue)
        lines.append("windows=\(windows.count)")
        guard let window = mainWindow() else { return }
        lines.append("main frame=\(rect(window.frame))")

        if let player = findPlayer(in: window.element) {
            lines.append("player frame=\(rect(frame(of: player) ?? .zero))")
            dumpTree(player, into: &lines, budget: 600)
        } else {
            lines.append("player=nil")
        }

        let buttons = controlButtons(in: window.element)
        lines.append(
            "window buttons: \(buttons.map { "'\($0.text)' [\(Int($0.frame.width))x\(Int($0.frame.height))]" }.joined(separator: " | "))"
        )
        if let album = albumFrame(in: window.element) {
            lines.append("album frame=\(rect(album))")
        } else {
            lines.append("album frame=nil")
        }
        if let shot = windowImage(of: window.frame) {
            lines.append("shot \(shot.pixels.width)x\(shot.pixels.height) scale=\(shot.scale)")
            let rep = NSBitmapImageRep(cgImage: shot.pixels)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: DebugLog.path("probe-window.png")))
        } else {
            lines.append("shot=nil")
        }
    }

    private static func dumpTree(_ root: AXUIElement, into lines: inout [String], budget: Int) {
        var remaining = budget
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 16, remaining > 0 else { return }
            remaining -= 1
            let role = stringAttribute(element, kAXRoleAttribute)
            let description = stringAttribute(element, kAXDescriptionAttribute)
            let title = stringAttribute(element, kAXTitleAttribute)
            var actions: CFArray?
            AXUIElementCopyActionNames(element, &actions)
            let actionList = ((actions as? [String]) ?? []).joined(separator: ",")
            let interesting = !description.isEmpty || !title.isEmpty
                || role == (kAXButtonRole as String)
                || role == (kAXCheckBoxRole as String)
                || role == (kAXSliderRole as String)
                || role == (kAXImageRole as String)
            if interesting {
                let indent = String(repeating: "·", count: depth)
                lines.append("\(indent)\(role) desc='\(description)' title='\(title)' actions=[\(actionList)] \(frame(of: element).map(rect) ?? "?")")
            }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success else { return }
            for child in axElements(children) { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
    }

    private static func writeProbe(_ lines: [String]) {
        try? lines.joined(separator: "\n").write(toFile: DebugLog.path("ax-probe.txt"), atomically: true, encoding: .utf8)
    }

    private static func dumpAttributes(_ element: AXUIElement, depth: Int, into lines: inout [String], budget: Int) {
        var left = budget
        func go(_ element: AXUIElement, depth: Int) {
            guard left > 0, depth < 24 else { return }
            left -= 1
            AXUIElementSetMessagingTimeout(element, 0.05)
            var names: CFArray?
            var parts: [String] = []
            if AXUIElementCopyAttributeNames(element, &names) == .success, let names = names as? [String] {
                for name in names where name != kAXChildrenAttribute && name != kAXParentAttribute && name != "AXChildrenInNavigationOrder" && name != kAXPositionAttribute && name != kAXSizeAttribute {
                    let value = describe(element, name)
                    if !value.isEmpty {
                        parts.append("\(name)=\(value)")
                    }
                }
            }
            let node = frame(of: element) ?? .zero
            lines.append("p\(depth) \(rect(node)) \(parts.joined(separator: " ;; "))")
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success else { return }
            for child in axElements(children) {
                go(child, depth: depth + 1)
            }
        }
        go(element, depth: depth)
    }

    private static func describe(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return "" }
        if let text = value as? String { return text }
        if let text = value as? NSAttributedString { return text.string }
        if let number = value as? NSNumber { return number.stringValue }
        if let url = value as? URL { return url.absoluteString }
        return ""
    }

    private static func describeValue(_ value: CFTypeRef?) -> String {
        guard let value else { return "nil" }
        if let number = value as? NSNumber { return number.stringValue }
        if let text = value as? String { return text }
        return String(describing: type(of: value))
    }

    private static func rect(_ frame: CGRect) -> String {
        String(format: "%.0f,%.0f %.0fx%.0f", frame.origin.x, frame.origin.y, frame.width, frame.height)
    }

    static func seekProbe() {
        cache = nil
        let before = read()
        let duration = before?.duration ?? 0
        seek(ratio: 0.55, duration: duration)
        Thread.sleep(forTimeInterval: 0.6)
        cache = nil
        let after = read()
        let lines = [
            "before \(Int(before?.elapsed ?? -1))/\(Int(before?.duration ?? -1))",
            "after \(Int(after?.elapsed ?? -1))/\(Int(after?.duration ?? -1))",
            "ok=\(after.map { abs(($0.elapsed / max(1, $0.duration)) - 0.55) < 0.12 } ?? false)",
        ]
        try? lines.joined(separator: "\n").write(toFile: DebugLog.path("seek.txt"), atomically: true, encoding: .utf8)
    }

    static func controlCheck() {
        var lines: [String] = []
        func snap(_ label: String) {
            cache = nil
            let track = read()
            lines.append("\(label) title=\(track?.title ?? "-") playing=\(track?.isPlaying ?? false) elapsed=\(Int(track?.elapsed ?? -1)) duration=\(Int(track?.duration ?? -1)) art=\(track?.artwork != nil)")
        }
        snap("start")
        for _ in 0..<8 where artworkCache?.image == nil {
            Thread.sleep(forTimeInterval: 0.35)
            cache = nil
            _ = read()
        }
        snap("art-ready")
        let origin = read()
        press(.toggle)
        Thread.sleep(forTimeInterval: 0.85)
        snap("toggled")
        press(.toggle)
        Thread.sleep(forTimeInterval: 0.85)
        snap("toggle-back")
        let beforeNext = read()?.title
        press(.next)
        Thread.sleep(forTimeInterval: 1.1)
        snap("next")
        let afterNext = read()?.title
        lines.append("next-changed=\(beforeNext != nil && beforeNext != afterNext)")
        press(.previous)
        Thread.sleep(forTimeInterval: 1.1)
        snap("previous")
        if let origin, origin.duration > 1 {
            let jump = 0.2
            seek(ratio: jump, duration: origin.duration)
            Thread.sleep(forTimeInterval: 1.0)
            snap("seek")
            if let after = read(), after.duration > 1 {
                let ratio = after.elapsed / after.duration
                lines.append("seek-ratio=\(String(format: "%.2f", ratio)) ok=\(abs(ratio - jump) < 0.15)")
            }
        } else {
            lines.append("seek skipped")
        }
        try? lines.joined(separator: "\n").write(toFile: DebugLog.path("check.txt"), atomically: true, encoding: .utf8)
    }

    static func statusLine() -> String {
        guard let track = currentTrack() else {
            var reason = "track=nil trusted=\(AXIsProcessTrusted()) running=\(application() != nil)"
            if let window = mainWindow() {
                reason += " window=\(rect(window.frame))"
                if let player = findPlayer(in: window.element) {
                    let info = inspect(player)
                    reason += " player title=\(info.title) artist=\(info.artist) playing=\(info.isPlaying)"
                } else {
                    reason += " player=nil"
                }
            } else {
                reason += " window=nil"
            }
            return reason
        }
        var extra = ""
        if let window = mainWindow(), let player = findPlayer(in: window.element) {
            extra = "\n" + playerTexts(in: player).joined(separator: "\n")
        }
        return "title=\(track.title) artist=\(track.artist) playing=\(track.isPlaying) elapsed=\(Int(track.elapsed)) duration=\(Int(track.duration)) album=\(track.albumID ?? "-") art=\(track.artwork != nil)\(extra)"
    }

    private static func playerTexts(in player: AXUIElement) -> [String] {
        var lines: [String] = []
        var remaining = 250
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 14, remaining > 0, lines.count < 24 else { return }
            remaining -= 1
            let role = stringAttribute(element, kAXRoleAttribute)
            if role == (kAXStaticTextRole as String) {
                let text = describe(element, kAXValueAttribute)
                if !text.isEmpty {
                    lines.append("text y=\(Int(frame(of: element)?.minY ?? -1)) \(text)")
                }
            }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success else { return }
            for child in axElements(children) { visit(child, depth: depth + 1) }
        }
        visit(player, depth: 0)
        return lines
    }

    static func currentTrack() -> Track? {
        guard application() != nil else { return nil }
        guard trusted(prompt: true) else { return nil }
        if let cache, Date().timeIntervalSince(cache.date) < 0.8 {
            return cache.track
        }
        let track = read()
        cache = (Date(), track)
        if let track {
            note(track)
        }
        return track
    }

    @discardableResult
    static func press(_ control: Control) -> String {
        cache = nil
        // AXPress и синтетический клик по кнопке трек не меняют. Работают шорткаты
        // приложения, и только когда оно на переднем плане.
        let key: CGKeyCode
        switch control {
        case .toggle: key = 40
        case .next: key = 45
        case .previous: key = 35
        }
        return sendShortcut(key, label: "\(control)")
    }

    private static func logControl(_ result: String, _ control: Control) -> String {
        logLine("\(control) → \(result)")
        return result
    }

    enum MediaKey {
        case play
        case next
        case previous

        var code: Int {
            switch self {
            case .play: return 16
            case .next: return 17
            case .previous: return 18
            }
        }
    }

    static func sendMediaKey(_ key: MediaKey) {
        func event(_ push: Bool) -> NSEvent? {
            NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: push ? 0xA00 : 0xB00),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (key.code << 16) | (push ? 0x0A00 : 0x0B00),
                data2: -1
            )
        }
        event(true)?.cgEvent?.post(tap: .cghidEventTap)
        event(false)?.cgEvent?.post(tap: .cghidEventTap)
    }

    private static func logLine(_ text: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let data = Data("[\(stamp)] \(text)\n".utf8)
        if let handle = FileHandle(forWritingAtPath: DebugLog.path("press.log")) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: DebugLog.path("press.log")))
        }
    }

    private static func controlButtons(in root: AXUIElement) -> [(element: AXUIElement, text: String, frame: CGRect)] {
        var result: [(AXUIElement, String, CGRect)] = []
        var remaining = 200
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 12, remaining > 0 else { return }
            remaining -= 1
            let role = stringAttribute(element, kAXRoleAttribute)
            let description = stringAttribute(element, kAXDescriptionAttribute).lowercased()
            if (role == (kAXButtonRole as String) || role == (kAXCheckBoxRole as String)), !description.isEmpty {
                result.append((element, description, frame(of: element) ?? .zero))
            }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return }
            for child in axElements(value) {
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return result
    }

    private static func albumFrame(in root: AXUIElement) -> CGRect? {
        var found: CGRect?
        var remaining = 200
        func visit(_ element: AXUIElement, depth: Int) {
            guard found == nil, depth < 12, remaining > 0 else { return }
            remaining -= 1
            if stringAttribute(element, kAXDescriptionAttribute).hasPrefix("Альбом"),
               let node = frame(of: element), node.width > 40, node.height > 40 {
                found = node
                return
            }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return }
            for child in axElements(value) { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return found
    }

    private static func sliderElement(in root: AXUIElement) -> AXUIElement? {
        var found: AXUIElement?
        var remaining = 2000
        func visit(_ element: AXUIElement, depth: Int) {
            guard found == nil, depth < 30, remaining > 0 else { return }
            remaining -= 1
            if stringAttribute(element, kAXDescriptionAttribute).localizedCaseInsensitiveContains("таймкод") {
                found = element
                return
            }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return }
            for child in axElements(value) {
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return found
    }

    enum Reaction: String {
        case like = "Нравится"
        case dislike = "Не нравится"
    }

    /// Кнопки «Нравится» есть и в строках списков на странице. Нужна та, что в нижней панели плеера: самая нижняя.
    private static func reactionBox(_ reaction: Reaction, in root: AXUIElement) -> AXUIElement? {
        var found: [(element: AXUIElement, y: CGFloat)] = []
        var remaining = 4000
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 30, remaining > 0 else { return }
            remaining -= 1
            if stringAttribute(element, kAXRoleAttribute) == (kAXCheckBoxRole as String),
               stringAttribute(element, kAXDescriptionAttribute) == reaction.rawValue,
               let node = frame(of: element) {
                found.append((element, node.minY))
            }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return }
            for child in axElements(value) { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return found.max { $0.y < $1.y }?.element
    }

    /// Нажимает «Нравится» / «Не нравится» в нижней панели плеера: MediaRemote-команды Яндекс Музыка игнорирует,
    /// AXPress и клик мышью без активации тоже. Работает фокус на чекбоксе (AXFocused) и пробел, отправленный
    /// адресно в процесс: приложение остаётся неактивным, окно не выходит на экран. Свёрнутое окно ключевым быть
    /// не может, поэтому его на время нажатия разворачивают за пределами экрана и сразу сворачивают обратно.
    /// Состояние кнопок через Accessibility не читается (AXValue пуст), его ведёт виджет и сверяет по пикселям.
    static func react(_ reaction: Reaction) {
        guard AXIsProcessTrusted(), let window = mainWindow() else {
            logLine("react \(reaction.rawValue) → no-window")
            return
        }
        let wasMinimized = isMinimized(window.element)
        var original: CGPoint?
        if wasMinimized {
            original = position(of: window.element)
            setPosition(CGPoint(x: -30000, y: 200), of: window.element)
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            // Раскладка после разворачивания меняется, кнопку ищем уже в живом окне.
            Thread.sleep(forTimeInterval: 0.5)
        }
        // Клавиши получает ключевое окно приложения: делаем окно главным и ключевым, не активируя само приложение.
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.2)
        var pressed = false
        if let box = reactionBox(reaction, in: window.element) {
            AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            Thread.sleep(forTimeInterval: 0.15)
            sendKey(49, global: false)
            Thread.sleep(forTimeInterval: 0.15)
            pressed = true
        }
        if wasMinimized {
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            Thread.sleep(forTimeInterval: 0.4)
            if let original { setPosition(original, of: window.element) }
        }
        logLine("react \(reaction.rawValue) pressed=\(pressed) wasMinimized=\(wasMinimized)")
    }

    private static func position(of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func setPosition(_ point: CGPoint, of element: AXUIElement) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    /// Доля «чернил» (пикселей, заметно отличающихся от фона кнопки) внутри кадра кнопки: у закрашенной иконки она заметно больше, чем у контурной.
    private static func inkCoverage(_ shot: WindowShot, window: CGRect, button: CGRect) -> Double? {
        let inner = button.insetBy(dx: button.width * 0.2, dy: button.height * 0.2)
        let rect = CGRect(
            x: (inner.minX - window.minX) * shot.scale,
            y: (inner.minY - window.minY) * shot.scale,
            width: inner.width * shot.scale,
            height: inner.height * shot.scale
        ).integral
        guard let crop = shot.pixels.cropping(to: rect),
              let rep = Optional(NSBitmapImageRep(cgImage: crop)), rep.pixelsWide > 2, rep.pixelsHigh > 2 else { return nil }
        func luma(_ x: Int, _ y: Int) -> Double {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
            return 0.299 * Double(color.redComponent) + 0.587 * Double(color.greenComponent) + 0.114 * Double(color.blueComponent)
        }
        let background = luma(0, 0)
        var ink = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where abs(luma(x, y) - background) > 0.2 { ink += 1 }
        }
        return Double(ink) / Double(rep.pixelsWide * rep.pixelsHigh)
    }

    /// Закрашенное сердечко даёт ≈0,33 покрытия, контурное ≈0,16 (замер в окне 5120×2160).
    static let filledHeartCoverage = 0.25

    static func reactionCoverage() -> (like: Double, dislike: Double)? {
        // У свёрнутого окна нет ни снимка, ни актуальной раскладки: состояние неизвестно.
        guard let window = mainWindow(), !isMinimized(window.element),
              let like = reactionBox(.like, in: window.element), let likeFrame = frame(of: like),
              let dislike = reactionBox(.dislike, in: window.element), let dislikeFrame = frame(of: dislike),
              let shot = windowImage(of: window.frame),
              let likeInk = inkCoverage(shot, window: window.frame, button: likeFrame),
              let dislikeInk = inkCoverage(shot, window: window.frame, button: dislikeFrame) else { return nil }
        return (likeInk, dislikeInk)
    }

    private static func sliderValue(in root: AXUIElement) -> String {
        guard let slider = sliderElement(in: root) else { return "" }
        return describe(slider, kAXValueAttribute)
    }

    private static func windowSize(_ item: [String: Any]) -> CGSize {
        guard let bounds = item[kCGWindowBounds as String] as? [String: Any] else { return .zero }
        return CGSize(
            width: (bounds["Width"] as? NSNumber)?.doubleValue ?? 0,
            height: (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
        )
    }

    private struct WindowShot {
        var pixels: CGImage
        var scale: CGFloat
    }

    private static func windowImageDebug(of frame: CGRect) -> String {
        guard let pid = application()?.processIdentifier else { return "windowImage pid=nil" }
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let owned = info.filter { item in
            let owner = item[kCGWindowOwnerPID as String]
            return "\(owner ?? "")" == "\(pid)" || (owner as? Int) == Int(pid) || (owner as? Int32) == pid
        }
        let target = owned.first { windowSize($0).width > 400 && windowSize($0).height > 400 }
        let raw = target?[kCGWindowNumber as String]
        let number = (raw as? NSNumber)?.uint32Value
        let image = number.flatMap { CGWindowListCreateImage(.null, .optionIncludingWindow, $0, [.boundsIgnoreFraming, .bestResolution]) }
        return "windowImage pid=\(pid) rawType=\(raw.map { String(describing: type(of: $0)) } ?? "nil") number=\(number.map(String.init) ?? "nil") image=\(image.map { "\($0.width)x\($0.height)" } ?? "nil")"
    }

    private static func windowImage(of frame: CGRect) -> WindowShot? {
        guard frame.width > 1, frame.height > 1 else { return nil }
        let options: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        var image: CGImage?
        let pid = application()?.processIdentifier
        if let pid {
            let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
            let number = info.first(where: { item in
                guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else { return false }
                let size = windowSize(item)
                return size.width > 400 && size.height > 400
            })?[kCGWindowNumber as String] as? NSNumber
            if let number = number?.uint32Value {
                image = CGWindowListCreateImage(.null, .optionIncludingWindow, number, options)
            }
        }
        if image == nil {
            let top = NSScreen.screens.map(\.frame.maxY).max() ?? frame.maxY
            let region = CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
            image = CGWindowListCreateImage(region, .optionOnScreenOnly, kCGNullWindowID, options)
        }
        guard let image else { return nil }
        let scale = CGFloat(image.width) / frame.width
        return WindowShot(pixels: image, scale: scale)
    }

    private static func saveImage(_ frame: CGRect, name: String) {
        guard let image = CGWindowListCreateImage(frame, .optionOnScreenOnly, kCGNullWindowID, [.boundsIgnoreFraming, .bestResolution]) else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: DebugLog.path("\(name).png")))
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value)
        return (value as? NSNumber)?.boolValue == true
    }

    private static func waitUntilFront() -> Bool {
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    private static func restoreFocus(_ previous: NSRunningApplication?, window: AXUIElement, wasMinimized: Bool) {
        if wasMinimized {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }
        if previous?.bundleIdentifier != bundleID {
            previous?.activate()
        }
    }

    /// Шорткат уходит в систему только если фокус уже у Яндекс Музыки, иначе буква попадёт в другое приложение.
    private static func sendShortcut(_ key: CGKeyCode, label: String) -> String {
        guard let window = mainWindow() else { return logControl("no-window", label) }
        let wasMinimized = isMinimized(window.element)
        let previous = NSWorkspace.shared.frontmostApplication
        showPlayerWindow(window.element)
        guard waitUntilFront() else {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
            restoreFocus(previous, window: window.element, wasMinimized: wasMinimized)
            NSApp.setActivationPolicy(.accessory)
            return logControl("not-front \(front)", label)
        }
        sendKey(key, global: true)
        Thread.sleep(forTimeInterval: 0.08)
        NSApp.setActivationPolicy(.accessory)
        restoreFocus(previous, window: window.element, wasMinimized: wasMinimized)
        return logControl("key \(key)", label)
    }

    private static func logControl(_ result: String, _ label: String) -> String {
        logLine("\(label) → \(result)")
        return result
    }

    /// В дереве два узла «таймкод»: тонкая полоска и высокая зона нажатия.
    /// Клик по центру высокой зоны перематывает, по тонкой — нет.
    private static func timecodeFrame(in root: AXUIElement) -> CGRect? {
        var best: CGRect?
        var remaining = 2500
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 30, remaining > 0 else { return }
            remaining -= 1
            AXUIElementSetMessagingTimeout(element, 0.05)
            let description = stringAttribute(element, kAXDescriptionAttribute)
            if description.localizedCaseInsensitiveContains("таймкод"),
               let node = frame(of: element), node.width > 40,
               best == nil || node.height > best!.height {
                best = node
            }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return }
            for child in axElements(value) { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return best
    }

    private static func sendKey(_ code: CGKeyCode, global: Bool) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return }
        if global {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        } else if let pid = application()?.processIdentifier {
            down.postToPid(pid)
            up.postToPid(pid)
        }
    }

    private static func showPlayerWindow(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        application()?.unhide()
        guard let path = application()?.bundleURL?.path else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", path]
        try? process.run()
        process.waitUntilExit()
    }

    private static func yandexWindowOnScreen() -> Bool {
        guard let pid = application()?.processIdentifier else { return false }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.contains { item in
            (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid && windowSize(item).width > 400
        }
    }

    private static func clickPoint(_ axPoint: CGPoint, flip: Bool = true) {
        let height = NSScreen.screens.map(\.frame.maxY).max() ?? axPoint.y
        let point = CGPoint(x: axPoint.x, y: flip ? height - axPoint.y : axPoint.y)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return }
        move.post(tap: .cghidEventTap)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func clickPointMove(_ point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return }
        move.post(tap: .cghidEventTap)
    }

    private static func click(_ frame: CGRect, flipped: Bool) {
        guard frame.width > 1, frame.height > 1 else { return }
        var point = CGPoint(x: frame.midX, y: frame.midY)
        if flipped {
            let height = NSScreen.screens.map(\.frame.maxY).max() ?? point.y
            point.y = height - point.y
        }
        let cursor = CGEvent(source: nil)?.location
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return }
        let pid = application()?.processIdentifier ?? 0
        down.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.05)
        up.postToPid(pid)
        if let cursor, let restore = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: cursor, mouseButton: .left) {
            restore.post(tap: .cghidEventTap)
        }
    }

    /// Слайдер таймкода не принимает AXValue (min=max=0). Полоса реагирует на клик,
    /// когда окно на экране. Громкость — это другой слайдер, её не трогаем.
    static func seek(ratio: Double, duration: TimeInterval = 0) {
        cache = nil
        let clamped = min(1, max(0, ratio))
        guard let window = mainWindow() else {
            logLine("seek → no-window")
            return
        }
        let wasMinimized = isMinimized(window.element)
        let previous = NSWorkspace.shared.frontmostApplication
        showPlayerWindow(window.element)
        guard waitUntilFront() else {
            NSApp.setActivationPolicy(.accessory)
            restoreFocus(previous, window: window.element, wasMinimized: wasMinimized)
            logLine("seek → not-front \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
            return
        }
        guard let app = application() else { return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let spoken = sliderValue(in: root)
        let timing = spokenTiming(spoken)
        let current = timing?.elapsed ?? elapsedOnly(spoken)
        let total = timing?.duration ?? (duration > 1 ? duration : 0)
        guard current >= 0, total > 1 else {
            NSApp.setActivationPolicy(.accessory)
            restoreFocus(previous, window: window.element, wasMinimized: wasMinimized)
            logLine("seek → no-timing [\(spoken)]")
            return
        }
        let target = total * clamped
        let delta = target - current
        // Стрелка вправо/влево сдвигает на ~2 с. Клик по AX-полосе позицию не меняет.
        let presses = min(450, max(0, Int((abs(delta) / 2).rounded())))
        guard presses > 0 else {
            NSApp.setActivationPolicy(.accessory)
            restoreFocus(previous, window: window.element, wasMinimized: wasMinimized)
            logLine("seek → already at \(Int(current))s")
            return
        }
        let key: CGKeyCode = delta > 0 ? 124 : 123
        for _ in 0..<presses {
            sendKey(key, global: true)
            Thread.sleep(forTimeInterval: 0.012)
        }
        NSApp.setActivationPolicy(.accessory)
        restoreFocus(previous, window: window.element, wasMinimized: wasMinimized)
        logLine("seek → \(presses) steps \(Int(current))s → \(Int(target))s / \(Int(total))s")
    }

    private static func findSlider(in root: AXUIElement) -> AXUIElement? {
        var found: AXUIElement?
        var remaining = 2500
        func visit(_ element: AXUIElement, depth: Int) {
            guard found == nil, depth < 30, remaining > 0 else { return }
            remaining -= 1
            AXUIElementSetMessagingTimeout(element, 0.05)
            if stringAttribute(element, kAXRoleAttribute) == (kAXSliderRole as String) {
                found = element
                return
            }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return }
            for child in axElements(value) {
                visit(child, depth: depth + 1)
                if found != nil { return }
            }
        }
        visit(root, depth: 0)
        return found
    }

    private static func application() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
    }

    private static func trusted(prompt: Bool) -> Bool {
        if AXIsProcessTrusted() { return true }
        if prompt, !didPrompt {
            didPrompt = true
            DispatchQueue.main.async {
                askForAccess()
            }
        }
        return false
    }

    private static func askForAccess() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            if AXIsProcessTrusted() {
                NSApp.setActivationPolicy(.accessory)
                return
            }
            let alert = NSAlert()
            alert.messageText = "Atoll не видит текущий трек"
            alert.informativeText = "Яндекс Музыка не отдаёт его системе. Включи Atoll в разделе «Универсальный доступ», и островок покажет то, что играет."
            alert.addButton(withTitle: "Открыть настройки")
            alert.addButton(withTitle: "Позже")
            alert.window.level = .statusBar
            let response = alert.runModal()
            try? "alert=\(response.rawValue) trusted=\(AXIsProcessTrusted())\n".write(
                toFile: DebugLog.path("access.log"),
                atomically: true,
                encoding: .utf8
            )
            if response == .alertFirstButtonReturn {
                let urls = [
                    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                ]
                for raw in urls {
                    guard let url = URL(string: raw) else { continue }
                    if NSWorkspace.shared.open(url) { break }
                }
            }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private struct WindowRef {
        var element: AXUIElement
        var frame: CGRect
    }

    private struct LabeledElement {
        var element: AXUIElement
        var text: String
        var frame: CGRect
    }

    private struct Scan {
        var texts: [LabeledElement] = []
        var buttons: [LabeledElement] = []
        var sliders: [LabeledElement] = []
        var webTitle = ""
    }

    private static func read() -> Track? {
        guard let window = mainWindow() else { return nil }
        // Свёрнутое окно отдаёт урезанное AX-дерево без названия трека, но разворачивать его ради чтения нельзя:
        // при смене трека запись в MediaRemote на миг пропадает, и окно каждый раз выскакивало бы на экран.
        if isMinimized(window.element) { return nil }
        guard let player = findPlayer(in: window.element) else { return nil }
        let info = inspect(player)
        guard !info.title.isEmpty else { return nil }
        let albumID = albumID(in: player)
        let artwork = artwork(for: albumID)
        return Track(
            title: info.title,
            artist: info.artist,
            isPlaying: info.isPlaying,
            elapsed: info.elapsed,
            duration: info.duration,
            artwork: artwork,
            albumID: albumID
        )
    }

    private static var artworkCache: (key: String, image: NSImage?)?
    private static var artworkFetch: String?
    private static let coverSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config)
    }()

    /// Снимок окна без записи экрана пустой. Обложка — публичный og:image альбома, без куков.
    private static func artwork(for albumID: String?) -> NSImage? {
        guard let albumID else { return nil }
        if let cache = artworkCache, cache.key == albumID { return cache.image }
        beginCoverFetch(albumID)
        return nil
    }

    private static func beginCoverFetch(_ albumID: String) {
        guard artworkFetch != albumID else { return }
        artworkFetch = albumID
        DispatchQueue.global(qos: .utility).async {
            let image = downloadCover(albumID: albumID)
            DispatchQueue.main.async {
                artworkCache = (albumID, image)
                if artworkFetch == albumID { artworkFetch = nil }
                cache = nil
            }
        }
    }

    private static func downloadCover(albumID: String) -> NSImage? {
        // Идентификатор достаётся из интерфейса приложения: пускаем только цифры, чтобы он не менял путь запроса.
        guard !albumID.isEmpty, albumID.allSatisfy(\.isNumber),
              let page = URL(string: "https://music.yandex.ru/album/\(albumID)") else { return nil }
        var request = URLRequest(url: page, timeoutInterval: 6)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let gate = DispatchSemaphore(value: 0)
        var htmlData: Data?
        coverSession.dataTask(with: request) { data, _, _ in
            htmlData = data
            gate.signal()
        }.resume()
        _ = gate.wait(timeout: .now() + 6)
        guard let htmlData, let html = String(data: htmlData, encoding: .utf8), let cover = coverURL(in: html) else { return nil }
        var imageData: Data?
        let imageGate = DispatchSemaphore(value: 0)
        coverSession.dataTask(with: cover) { data, _, _ in
            imageData = data
            imageGate.signal()
        }.resume()
        _ = imageGate.wait(timeout: .now() + 6)
        // Обложка заведомо небольшая: огромный ответ не декодируем.
        return imageData.flatMap { $0.count <= 5_000_000 ? NSImage(data: $0) : nil }
    }

    private static func coverURL(in html: String) -> URL? {
        guard let start = html.range(of: "property=\"og:image\" content=\"") else { return nil }
        let rest = html[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let raw = String(rest[..<end])
        // Страница чужая: берём только https-адрес на домене Яндекса.
        func trusted(_ url: URL?) -> URL? {
            guard let url, url.scheme == "https", let host = url.host?.lowercased(),
                  host == "yandex.net" || host.hasSuffix(".yandex.net") || host.hasSuffix(".yandex.ru") else { return nil }
            return url
        }
        if let resized = trusted(URL(string: raw.replacingOccurrences(of: "/m1000x1000", with: "/200x200"))) {
            return resized
        }
        return trusted(URL(string: raw))
    }

    private static func albumID(in root: AXUIElement) -> String? {
        var found: String?
        var remaining = 400
        func visit(_ element: AXUIElement, depth: Int) {
            guard found == nil, depth < 16, remaining > 0 else { return }
            remaining -= 1
            if let id = albumID(from: describe(element, kAXURLAttribute)) {
                found = id
                return
            }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return }
            for child in axElements(value) { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return found
    }

    private static func albumID(from url: String) -> String? {
        guard let range = url.range(of: "albumId=") else { return nil }
        let id = url[range.upperBound...].prefix { $0.isNumber }
        return id.isEmpty ? nil : String(id)
    }

    private static func findPlayer(in window: AXUIElement) -> AXUIElement? {
        var namedPlayer: AXUIElement?
        var transport: AXUIElement?
        var slider: AXUIElement?
        let deadline = Date().addingTimeInterval(1.2)
        var remaining = 5000
        func visit(_ element: AXUIElement, depth: Int) {
            guard namedPlayer == nil, depth < 32, remaining > 0, Date() < deadline else { return }
            remaining -= 1
            AXUIElementSetMessagingTimeout(element, 0.05)
            let description = stringAttribute(element, kAXDescriptionAttribute)
            if description == "Плеер",
               let node = frame(of: element), node.height > 40, node.width > 200 {
                namedPlayer = element
                return
            }
            if transport == nil,
               description.localizedCaseInsensitiveContains("пауз")
                || description.localizedCaseInsensitiveContains("pause")
                || description.localizedCaseInsensitiveContains("воспроиз") {
                transport = element
            }
            if slider == nil, description.localizedCaseInsensitiveContains("таймкод") {
                slider = element
            }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return }
            for child in axElements(value) {
                visit(child, depth: depth + 1)
                if namedPlayer != nil { return }
            }
        }
        visit(window, depth: 0)
        if let namedPlayer { return namedPlayer }
        // В новых сборках нет группы «Плеер» — читаем всё окно, а inspect режет по полосе плеера.
        if slider != nil || transport != nil {
            return window
        }
        return nil
    }

    private static func commonAncestor(_ lhs: AXUIElement, _ rhs: AXUIElement) -> AXUIElement? {
        var leftChain: [AXUIElement] = []
        var current: AXUIElement? = lhs
        for _ in 0..<16 {
            guard let node = current else { break }
            leftChain.append(node)
            current = parent(of: node)
        }
        current = rhs
        for _ in 0..<16 {
            guard let node = current else { break }
            if leftChain.contains(where: { CFEqual($0, node) }) { return node }
            current = parent(of: node)
        }
        return nil
    }

    private static func ancestor(of element: AXUIElement, minWidth: CGFloat, minHeight: CGFloat) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let node = current else { return nil }
            if let frame = frame(of: node), frame.width >= minWidth, frame.height >= minHeight {
                return node
            }
            current = parent(of: node)
        }
        return nil
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func inspect(_ player: AXUIElement) -> (title: String, artist: String, isPlaying: Bool, elapsed: TimeInterval, duration: TimeInterval) {
        var title = ""
        var artist = ""
        var albumName = ""
        var playing = false
        var elapsed: TimeInterval = 0
        var duration: TimeInterval = 0
        var clocks: [(seconds: TimeInterval, x: CGFloat, y: CGFloat)] = []
        var sliderY: CGFloat = 0
        var remaining = 2500
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 28, remaining > 0 else { return }
            remaining -= 1
            AXUIElementSetMessagingTimeout(element, 0.05)
            let description = stringAttribute(element, kAXDescriptionAttribute)
            let value = describe(element, kAXValueAttribute)
            let node = frame(of: element) ?? .zero
            if isPause(description) { playing = true }
            if description.hasPrefix("Трек ") {
                title = String(description.dropFirst("Трек ".count)).trimmingCharacters(in: .whitespaces)
            } else if description.hasPrefix("Артист ") {
                artist = String(description.dropFirst("Артист ".count)).trimmingCharacters(in: .whitespaces)
            } else if description.hasPrefix("Альбом "), node.width > 40, node.height > 40 {
                albumName = String(description.dropFirst("Альбом ".count))
            }
            if description.localizedCaseInsensitiveContains("таймкод") {
                sliderY = node.midY
                let spoken = value.isEmpty ? describe(element, kAXValueDescriptionAttribute) : value
                if let timing = spokenTiming(spoken) {
                    elapsed = timing.elapsed
                    duration = timing.duration
                } else if let only = spokenDuration(spoken) {
                    elapsed = only
                }
            }
            if let seconds = spokenDuration(description), node.width > 20, node.height > 10, node.width < 120 {
                clocks.append((seconds, node.minX, node.midY))
            }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success else { return }
            for child in axElements(children) {
                visit(child, depth: depth + 1)
            }
        }
        visit(player, depth: 0)
        // Слева — прошедшее. Справа в актуальном UI — полная длина трека.
        let nearClocks = clocks.filter { sliderY == 0 || abs($0.y - sliderY) < 80 }.sorted { $0.x < $1.x }
        if nearClocks.count >= 2 {
            let left = nearClocks[0].seconds
            let right = nearClocks[1].seconds
            elapsed = left
            duration = right >= left ? right : left + right
        } else if duration < 1, let only = nearClocks.first {
            elapsed = only.seconds
        }
        if artist.isEmpty { artist = albumName }
        return (title, artist, playing, elapsed, duration)
    }

    private static func looksLikeArtistLine(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.hasSuffix("—") || trimmed.hasSuffix("–") || trimmed.hasSuffix("-")
    }

    private static func stripArtistLine(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: " —–-").union(.whitespaces))
    }

    private static func elapsedOnly(_ raw: String) -> TimeInterval {
        let head = raw.components(separatedBy: "/").first ?? raw
        return spokenDuration(head) ?? -1
    }

    private static func spokenTiming(_ raw: String) -> (elapsed: TimeInterval, duration: TimeInterval)? {
        let parts = raw.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2, let elapsed = spokenDuration(parts[0]), let duration = spokenDuration(parts[1]) else { return nil }
        return (elapsed, duration)
    }

    private static func spokenDuration(_ raw: String) -> TimeInterval? {
        let pattern = #"(\d+)\s*(час\w*|минут\w*|секунд\w*)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let matches = expression.matches(in: raw, range: range)
        guard !matches.isEmpty else { return nil }
        var total: TimeInterval = 0
        for match in matches {
            guard let numberRange = Range(match.range(at: 1), in: raw),
                  let unitRange = Range(match.range(at: 2), in: raw),
                  let number = Double(raw[numberRange]) else { continue }
            let unit = raw[unitRange]
            if unit.hasPrefix("час") {
                total += number * 3600
            } else if unit.hasPrefix("минут") {
                total += number * 60
            } else {
                total += number
            }
        }
        return total
    }

    private static func mainWindow() -> WindowRef? {
        guard let app = application() else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success else { return nil }
        let windows = axElements(value)
        let match = windows
            .compactMap { item -> WindowRef? in
                guard let nodeFrame = frame(of: item), nodeFrame.width > 200 else { return nil }
                return WindowRef(element: item, frame: nodeFrame)
            }
            .max { $0.frame.width < $1.frame.width }
        return match
    }

    private static func scan(window: AXUIElement, frame windowFrame: CGRect) -> Scan {
        var found = Scan()
        let deadline = Date().addingTimeInterval(0.28)
        let bandTop = windowFrame.maxY - 170
        var remaining = 900

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 14, remaining > 0, Date() < deadline else { return }
            remaining -= 1
            AXUIElementSetMessagingTimeout(element, 0.08)
            let nodeFrame = frame(of: element)
            if depth > 0, let nodeFrame, nodeFrame.maxY < bandTop, nodeFrame.height < windowFrame.height * 0.45 {
                return
            }
            let role = stringAttribute(element, kAXRoleAttribute)
            if role == (kAXStaticTextRole as String), let nodeFrame {
                let text = stringAttribute(element, kAXValueAttribute).ifEmpty(stringAttribute(element, kAXTitleAttribute))
                if !text.isEmpty {
                    found.texts.append(LabeledElement(element: element, text: text, frame: nodeFrame))
                }
            } else if role == (kAXButtonRole as String) {
                let text = [
                    stringAttribute(element, kAXTitleAttribute),
                    stringAttribute(element, kAXDescriptionAttribute),
                    stringAttribute(element, kAXHelpAttribute),
                ].filter { !$0.isEmpty }.joined(separator: " ")
                if !text.isEmpty {
                    found.buttons.append(LabeledElement(element: element, text: text, frame: nodeFrame ?? .zero))
                }
            } else if role == (kAXSliderRole as String), let nodeFrame, nodeFrame.maxY > bandTop {
                found.sliders.append(LabeledElement(element: element, text: "", frame: nodeFrame))
            } else if role == "AXWebArea", found.webTitle.isEmpty {
                found.webTitle = stringAttribute(element, kAXTitleAttribute)
            }

            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return }
            let children = axElements(value).sorted { lhs, rhs in
                (frame(of: lhs)?.maxY ?? 0) > (frame(of: rhs)?.maxY ?? 0)
            }
            for child in children {
                visit(child, depth: depth + 1)
            }
        }

        visit(window, depth: 0)
        return found
    }

    private static func timing(in found: Scan, frame windowFrame: CGRect) -> (elapsed: TimeInterval, duration: TimeInterval) {
        let bandTop = windowFrame.maxY - 170
        let clocks = found.texts
            .filter { $0.frame.maxY > bandTop }
            .compactMap { clock($0.text) }
        guard let first = clocks.first else { return (0, 0) }
        let elapsed = max(0, first)
        if clocks.count >= 2 {
            let second = clocks[1]
            if second < 0 {
                return (elapsed, elapsed + abs(second))
            }
            if second > elapsed {
                return (elapsed, second)
            }
        }
        return (elapsed, 0)
    }

    private static func clock(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let negative = trimmed.hasPrefix("-") || trimmed.hasPrefix("−")
        let body = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "-−"))
        let parts = body.split(separator: ":")
        guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]), seconds < 60 else { return nil }
        let value = minutes * 60 + seconds
        return negative ? -value : value
    }

    private static func isPause(_ text: String) -> Bool {
        let value = text.lowercased()
        return value.contains("пауз") || value.contains("pause")
    }

    private static func axElements(_ value: CFTypeRef?) -> [AXUIElement] {
        (value as? [AXUIElement]) ?? []
    }

    private static func numberAttribute(_ element: AXUIElement, _ attribute: String) -> Double? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.doubleValue
    }

    private static func note(_ track: Track) {
        let line = "\(track.title) | \(track.artist) | playing=\(track.isPlaying)"
        guard line != logged else { return }
        logged = line
        try? (line + "\n").write(toFile: DebugLog.path("ax.log"), atomically: true, encoding: .utf8)
    }

    private static func noteMiss(windowTitle: String, scan: Scan) {
        let line = "miss title=\(windowTitle) web=\(scan.webTitle) texts=\(scan.texts.prefix(6).map(\.text).joined(separator: " / "))"
        guard line != logged else { return }
        logged = line
        try? (line + "\n").write(toFile: DebugLog.path("ax.log"), atomically: true, encoding: .utf8)
    }

    private static func parseTitle(_ raw: String) -> (title: String, artist: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAppName(trimmed) else { return nil }
        let separators = [" — ", " – ", " - "]
        for separator in separators {
            let parts = trimmed.components(separatedBy: separator).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !isAppName($0) }
            if parts.count >= 2 {
                return (parts[0], parts[1])
            }
        }
        return nil
    }

    private static func isNoise(_ text: String) -> Bool {
        if isAppName(text) { return true }
        if text.count > 80 { return true }
        let blocked = ["плеер", "поиск", "коллекция", "концерты", "книги", "подкасты", "моя волна", "для вас", "тренды", "плюс"]
        if blocked.contains(text.lowercased()) { return true }
        return text.range(of: #"^-?\d+:\d{2}$"#, options: .regularExpression) != nil
    }

    private static func isAppName(_ text: String) -> Bool {
        let value = text.lowercased()
        return value.contains("яндекс") && value.contains("узык")
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
