import SwiftUI
import AppKit
import AudioToolbox
import CoreAudio
@preconcurrency import CoreWLAN

/// Wi-Fi, AirDrop, dark mode, volume and brightness; Amphetamine and Raycast, if installed.
/// Nothing is monitored in the background: states are read when the island opens and after each action.
@MainActor @Observable
final class SystemControls {
    /// Who can see this Mac in AirDrop. The raw values are what sharingd stores in `DiscoverableMode`.
    enum AirDropMode: String, CaseIterable, Equatable, Sendable {
        case off = "Off", contactsOnly = "Contacts Only", everyone = "Everyone"

        /// The labels Control Center uses.
        var title: String { rawValue }
        var shortTitle: String {
            switch self {
            case .off: "Off"
            case .contactsOnly: "Contacts"
            case .everyone: "Everyone"
            }
        }
    }

    private(set) var wifiOn = false
    private(set) var wifiBars = 0               // 0...5, from signal strength
    private(set) var wifiAvailable = true
    private(set) var airDrop: AirDropMode = .off
    private(set) var darkMode = false
    private(set) var volume: Double = 0
    private(set) var muted = false
    private(set) var brightness: Double = 0
    private(set) var brightnessAvailable = false
    /// A short explanation shown inside the tile for a few seconds (e.g. a missing permission).
    private(set) var notice: TileNotice?
    /// The volume and brightness sliders, shown in place of the buttons.
    var showingSliders = false
    /// The AirDrop choices (Off, Contacts Only, Everyone), shown in place of the buttons.
    var showingAirDrop = false
    /// Amphetamine's session as last read (or as just set from here).
    private(set) var amphetamine = AmphetamineSession()
    /// Amphetamine's choices (start or end, how long, display sleep), shown in place of the buttons.
    var showingAmphetamine = false

    /// Called after opening another app, so the island can close.
    @ObservationIgnored var onOpenedApp: (() -> Void)?
    /// Called after the dark-mode button switched macOS, so the tiles can follow.
    @ObservationIgnored var onDarkModeSwitched: (() -> Void)?
    @ObservationIgnored private let isPreview: Bool
    @ObservationIgnored private let workQueue = DispatchQueue(label: "CustomNotch.controls")
    @ObservationIgnored private var noticeWork: DispatchWorkItem?
    @ObservationIgnored private var airDropRequest = 0

    init(preview: Bool = false) {
        isPreview = preview
        if preview {
            wifiOn = true; wifiBars = 4; airDrop = .contactsOnly; volume = 0.6; brightness = 0.7
            brightnessAvailable = true
            amphetamine = AmphetamineSession(active: true, endsAt: Date().addingTimeInterval(3_540), duration: .hour1)
        }
    }

    func refresh() {
        guard !isPreview else { return }
        showingSliders = false
        showingAirDrop = false
        showingAmphetamine = false
        readWiFi()
        airDrop = Self.readAirDrop()
        darkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        readVolume()
        if let level = Brightness.get() { brightness = Double(level); brightnessAvailable = true }
        // Only once Custom Notch may control Amphetamine: opening the island never shows a permission prompt.
        if amphetamineApp.isRunning {
            Task {
                if await AppleScript.isAuthorized(amphetamineApp.bundleID) { await readAmphetamine(quietly: true) }
            }
        } else {
            amphetamine = AmphetamineSession()
        }
    }

    // MARK: Wi-Fi (CoreWLAN; the network name would need Location, so it is not read)

    private func readWiFi() {
        guard let interface = CWWiFiClient.shared().interface() else { wifiAvailable = false; return }
        wifiAvailable = true
        wifiOn = interface.powerOn()
        let rssi = interface.rssiValue()
        switch rssi {
        case 0: wifiBars = 0                    // not connected
        case (-55)...: wifiBars = 5
        case -62 ..< -55: wifiBars = 4
        case -70 ..< -62: wifiBars = 3
        case -78 ..< -70: wifiBars = 2
        default: wifiBars = 1
        }
    }

    func toggleWiFi() {
        guard let interface = CWWiFiClient.shared().interface() else { return }
        let target = !interface.powerOn()
        wifiOn = target
        // Turning the radio on can take a moment; keep the island responsive.
        workQueue.async { [weak self] in
            let switched = (try? interface.setPower(target)) != nil
            DispatchQueue.main.async {
                guard let self else { return }
                if switched {
                    // Signal strength settles a moment after the radio comes back.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.readWiFi() }
                } else {
                    self.wifiOn = !target
                    self.show("macOS didn't allow switching Wi-Fi. Use the Wi-Fi menu instead.")
                }
            }
        }
    }

    // MARK: AirDrop (no public API: sharingd's preference is written and sharingd restarted to pick it up)

    nonisolated private static var sharingDomain: CFString { "com.apple.sharingd" as CFString }
    nonisolated private static var discoverableKey: CFString { "DiscoverableMode" as CFString }

    nonisolated private static func readAirDrop() -> AirDropMode {
        // Drop this process's cached copy, so a change made elsewhere (or by sharingd) is seen.
        CFPreferencesAppSynchronize(sharingDomain)
        let value = CFPreferencesCopyAppValue(discoverableKey, sharingDomain) as? String ?? ""
        if value.localizedCaseInsensitiveContains("everyone") { return .everyone }
        if value.localizedCaseInsensitiveContains("contacts") { return .contactsOnly }
        return .off
    }

    /// Applies the mode like Control Center does; the choices stay open with the new one selected.
    func setAirDrop(_ mode: AirDropMode) {
        guard mode != airDrop else { return }
        airDrop = mode                          // optimistic; checked again below
        guard !isPreview else { return }
        airDropRequest += 1
        let request = airDropRequest
        workQueue.async { [weak self] in
            Self.applyAirDrop(mode)
            // sharingd takes a moment to come back; read what it settled on.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                // A later choice has its own check.
                guard let self, request == self.airDropRequest else { return }
                let actual = Self.readAirDrop()
                self.airDrop = actual
                if actual != mode {
                    self.show("macOS didn't switch AirDrop. Use AirDrop in Control Center instead.")
                }
            }
        }
    }

    /// Writes sharingd's preference and restarts it. Blocking; call off the main thread.
    /// Returns whether the preference holds the new value afterwards.
    @discardableResult
    nonisolated static func applyAirDrop(_ mode: AirDropMode) -> Bool {
        CFPreferencesSetAppValue(discoverableKey, mode.rawValue as CFString, sharingDomain)
        let synced = CFPreferencesAppSynchronize(sharingDomain)
        if !synced || readAirDrop() != mode {
            // Fall back to the command-line tool, which writes through cfprefsd as the user.
            run("/usr/bin/defaults", ["write", "com.apple.sharingd", "DiscoverableMode", "-string", mode.rawValue])
        }
        // sharingd reads the preference when it starts; launchd brings it straight back.
        run("/usr/bin/killall", ["sharingd"])
        return readAirDrop() == mode
    }

    nonisolated private static func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {}
    }

    func showAirDrop() {
        showingSliders = false
        showingAmphetamine = false
        showingAirDrop = true
    }

    func showSliders() {
        showingAirDrop = false
        showingAmphetamine = false
        showingSliders = true
    }

    // MARK: Amphetamine (its AppleScript dictionary; needs the Automation permission once)

    /// Opens the session choices, like a click on Amphetamine's menu-bar icon. If Amphetamine isn't open yet,
    /// it is started in the background first (its menu-bar icon needs it running, too).
    func showAmphetamine() {
        guard !isPreview else { openAmphetaminePanel(); return }
        guard let url = amphetamineApp.url else {
            show("Amphetamine isn't installed. It's free in the Mac App Store.")
            return
        }
        Task {
            if !amphetamineApp.isRunning {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                try? await Task.sleep(for: .seconds(1.5))      // its scripting is ready a moment after launch
            }
            if await readAmphetamine() { openAmphetaminePanel() }
        }
    }

    private func openAmphetaminePanel() {
        showingAirDrop = false
        showingSliders = false
        showingAmphetamine = true
    }

    /// Ends the running session, or starts one with Amphetamine's own default duration (its Preferences).
    func toggleAmphetamine() {
        if amphetamine.active {
            amphetamine.active = false
            amphetamine.duration = nil
            runAmphetamine("end session")
        } else {
            amphetamine.active = true
            amphetamine.endsAt = nil
            amphetamine.duration = nil
            runAmphetamine("start new session")
        }
    }

    /// Starts a new session of this length; Amphetamine ends the current one first.
    func startAmphetamine(_ duration: AmphetamineDuration) {
        amphetamine.active = true
        amphetamine.duration = duration
        amphetamine.endsAt = duration.seconds.map { Date().addingTimeInterval($0) }
        let displaySleep = amphetamine.displaySleepAllowed ? "true" : "false"
        runAmphetamine("start new session with options {\(duration.options), displaySleepAllowed:\(displaySleep)}")
    }

    /// Whether the display may sleep: for the running session, or else for the next ones (Amphetamine's rule).
    func setAmphetamineDisplaySleep(_ allowed: Bool) {
        amphetamine.displaySleepAllowed = allowed
        runAmphetamine(allowed ? "allow display sleep" : "prevent display sleep")
    }

    private func runAmphetamine(_ command: String) {
        guard !isPreview else { return }
        Task {
            let result = await AppleScript.run("tell application id \"\(amphetamineApp.bundleID)\" to \(command)",
                                               requiring: amphetamineApp.bundleID)
            if result.errorNumber != nil { report(result) }
            await readAmphetamine()
        }
    }

    /// Reads the session from Amphetamine. Returns false (and, unless `quietly`, explains why in the tile) if it couldn't.
    @discardableResult
    private func readAmphetamine(quietly: Bool = false) async -> Bool {
        let source = """
        tell application id "\(amphetamineApp.bundleID)"
            return {session is active, session time remaining, display sleep allowed}
        end tell
        """
        let result = await AppleScript.run(source, requiring: amphetamineApp.bundleID)
        guard let list = result.descriptor, result.errorNumber == nil, list.numberOfItems == 3 else {
            if !quietly { report(result) }
            return false
        }
        let active = list.atIndex(1)?.booleanValue ?? false
        // Seconds left; 0 while it runs indefinitely, negative without a session.
        let remaining = Int(list.atIndex(2)?.int32Value ?? -1)
        amphetamine.active = active
        amphetamine.endsAt = active && remaining > 0 ? Date().addingTimeInterval(TimeInterval(remaining)) : nil
        amphetamine.displaySleepAllowed = list.atIndex(3)?.booleanValue ?? false
        if !active { amphetamine.duration = nil }
        // A duration chosen here stays highlighted only while the session still matches it.
        if let duration = amphetamine.duration, (duration.seconds == nil) != (amphetamine.endsAt == nil) {
            amphetamine.duration = nil
        }
        return true
    }

    private func report(_ result: AppleScript.Result) {
        if result.notAuthorized {
            show("Amphetamine needs permission to be controlled by Custom Notch (Privacy & Security → Automation).",
                 settings: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"))
        } else if result.errorNumber == -600 {
            show("Amphetamine isn't running.")
        } else {
            show("Amphetamine didn't answer. Use its menu-bar icon instead.")
        }
    }

    // MARK: Raycast (its URL scheme: "raycast://" opens the search window, like the hot key)

    func openRaycast() {
        guard !isPreview else { return }
        guard raycastApp.url != nil, let url = URL(string: "raycast://") else {
            show("Raycast isn't installed.")
            return
        }
        NSWorkspace.shared.open(url)
        onOpenedApp?()
    }

    // MARK: Dark mode (System Events, needs the Automation permission once)

    func toggleDarkMode() {
        let source = """
        tell application "System Events"
            tell appearance preferences
                set dark mode to not dark mode
                return dark mode
            end tell
        end tell
        """
        Task {
            let result = await AppleScript.run(source)
            if let isDark = result.descriptor?.booleanValue, result.errorNumber == nil {
                darkMode = isDark
                onDarkModeSwitched?()
            } else if result.notAuthorized {
                show("Dark mode needs permission to control System Events (Privacy & Security → Automation).",
                     settings: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"))
            } else {
                show("Couldn't switch dark mode.")
            }
        }
    }

    // MARK: Volume (CoreAudio, default output device)

    private func readVolume() {
        guard let device = Audio.defaultOutput() else { return }
        if let level = Audio.volume(of: device) { volume = Double(level) }
        muted = Audio.isMuted(device)
    }

    func setVolume(_ value: Double) {
        guard let device = Audio.defaultOutput() else { return }
        volume = min(max(value, 0), 1)
        Audio.setVolume(Float32(volume), of: device)
        if muted && volume > 0 { Audio.setMuted(false, device); muted = false }
    }

    func toggleMute() {
        guard let device = Audio.defaultOutput() else { return }
        muted.toggle()
        Audio.setMuted(muted, device)
    }

    // MARK: Brightness (private DisplayServices framework, built-in display)

    func setBrightness(_ value: Double) {
        brightness = min(max(value, 0), 1)
        Brightness.set(Float(brightness))
    }

    // MARK: Helpers

    func openSettings(_ url: URL) {
        notice = nil
        NSWorkspace.shared.open(url)
        onOpenedApp?()
    }

    private func show(_ message: String, settings: URL? = nil) {
        noticeWork?.cancel()
        notice = TileNotice(text: message, settings: settings)
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
}

// MARK: - Amphetamine and Raycast

struct AmphetamineSession: Equatable {
    var active = false
    /// When a timed session ends; nil while it runs indefinitely (or none runs).
    var endsAt: Date?
    var displaySleepAllowed = false
    /// The length chosen here, highlighted while that session runs.
    var duration: AmphetamineDuration?

    /// "Indefinitely", "1:05:12 left", "Off".
    func status(at now: Date) -> String {
        guard active else { return "Off" }
        guard let endsAt else { return "Indefinitely" }
        let seconds = max(Int(endsAt.timeIntervalSince(now).rounded(.up)), 0)
        let (hours, minutes, rest) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d left", hours, minutes, rest)
                         : String(format: "%d:%02d left", minutes, rest)
    }
}

/// The session lengths offered in the island; Amphetamine's menu has the same under Start New Session.
enum AmphetamineDuration: CaseIterable, Equatable, Sendable {
    case indefinitely, minutes30, hour1, hours2, hours4

    var title: String {
        switch self {
        case .indefinitely: "∞"
        case .minutes30: "30m"
        case .hour1: "1h"
        case .hours2: "2h"
        case .hours4: "4h"
        }
    }

    var spokenTitle: String {
        switch self {
        case .indefinitely: "Indefinitely"
        case .minutes30: "30 minutes"
        case .hour1: "1 hour"
        case .hours2: "2 hours"
        case .hours4: "4 hours"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .indefinitely: nil
        case .minutes30: 1_800
        case .hour1: 3_600
        case .hours2: 7_200
        case .hours4: 14_400
        }
    }

    /// The record fields Amphetamine's `start new session with options` takes (0 and 0: indefinitely).
    var options: String {
        switch self {
        case .indefinitely: "duration:0, interval:0"
        case .minutes30: "duration:30, interval:minutes"
        case .hour1: "duration:1, interval:hours"
        case .hours2: "duration:2, interval:hours"
        case .hours4: "duration:4, interval:hours"
        }
    }
}

/// An app found by its bundle identifier; its logo is the app icon, in colour.
@MainActor
struct InstalledApp {
    let bundleID: String

    var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    var icon: NSImage? { url.map { NSWorkspace.shared.icon(forFile: $0.path) } }
}

@MainActor let amphetamineApp = InstalledApp(bundleID: "com.if.Amphetamine")
@MainActor let raycastApp = InstalledApp(bundleID: "com.raycast.macos")

// MARK: - CoreAudio

private enum Audio {
    static func defaultOutput() -> AudioObjectID? {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    static func volume(of device: AudioObjectID) -> Float32? {
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func setVolume(_ value: Float32, of device: AudioObjectID) {
        var value = value
        AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    static func isMuted(_ device: AudioObjectID) -> Bool {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &value) == noErr && value != 0
    }

    static func setMuted(_ muted: Bool, _ device: AudioObjectID) {
        var value = UInt32(muted ? 1 : 0)
        AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

// MARK: - DisplayServices (private; there is no public brightness API)

private enum Brightness {
    private typealias Getter = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getter = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Getter.self) }
    private static let setter = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Setter.self) }

    /// The built-in display if there is one, otherwise the main display.
    private static var display: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &count)
        return ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? CGMainDisplayID()
    }

    static func get() -> Float? {
        guard let getter else { return nil }
        var value: Float = 0
        return getter(display, &value) == 0 ? value : nil
    }

    static func set(_ value: Float) {
        _ = setter?(display, value)
    }
}

// MARK: - Tile: Quick controls

struct ControlsTile: View {
    let controls: SystemControls
    let cells: Int
    let palette: Palette
    var openChess: () -> Void = {}
    var openPrompter: () -> Void = {}

    private enum Item { case wifi, airDrop, appearance, soundAndDisplay, chess, prompter, amphetamine, raycast }

    var body: some View {
        // One inset all round; inner corners are concentric with the tile's (14 − inset).
        let padding: CGFloat = cells == 1 ? 6 : 7
        let spacing: CGFloat = 6
        let radius = Metrics.tileRadius - padding
        // One cell has room for four buttons; Dark Mode, Chess, Amphetamine and Raycast need the larger tile.
        let items: [Item] = cells == 1 ? [.wifi, .airDrop, .soundAndDisplay, .prompter]
                                       : [.wifi, .airDrop, .appearance, .soundAndDisplay,
                                          .chess, .prompter, .amphetamine, .raycast]
        let columns = items.count / 2
        let width = (Metrics.tileWidth(cells: cells) - 2 * padding - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let height = (Metrics.tileHeight - 2 * padding - spacing) / 2

        Group {
            if let notice = controls.notice {
                FittedNotice(notice: notice, compact: cells == 1, palette: palette, open: controls.openSettings)
            } else if controls.showingAirDrop || controls.showingSliders || controls.showingAmphetamine {
                // The chevron runs the full height from the tile's edge, so it is easy to hit even at one cell.
                HStack(spacing: 0) {
                    BackButton(palette: palette, width: cells == 1 ? 16 : 26) {
                        controls.showingAirDrop = false
                        controls.showingSliders = false
                        controls.showingAmphetamine = false
                    }
                    Group {
                        if controls.showingAirDrop {
                            // Three rows of 20 pt need a little more height than the grid's inset leaves.
                            AirDropPanel(controls: controls, compact: cells == 1, radius: radius, palette: palette)
                                .padding(.vertical, padding - 1)
                        } else if controls.showingAmphetamine {
                            AmphetaminePanel(controls: controls, radius: radius, palette: palette)
                                .padding(.vertical, padding - 1)
                        } else {
                            SlidersPanel(controls: controls, palette: palette, compact: cells == 1, radius: radius)
                                .padding(.vertical, padding)
                        }
                    }
                    .padding(.trailing, padding)
                }
            } else {
                VStack(spacing: spacing) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: spacing) {
                            ForEach(0..<columns, id: \.self) { column in
                                button(items[row * columns + column], narrow: width < 40)
                                    .environment(\.controlRadius, radius)
                                    .frame(width: width, height: height)
                            }
                        }
                    }
                }
                .padding(padding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func button(_ item: Item, narrow: Bool) -> some View {
        switch item {
        case .wifi:
            ControlButton(icon: .symbol(controls.wifiOn ? "wifi" : "wifi.slash"), label: "Wi-Fi", value: controls.wifiOn ? "On" : "Off",
                          active: controls.wifiOn, dots: controls.wifiOn ? controls.wifiBars : nil,
                          palette: palette, action: controls.toggleWiFi)
        case .airDrop:
            // Tinted while this Mac can be seen; the panel shows by whom.
            ControlButton(icon: AirDropGlyph.icon, label: "AirDrop", value: controls.airDrop.title,
                          active: controls.airDrop != .off, palette: palette, action: controls.showAirDrop)
        case .appearance:
            ControlButton(icon: .symbol("circle.lefthalf.filled"), label: "Dark Mode", value: controls.darkMode ? "On" : "Off",
                          active: controls.darkMode, palette: palette, action: controls.toggleDarkMode)
        case .soundAndDisplay:
            ControlButton(icon: .pair(controls.muted ? "speaker.slash" : "speaker.wave.2", "sun.max"), label: "Sound & Display",
                          compact: narrow, palette: palette, action: controls.showSliders)
        case .chess:
            ControlButton(icon: .symbol("checkerboard.rectangle"), label: "Chess", palette: palette, action: openChess)
        case .prompter:
            ControlButton(icon: .symbol(PrompterSymbol.name), label: "Teleprompter", palette: palette, action: openPrompter)
        case .amphetamine:
            // Its logo in colour while it keeps the Mac awake, greyed out while it doesn't.
            let session = controls.amphetamine
            ControlButton(icon: amphetamineApp.icon.map { .appIcon($0, dimmed: !session.active) } ?? .symbol("pills.fill"),
                          label: "Amphetamine", value: session.active ? "Keeping Awake" : "Off",
                          active: session.active, palette: palette, action: controls.showAmphetamine)
        case .raycast:
            ControlButton(icon: raycastApp.icon.map { .appIcon($0, dimmed: false) } ?? .symbol("command"),
                          label: "Raycast", palette: palette, action: controls.openRaycast)
        }
    }
}

private enum PrompterSymbol {
    /// Lines of text with a play marker: a script that runs.
    static let name = "text.line.first.and.arrowtriangle.forward"
}

/// Apple's own AirDrop glyph (the one in Finder's sidebar), drawn as a template so it takes the tile's colours.
@MainActor
private enum AirDropGlyph {
    static let image: NSImage? = {
        let path = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/SidebarAirDrop.icns"
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        image.isTemplate = true
        return image
    }()

    static var icon: ControlButton.Icon {
        image.map { .image($0) } ?? .symbol("dot.radiowaves.left.and.right")
    }
}

struct ControlButton: View {
    enum Icon {
        case symbol(String)
        case image(NSImage)
        /// Two smaller symbols side by side, for a button that holds two controls.
        case pair(String, String)
        /// An app's own icon, in its colours; `dimmed` greys it out (its feature is off).
        case appIcon(NSImage, dimmed: Bool)
    }

    let icon: Icon
    /// What the button is, for the tooltip and VoiceOver ("Wi-Fi").
    let label: String
    /// Its state, if it has one ("On", "Contacts Only").
    var value: String? = nil
    var active = false
    /// Signal strength, 0...5; nil hides the dots.
    var dots: Int? = nil
    /// A narrow button (one-cell tile): a pair of symbols is drawn smaller.
    var compact = false
    let palette: Palette
    let action: () -> Void
    @Environment(\.controlRadius) private var radius

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(active ? palette.controlActive : palette.control)
                // The glyph stays centred so the buttons in a row line up; the dots sit beneath it.
                glyph
                    .foregroundStyle(active ? palette.accent : palette.text)
                if let dots {
                    HStack(spacing: 2.5) {
                        ForEach(0..<5, id: \.self) { index in
                            Circle()
                                .fill(index < dots ? palette.accent : palette.secondary.opacity(0.35))
                                .frame(width: 2.5, height: 2.5)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(value.map { "\(label): \($0)" } ?? label)
        .accessibilityLabel(label)
        .accessibilityValue(value ?? "")
    }

    @ViewBuilder
    private var glyph: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: name == PrompterSymbol.name ? 12.5 : 14, weight: .medium))
        case .image(let image):
            // The sidebar glyph has a little padding of its own, so it is drawn a bit larger than the symbols.
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 17, height: 17)
        case .pair(let first, let second):
            HStack(spacing: compact ? 1.5 : 2.5) {
                Image(systemName: first)
                Image(systemName: second)
            }
            .font(.system(size: compact ? 10 : 11.5, weight: .medium))
        case .appIcon(let image, let dimmed):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .saturation(dimmed ? 0 : 1)
                .opacity(dimmed ? 0.55 : 1)
        }
    }
}

/// Who can see this Mac in AirDrop, shown in place of the buttons; the current choice is filled.
private struct AirDropPanel: View {
    let controls: SystemControls
    let compact: Bool
    var radius: CGFloat = 7
    let palette: Palette

    var body: some View {
        VStack(spacing: 3) {
            ForEach(SystemControls.AirDropMode.allCases, id: \.self) { mode in
                row(mode)
            }
        }
    }

    private func row(_ mode: SystemControls.AirDropMode) -> some View {
        let selected = controls.airDrop == mode
        return Button { controls.setAirDrop(mode) } label: {
            HStack(spacing: 4) {
                Text(compact ? mode.shortTitle : mode.title)
                    .font(.system(size: compact ? 10 : 10.5, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                if !compact {
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .semibold))
                        .opacity(selected ? 1 : 0)
                }
            }
            .foregroundStyle(selected ? palette.accent : palette.text)
            .padding(.horizontal, compact ? 3 : 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .center : .leading)
            .background(selected ? palette.controlActive : palette.control,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("AirDrop: \(mode.title)")
        .accessibilityLabel("AirDrop: \(mode.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Amphetamine's choices, shown in place of the buttons: what its menu-bar icon offers for a session.
/// Start or end it (with its default length), start one of a given length, and whether the display may sleep.
private struct AmphetaminePanel: View {
    let controls: SystemControls
    var radius: CGFloat = 7
    let palette: Palette

    var body: some View {
        let session = controls.amphetamine
        VStack(spacing: 3) {
            // The countdown ticks only while this panel is shown.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                row(selected: session.active, help: session.active ? "End Session" : "Start New Session",
                    action: controls.toggleAmphetamine) {
                    Text("Awake").font(.system(size: 10.5, weight: session.active ? .semibold : .regular))
                    Spacer(minLength: 4)
                    Text(session.status(at: context.date))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(session.active ? palette.accent : palette.secondary)
                }
            }
            HStack(spacing: 3) {
                ForEach(AmphetamineDuration.allCases, id: \.self) { duration in
                    let selected = session.active && session.duration == duration
                    Button { controls.startAmphetamine(duration) } label: {
                        Text(duration.title)
                            .font(.system(size: duration == .indefinitely ? 12 : 10,
                                          weight: selected ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(selected ? palette.accent : palette.text)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(selected ? palette.controlActive : palette.control,
                                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Start New Session: \(duration.spokenTitle)")
                    .accessibilityLabel("Keep awake \(duration.spokenTitle)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            row(selected: !session.displaySleepAllowed,
                help: session.displaySleepAllowed ? "Prevent Display Sleep" : "Allow Display Sleep",
                action: { controls.setAmphetamineDisplaySleep(!session.displaySleepAllowed) }) {
                Text("Display Stays On").font(.system(size: 10.5))
                Spacer(minLength: 4)
                Image(systemName: "checkmark")
                    .font(.system(size: 9.5, weight: .semibold))
                    .opacity(session.displaySleepAllowed ? 0 : 1)
            }
        }
    }

    private func row<Label: View>(selected: Bool, help: String, action: @escaping () -> Void,
                                  @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            HStack(spacing: 4) { label() }
                .lineLimit(1)
                .foregroundStyle(selected ? palette.accent : palette.text)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(selected ? palette.controlActive : palette.control,
                            in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The chevron that closes a panel and brings the buttons back.
private struct BackButton: View {
    let palette: Palette
    var width: CGFloat = 14
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.secondary)
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Back")
        .accessibilityLabel("Back")
    }
}

private struct ControlRadiusKey: EnvironmentKey {
    static let defaultValue: CGFloat = 7
}

extension EnvironmentValues {
    /// Corner radius of a Quick Controls button, concentric with the tile (tile radius − inset).
    var controlRadius: CGFloat {
        get { self[ControlRadiusKey.self] }
        set { self[ControlRadiusKey.self] = newValue }
    }
}

enum VolumeSymbol {
    static func name(_ volume: Double, muted: Bool) -> String {
        if muted { return "speaker.slash" }
        switch volume {
        case ..<0.01: return "speaker"
        case ..<0.34: return "speaker.wave.1"
        case ..<0.67: return "speaker.wave.2"
        default: return "speaker.wave.3"
        }
    }
}

/// Volume and brightness sliders, shown in place of the buttons.
struct SlidersPanel: View {
    let controls: SystemControls
    let palette: Palette
    /// A one-cell tile: each symbol sits above its slider, so the slider keeps a usable length.
    var compact = false
    var radius: CGFloat = 7

    var body: some View {
        VStack(spacing: 6) {
            SliderRow(symbol: VolumeSymbol.name(controls.volume, muted: controls.muted),
                      value: controls.muted ? 0 : controls.volume, enabled: true,
                      name: "Volume", iconLabel: controls.muted ? "Unmute" : "Mute", compact: compact, radius: radius,
                      palette: palette, onIcon: controls.toggleMute, onChange: controls.setVolume)
            SliderRow(symbol: "sun.max", value: controls.brightness, enabled: controls.brightnessAvailable,
                      name: "Brightness", compact: compact, radius: radius, palette: palette, onIcon: {},
                      onChange: controls.setBrightness)
        }
    }
}

struct SliderRow: View {
    let symbol: String
    let value: Double
    let enabled: Bool
    /// What the slider sets, for VoiceOver.
    var name = ""
    /// What the symbol does when clicked, if anything.
    var iconLabel: String? = nil
    var compact = false
    var radius: CGFloat = 7
    let palette: Palette
    let onIcon: () -> Void
    let onChange: (Double) -> Void

    var body: some View {
        let layout = compact ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 7))
        layout {
            Button(action: onIcon) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.text)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help(iconLabel ?? name)
            .accessibilityLabel(iconLabel ?? name)
            FlatSlider(value: value, palette: palette, onChange: onChange)
                .accessibilityLabel(name)
                .accessibilityValue("\(Int((value * 100).rounded())) %")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: onChange(min(value + 0.1, 1))
                    case .decrement: onChange(max(value - 0.1, 0))
                    @unknown default: break
                    }
                }
                .frame(maxHeight: compact ? 9 : .infinity)
        }
        .padding(.horizontal, compact ? 7 : 8)
        .frame(maxHeight: .infinity)
        .background(palette.control, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .opacity(enabled ? 1 : 0.4)
        .allowsHitTesting(enabled)
    }
}

/// Flat track with an accent fill; click or drag anywhere on it.
struct FlatSlider: View {
    let value: Double
    let palette: Palette
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(palette.secondary.opacity(0.22))
                Capsule().fill(palette.accent).frame(width: max(5, width * value))
            }
            .frame(height: 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                onChange(min(max(drag.location.x / width, 0), 1))
            })
        }
    }
}
