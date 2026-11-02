import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Menu bar

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let settings: Settings
    private let island: IslandController
    private let services: Services
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let cityPrompt = TextPrompt()
    private let slackPrompt = TextPrompt()
    private lazy var editor: PrompterEditor = {
        let editor = PrompterEditor(prompter: services.prompter, settings: settings)
        editor.applyLayout = { [unowned self] change in island.changePrompterLayout(change) }
        return editor
    }()
    var onMusicSettingsChanged: () -> Void = {}
    var peeks: PeekSources?
    var onClaudeSettingsChanged: () -> Void = {}

    init(settings: Settings, island: IslandController, services: Services) {
        self.settings = settings
        self.island = island
        self.services = services
        super.init()
        item.button?.image = Self.icon()
        item.button?.toolTip = "Custom Notch"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Teleprompter: opens the script window (paste, then Start); while it runs, this stops it.
        let prompter = services.prompter
        menu.addItem(prompter.isActive
            ? action("Stop Teleprompter") { prompter.stop() }
            : action("Teleprompter…") { [unowned self] in editScript() })
        menu.addItem(.separator())

        // Tiles: show/hide, size and order.
        let tilesItem = NSMenuItem(title: "Tiles", action: nil, keyEquivalent: "")
        let tilesMenu = NSMenu()
        let tiles = settings.tiles
        for tile in tiles {
            let entry = NSMenuItem(title: tile.kind.title, action: nil, keyEquivalent: "")
            entry.state = tile.visible ? .on : .off
            let options = NSMenu()
            options.autoenablesItems = false     // so the disabled Move items stay disabled
            options.addItem(action(tile.visible ? "Hide" : "Show") { [unowned self] in
                island.apply(tiles: settings.tiles.setting(tile.kind, visible: !tile.visible))
            })
            options.addItem(.separator())
            for cells in 1...3 {
                let size = action(cells == 1 ? "1 Cell" : "\(cells) Cells") { [unowned self] in
                    island.apply(tiles: settings.tiles.setting(tile.kind, cells: cells))
                }
                size.state = tile.cells == cells ? .on : .off
                options.addItem(size)
            }
            options.addItem(.separator())
            let left = action("Move Left") { [unowned self] in island.apply(tiles: settings.tiles.moving(tile.kind, by: -1)) }
            left.isEnabled = tile.visible && tiles.canMove(tile.kind, by: -1)
            options.addItem(left)
            let right = action("Move Right") { [unowned self] in island.apply(tiles: settings.tiles.moving(tile.kind, by: 1)) }
            right.isEnabled = tile.visible && tiles.canMove(tile.kind, by: 1)
            options.addItem(right)
            entry.submenu = options
            tilesMenu.addItem(entry)
        }
        tilesMenu.autoenablesItems = false
        tilesItem.submenu = tilesMenu
        menu.addItem(tilesItem)

        let city = settings.weatherLocation.map { "Weather City: \($0.name)…" } ?? "Weather City…"
        menu.addItem(action(city) { [unowned self] in chooseCity() })

        let musicItem = NSMenuItem(title: "Music", action: nil, keyEquivalent: "")
        let musicMenu = NSMenu()
        let inNotch = action("Show Music in the Notch") { [unowned self] in
            settings.musicInNotch.toggle()
            onMusicSettingsChanged()
        }
        inNotch.state = settings.musicInNotch ? .on : .off
        let lyrics = action("Synced Lyrics (lrclib.net)") { [unowned self] in
            settings.lyricsEnabled.toggle()
            onMusicSettingsChanged()
        }
        lyrics.state = settings.lyricsEnabled ? .on : .off
        let covers = action("Load Spotify Covers (i.scdn.co)") { [unowned self] in
            settings.spotifyCovers.toggle()
            onMusicSettingsChanged()
        }
        covers.state = settings.spotifyCovers ? .on : .off
        [inNotch, lyrics, covers].forEach(musicMenu.addItem)
        musicItem.submenu = musicMenu
        menu.addItem(musicItem)
        menu.addItem(cardsItem())
        menu.addItem(peeksItem())
        menu.addItem(claudeItem())
        menu.addItem(chessItem())
        menu.addItem(.separator())

        let theme = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themes = NSMenu()
        for name in ThemeName.allCases {
            let entry = NSMenuItem(title: name.title, action: #selector(chooseTheme(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = name.rawValue
            entry.state = settings.theme == name ? .on : .off
            themes.addItem(entry)
        }
        theme.submenu = themes
        menu.addItem(theme)

        // Preview is a testing aid: it appears only while ⌥ is held when the menu opens.
        let showPreview = NSEvent.modifierFlags.contains(.option)
        let preview = NSMenuItem(title: "Preview", action: nil, keyEquivalent: "")
        let previews = NSMenu()
        for (title, key) in [("Compact", "compact"), ("Peek", "peek"),
                             ("Peek: Battery 20%", "peek-20"), ("Peek: Battery 10%", "peek-10"),
                             ("Peek: Focus", "peek-focus"), ("Expanded", "expanded"), ("Resting", "resting")] {
            let entry = NSMenuItem(title: title, action: #selector(choosePreview(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = key
            previews.addItem(entry)
        }
        preview.submenu = previews
        if showPreview { menu.addItem(preview) }

        menu.addItem(.separator())
        menu.addItem(loginItem())
        let quit = NSMenuItem(title: "Quit Custom Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// Launch at Login (off until you turn it on). macOS lists the app in Settings → General → Login Items.
    private func loginItem() -> NSMenuItem {
        let service = SMAppService.mainApp
        switch service.status {
        case .requiresApproval:
            return action("Launch at Login: Approve in System Settings…") {
                SMAppService.openSystemSettingsLoginItems()
            }
        default:
            let item = action("Launch at Login") { [unowned self] in
                do {
                    if service.status == .enabled {
                        try service.unregister()
                    } else {
                        try service.register()
                        switch service.status {
                        case .enabled: break
                        case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
                        // No error, but macOS didn't take it either (seen with ad-hoc signatures).
                        default: showLoginProblem("macOS didn't register the app")
                        }
                    }
                } catch {
                    showLoginProblem(error.localizedDescription)
                }
            }
            item.state = service.status == .enabled ? .on : .off
            return item
        }
    }

    /// If macOS refuses, offer the closest thing: adding the app to Login Items by hand. The button opens
    /// Login Items and shows Custom Notch.app selected in the Finder, ready to drag into the list.
    private func showLoginProblem(_ reason: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Couldn't turn on Launch at Login"
        alert.informativeText = "\(reason). This usually happens with the ad-hoc signature.\n\n"
            + "Add it yourself: drag Custom Notch.app from the Finder window into the \"Open at Login\" list in System Settings."
        alert.addButton(withTitle: "Show App and Login Items")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SMAppService.openSystemSettingsLoginItems()
        // Finder last, so its window (with the app selected) ends up in front of System Settings.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
    }

    /// Claude Code: what shows in the notch, and the hook lines for ~/.claude/settings.json.
    private func claudeItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Claude Code", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let status = action("Show Claude Code in the Notch") { [unowned self] in
            settings.claudeInNotch.toggle()
            onClaudeSettingsChanged()
        }
        status.state = settings.claudeInNotch ? .on : .off
        let approvals = action("Allow or Deny from the Notch (⌃⌥Y / ⌃⌥N)") { [unowned self] in
            settings.claudeApprovals.toggle()
        }
        approvals.state = settings.claudeApprovals ? .on : .off
        let connected = ClaudeBridge.isConnected
        let connect = action(connected ? "Connected to Claude Code" : "Connect Claude Code…") { [unowned self] in
            connectClaude()
        }
        connect.state = connected ? .on : .off
        connect.isEnabled = !connected
        let copy = action("Copy Hook Settings for ~/.claude/settings.json") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ClaudeBridge.settingsSnippet, forType: .string)
        }
        let copyStatusLine = action("Copy Status Line Setting (Claude limit in the cards)") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ClaudeBridge.statusLineSnippet, forType: .string)
        }
        submenu.autoenablesItems = false
        [connect, .separator(), status, approvals, .separator(), copy, copyStatusLine].forEach(submenu.addItem)
        item.submenu = submenu
        return item
    }

    /// Chess against Claude: open the board, start a new game, choose the model that plays.
    private func chessItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Chess", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let chess = services.chess
        submenu.addItem(action("Open Board") { [unowned self] in services.openChess() })
        submenu.addItem(action("New Game as White") { [unowned self] in
            chess.newGame(as: .white)
            services.openChess()
        })
        submenu.addItem(action("New Game as Black") { [unowned self] in
            chess.newGame(as: .black)
            services.openChess()
        })
        submenu.addItem(.separator())
        let heading = NSMenuItem(title: "Opponent (uses your Claude Code login)", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        submenu.addItem(heading)
        for opponent in ChessOpponent.allCases {
            let entry = action(opponent.menuTitle) { [unowned self] in settings.chessOpponent = opponent }
            entry.state = settings.chessOpponent == opponent ? .on : .off
            submenu.addItem(entry)
        }
        submenu.autoenablesItems = false
        item.submenu = submenu
        return item
    }

    /// The swipeable cards: AirPods over Bluetooth, and the Slack connection.
    private func cardsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Cards", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let airpods = action("Show AirPods Batteries (uses Bluetooth)") { [unowned self] in
            settings.airpodsBatteries ? services.batteries.disableBluetooth() : services.batteries.enableBluetooth()
        }
        airpods.state = settings.airpodsBatteries ? .on : .off
        let slack = services.slack
        let slackItem = slack.state == .notConnected
            ? action("Connect Slack…") { [unowned self] in connectSlack() }
            : action("Disconnect Slack\(slack.team.map { " (\($0))" } ?? "")") { slack.disconnect() }
        [airpods, slackItem].forEach(submenu.addItem)
        item.submenu = submenu
        return item
    }

    /// Peeks: one switch per kind. Focus needs its permission first, and says so when it's missing.
    private func peeksItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Peeks", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let toggles: [(String, ReferenceWritableKeyPath<Settings, Bool>)] = [
            ("Charger Connected", \.peekCharger),
            ("Battery at 20% and 10%", \.peekBattery)]
        for (title, key) in toggles {
            let entry = action(title) { [unowned self] in settings[keyPath: key].toggle() }
            entry.state = settings[keyPath: key] ? .on : .off
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        switch peeks?.focusAccess {
        case .granted:
            let focus = action("Do Not Disturb and Other Focus") { [unowned self] in
                settings.peekFocus.toggle()
                peeks?.updateFocusMonitoring()
            }
            focus.state = settings.peekFocus ? .on : .off
            submenu.addItem(focus)
        case .notAsked:
            submenu.addItem(action("Do Not Disturb… (asks for the Focus permission)") { [unowned self] in
                peeks?.requestFocusAccess {}
            })
        default:
            let off = NSMenuItem(title: "Do Not Disturb: Focus permission not granted", action: nil, keyEquivalent: "")
            off.isEnabled = false
            submenu.addItem(off)
            submenu.addItem(action("Open Focus Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")!)
            })
        }
        item.submenu = submenu
        return item
    }

    /// A menu item that runs a closure.
    private func action(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: #selector(ClosureMenuItem.fire), keyEquivalent: "")
        item.target = item
        item.handler = handler
        return item
    }

    /// The teleprompter's script window: paste or type, choose size and width, then Start.
    func editScript() {
        editor.show()
    }

    /// Asks for the Slack token, checks it with Slack, and keeps it in the keychain.
    func connectSlack() {
        let slack = services.slack
        slackPrompt.show(.slack, current: nil, onSave: { [unowned self] token in
            Task { @MainActor in
                if let problem = await slack.connect(token: token) {
                    slackPrompt.showError(problem)
                } else {
                    slackPrompt.close()
                }
            }
        }, onRemove: slack.state == .notConnected ? nil : { [unowned self] in
            slack.disconnect()
            slackPrompt.close()
        })
    }

    /// Adds the notch's hooks and status line to ~/.claude/settings.json, after asking.
    func connectClaude() {
        guard !ClaudeBridge.isConnected else { return }
        NSApp.activate()
        let ask = NSAlert()
        ask.messageText = "Connect Claude Code to the notch?"
        ask.informativeText = """
            Custom Notch adds its hooks and status line to ~/.claude/settings.json. Your other settings and hooks \
            stay as they are, and a backup is saved next to the file.

            Then the notch shows what Claude Code is doing, lets you allow or deny its requests, and shows your \
            plan limits. New Claude Code sessions pick this up.
            """
        ask.addButton(withTitle: "Connect")
        ask.addButton(withTitle: "Cancel")
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        let done = NSAlert()
        do {
            let connection = try ClaudeBridge.connect()
            done.messageText = "Claude Code is connected"
            done.informativeText = connection.addedStatusLine
                ? "Start a new Claude Code session to see it in the notch. The Claude limit card fills in after its first reply."
                : "Start a new Claude Code session to see it in the notch. You already have a status line, so it was kept; for the Claude limit card, use Copy Status Line Setting."
        } catch {
            done.alertStyle = .warning
            done.messageText = "Couldn't connect Claude Code"
            done.informativeText = error.localizedDescription
        }
        done.runModal()
    }

    /// Asks for the weather city and looks it up with Open-Meteo.
    func chooseCity() {
        let hasCity = settings.weatherLocation != nil
        cityPrompt.show(.city, current: settings.weatherLocation?.name, onSave: { [unowned self] name in
            Task { @MainActor in
                do {
                    guard let location = try await services.weather.geocode(name) else {
                        return cityPrompt.showError("Couldn't find a city called “\(name)”.")
                    }
                    settings.weatherLocation = location
                    cityPrompt.close()
                    await services.weather.refresh()
                } catch {
                    cityPrompt.showError("Couldn't reach Open-Meteo. Check your connection and try again.")
                }
            }
        }, onRemove: hasCity ? { [unowned self] in
            settings.weatherLocation = nil
            cityPrompt.close()
            Task { await services.weather.refresh() }
        } : nil)
    }

    @objc private func chooseTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let theme = ThemeName(rawValue: raw) else { return }
        withAnimation(.easeInOut(duration: 0.25)) { settings.theme = theme }
    }

    @objc private func choosePreview(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        preview(key)
    }

    func preview(_ key: String) {
        switch key {
        case "compact":
            island.setCompact(CompactContent(leading: .symbol("sparkle"), trailing: .activity))
        case "peek":
            island.showPeek(PeekContent(symbol: "bolt.fill", title: "Charging", subtitle: "Battery 76%"))
        case "peek-20":
            island.showPeek(PeekContent(symbol: "battery.25", title: "Battery 20%", subtitle: "Low battery",
                                        tint: .warning, duration: 4))
        case "peek-10":
            island.showPeek(PeekContent(symbol: "battery.0", title: "Battery 10%", subtitle: "Connect the charger soon",
                                        tint: .critical, duration: 4))
        case "peek-focus":
            island.showPeek(PeekContent(symbol: "moon.fill", title: "Focus On", subtitle: "Notifications are silenced",
                                        duration: 3))
        case "expanded":
            island.expandPinned()
        case "city":
            chooseCity()
        case "script":
            editScript()
        case "prompter":
            // Testing aid: starts with the sample script when there is none yet.
            if Teleprompter.words(in: services.prompter.script).isEmpty { services.prompter.script = Teleprompter.sampleScript }
            services.prompter.start()
        case "chess":
            services.openChess()
        default:
            island.setCompact(nil)
            island.collapse()
        }
    }

    /// Template icon: a screen outline with a small notch.
    private static func icon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 14), flipped: false) { _ in
            let body = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 15, height: 11), xRadius: 2.5, yRadius: 2.5)
            body.lineWidth = 1.3
            NSColor.black.setStroke()
            body.stroke()
            let notch = NSBezierPath(roundedRect: NSRect(x: 6, y: 9.5, width: 6, height: 3), xRadius: 1.2, yRadius: 1.2)
            NSColor.black.setFill()
            notch.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// A small floating panel for typing one value (the weather city, the Slack token). It takes keyboard input
/// without activating the app (like Spotlight), so typing works whichever app is in front.
@MainActor
final class TextPrompt: NSObject {
    struct Config {
        var title: String
        var hint: String
        var placeholder: String
        var secure = false
        var removeTitle = "Remove"
        var busy: (String) -> String = { _ in "Checking…" }

        static let city = Config(title: "Weather City", hint: "Only the city name is sent to Open-Meteo to find it.",
                                 placeholder: "For example, Lisbon", removeTitle: "Remove City",
                                 busy: { "Looking up “\($0)”…" })
        static let slack = Config(title: "Connect Slack",
                                  hint: "Paste your Slack user token (xoxp-…, scopes search:read and users:read). "
                                      + "It stays in your keychain; only slack.com sees it.",
                                  placeholder: "xoxp-…", secure: true, removeTitle: "Disconnect",
                                  busy: { _ in "Checking the token with Slack…" })
    }

    private var panel: KeyPanel?
    private var field = NSTextField()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var config = Config.city
    private var onSave: (String) -> Void = { _ in }
    private var onRemove: (() -> Void)?

    func show(_ config: Config, current: String?, onSave: @escaping (String) -> Void, onRemove: (() -> Void)?) {
        self.config = config
        self.onSave = onSave
        self.onRemove = onRemove
        panel?.close()
        field = config.secure ? NSSecureTextField() : NSTextField()

        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 130),
                             styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = config.title
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        field.stringValue = current ?? ""
        field.placeholderString = config.placeholder
        resetMessage()

        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        var buttons: [NSView] = []
        if onRemove != nil { buttons.append(NSButton(title: config.removeTitle, target: self, action: #selector(removeClicked))) }
        buttons += [NSView(), cancel, save]
        let row = NSStackView(views: buttons)
        row.distribution = .fill

        let stack = NSStackView(views: [field, message, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        for view in [field, message, row] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        panel.contentView = stack

        // Under the notch, on the notch screen.
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - 160, y: frame.maxY - 190))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        self.panel = panel
    }

    func showError(_ text: String) {
        message.stringValue = text
        message.textColor = NSColor(srgbRed: 0.74, green: 0.45, blue: 0.22, alpha: 1)   // muted orange
    }

    func close() { panel?.close() }

    private func resetMessage() {
        message.stringValue = config.hint
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 11)
    }

    @objc private func saveClicked() {
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        resetMessage()
        message.stringValue = config.busy(name)
        onSave(name)
    }

    @objc private func cancelClicked() { close() }
    @objc private func removeClicked() { onRemove?() }
}

/// A panel that takes typing without activating the app (the prompts and the teleprompter script).
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }

    /// A menu-bar app has no Edit menu, and macOS routes ⌘V/⌘C/⌘X/⌘A/⌘Z through that menu, so without
    /// this, pasting into the field would do nothing.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command || flags == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let action: Selector?
        switch (key, flags == .command) {
        case ("v", true): action = #selector(NSText.paste(_:))
        case ("c", true): action = #selector(NSText.copy(_:))
        case ("x", true): action = #selector(NSText.cut(_:))
        case ("a", true): action = #selector(NSText.selectAll(_:))
        case ("z", true): action = Selector(("undo:"))
        case ("z", false): action = Selector(("redo:"))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class ClosureMenuItem: NSMenuItem {
    var handler: () -> Void = {}
    @objc func fire() { handler() }
}
