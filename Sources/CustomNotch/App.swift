import AppKit
import SwiftUI

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)     // menu bar only, no Dock icon
        app.run()
    }
}

/// The data sources behind the tiles.
@MainActor
final class Services {
    let weather: WeatherService
    let controls: SystemControls
    let music: MusicService
    let batteries: BatteryService
    let slack: SlackService
    let calendar: CalendarService
    let timer: FocusTimer
    let claude: ClaudeBridge
    let prompter: Teleprompter
    let chess: ChessGame
    var openChess: () -> Void = {}
    /// The teleprompter button: opens the script window, or stops a running teleprompter.
    var openPrompter: () -> Void = {}
    var chooseCity: () -> Void = {}
    var connectSlack: () -> Void = {}

    init(weather: WeatherService, controls: SystemControls, music: MusicService,
         batteries: BatteryService, slack: SlackService, calendar: CalendarService, timer: FocusTimer,
         claude: ClaudeBridge, prompter: Teleprompter? = nil, chess: ChessGame? = nil) {
        self.claude = claude
        self.chess = chess ?? ChessGame(settings: .shared)
        self.prompter = prompter ?? Teleprompter(settings: .shared)
        self.weather = weather
        self.controls = controls
        self.music = music
        self.batteries = batteries
        self.slack = slack
        self.calendar = calendar
        self.timer = timer
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var island: IslandController!
    private var menu: StatusMenu!
    private var services: Services!
    private var peeks: PeekSources!
    private var appearance: AppearanceWatcher!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Developer aids (-snapshot, -lyrics, …) run and quit here; see DevTools.swift.
        if DevTools.handleLaunchArguments() { return }

        let settings = Settings.shared
        // Automatic theme: dark tiles in dark mode, light tiles in light mode, switching live.
        appearance = AppearanceWatcher(settings: settings)

        services = Services(weather: WeatherService(settings: settings), controls: SystemControls(),
                            music: MusicService(settings: settings), batteries: BatteryService(), slack: SlackService(),
                            calendar: CalendarService(), timer: FocusTimer(), claude: ClaudeBridge(settings: settings))
        island = IslandController(settings: settings, services: services)
        menu = StatusMenu(settings: settings, island: island, services: services)

        island.onExpand = { [services, settings, appearance] in
            appearance?.check()             // in case a switch went unnoticed
            guard let services else { return }
            let visible = Set(settings.tiles.filter(\.visible).map(\.kind))
            if visible.contains(.weather) { services.weather.refreshIfStale() }
            if visible.contains(.controls) { services.controls.refresh() }
            if visible.contains(.music) { services.music.islandOpened() }
            if visible.contains(.cards) {
                services.calendar.refresh()
                services.batteries.islandOpened()
                services.slack.refreshIfStale()
            } else if visible.contains(.calendar) {
                services.calendar.refresh()
            }
        }
        island.onCollapse = { [services] in
            services?.music.islandClosed()
            services?.batteries.islandClosed()
        }
        services.music.onChange = { [weak self] in self?.updateCompact() }
        // The music tile only shows while Spotify or Music is open.
        let updateMusicTile = { [weak island, weak music = services.music] in
            guard let island, let music else { return }
            island.setUnavailable(music.runningPlayers.isEmpty ? [.music] : [])
        }
        services.music.onPlayersChange = updateMusicTile
        updateMusicTile()
        menu.onMusicSettingsChanged = { [weak self] in
            self?.services.music.settingsChanged()
            self?.updateCompact()
        }
        services.controls.onOpenedApp = { [weak island] in island?.collapse() }
        services.controls.onDarkModeSwitched = { [appearance] in appearance?.checkSoon() }
        services.timer.onFinish = { [weak island] in
            NSSound(named: "Glass")?.play()
            island?.showPeek(PeekContent(symbol: "timer", title: "Focus session done",
                                         subtitle: "25 minutes. Time for a break.", duration: 4))
        }
        services.chooseCity = { [weak menu] in menu?.chooseCity() }
        services.connectSlack = { [weak menu] in menu?.connectSlack() }
        services.slack.onOpenedApp = { [weak island] in island?.collapse() }
        services.weather.refreshIfStale()

        let claude = services.claude
        claude.onActivityChange = { [weak self] in self?.updateCompact() }
        claude.onRequestsChange = { [weak island] in island?.claudeRequestsChanged() }
        claude.showPeek = { [weak island] peek in island?.showPeek(peek) }
        claude.start()
        menu.onClaudeSettingsChanged = { [weak self] in self?.updateCompact() }

        // The teleprompter: while it is out, Claude's requests go to the terminal and peeks wait.
        let prompter = services.prompter
        prompter.onShow = { [weak self] in
            self?.services.claude.pauseApprovals(true)
            self?.island.showPrompter()
        }
        prompter.onHide = { [weak self] in
            self?.services.claude.pauseApprovals(false)
            self?.island.hidePrompter()
        }
        prompter.onNeedsScript = { [weak menu] in menu?.editScript() }
        services.openPrompter = { [weak self] in
            guard let self else { return }
            if prompter.isActive {
                prompter.stop()
            } else {
                island.collapse()
                menu.editScript()
            }
        }

        // Chess against Claude: the board opens from its Quick Controls button or the menu. When Claude moves while the board
        // is closed, a bubble says so.
        services.openChess = { [weak self] in
            guard let self else { return }
            island.showChess()
            services.chess.resume()
        }
        services.chess.onClaudeMoved = { [weak self] san in
            guard let self, island.model.state != .chess else { return }
            let game = services.chess
            island.showPeek(PeekContent(symbol: "checkerboard.rectangle", title: "Claude played \(san)",
                                        subtitle: game.outcome?.text(player: game.player) ?? "Your move",
                                        group: "chess"))
        }

        peeks = PeekSources(settings: settings) { [weak island] peek in island?.showPeek(peek) }
        peeks.start()
        menu.peeks = peeks

        // Development aid: `open -a "Custom Notch" --args -preview expanded|compact|peek`
        if let preview = UserDefaults.standard.string(forKey: "preview") {
            menu.preview(preview)
        }
    }

    /// The black pill: Claude Code's current step while it works, otherwise the music (if turned on).
    private func updateCompact() {
        let music = services.music
        let claude = services.claude
        if Settings.shared.claudeInNotch, claude.working {
            island.setCompact(CompactContent(leading: .symbol(claude.step.symbol), trailing: .activity))
        } else if Settings.shared.musicInNotch, music.isPlaying, music.track != nil {
            island.setCompact(CompactContent(leading: .artwork(music.artwork), trailing: .equalizer))
        } else {
            island.setCompact(nil)
        }
    }
}

/// Keeps `Settings.systemDark` in step with macOS. The app's own appearance is the one source of truth;
/// it is read when it changes (KVO), after the system-wide "theme changed" notification and the dark-mode
/// button (the app's appearance can trail those a moment), and whenever the island opens.
@MainActor
final class AppearanceWatcher {
    private let settings: Settings
    private var observation: NSKeyValueObservation?
    private var themeObserver: NSObjectProtocol?

    init(settings: Settings) {
        self.settings = settings
        settings.systemDark = Self.systemIsDark
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.check() }
        }
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSoon() }
        }
    }

    static var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    func check() {
        let dark = Self.systemIsDark
        guard settings.systemDark != dark else { return }
        withAnimation(.easeInOut(duration: 0.3)) { settings.systemDark = dark }
    }

    /// Now and twice more shortly after, for when macOS has switched but the app's appearance hasn't yet.
    func checkSoon() {
        check()
        for delay in [0.4, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.check() }
        }
    }
}
