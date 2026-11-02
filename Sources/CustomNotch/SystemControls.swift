import SwiftUI
import AppKit
import AudioToolbox
import CoreAudio
@preconcurrency import CoreWLAN

/// Wi-Fi, AirDrop, dark mode, volume and brightness.
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
        }
    }

    func refresh() {
        guard !isPreview else { return }
        showingSliders = false
        showingAirDrop = false
        readWiFi()
        airDrop = Self.readAirDrop()
        darkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        readVolume()
        if let level = Brightness.get() { brightness = Double(level); brightnessAvailable = true }
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
        showingAirDrop = true
    }

    func showSliders() {
        showingAirDrop = false
        showingSliders = true
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

    private enum Item { case wifi, airDrop, appearance, soundAndDisplay, chess, prompter }

    var body: some View {
        // One inset all round; inner corners are concentric with the tile's (14 − inset).
        let padding: CGFloat = cells == 1 ? 6 : 7
        let spacing: CGFloat = 6
        let radius = Metrics.tileRadius - padding
        let columns = cells == 1 ? 2 : 3
        // One cell has room for four buttons; Dark Mode and Chess stay in the menu bar and the larger tile.
        let items: [Item] = cells == 1 ? [.wifi, .airDrop, .soundAndDisplay, .prompter]
                                       : [.wifi, .airDrop, .appearance, .soundAndDisplay, .chess, .prompter]
        let width = (Metrics.tileWidth(cells: cells) - 2 * padding - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let height = (Metrics.tileHeight - 2 * padding - spacing) / 2

        Group {
            if let notice = controls.notice {
                FittedNotice(notice: notice, compact: cells == 1, palette: palette, open: controls.openSettings)
            } else if controls.showingAirDrop || controls.showingSliders {
                // The chevron runs the full height from the tile's edge, so it is easy to hit even at one cell.
                HStack(spacing: 0) {
                    BackButton(palette: palette, width: cells == 1 ? 16 : 26) {
                        controls.showingAirDrop = false
                        controls.showingSliders = false
                    }
                    Group {
                        if controls.showingAirDrop {
                            // Three rows of 20 pt need a little more height than the grid's inset leaves.
                            AirDropPanel(controls: controls, compact: cells == 1, radius: radius, palette: palette)
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
                                button(items[row * columns + column])
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
    private func button(_ item: Item) -> some View {
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
                          compact: cells == 1, palette: palette, action: controls.showSliders)
        case .chess:
            ControlButton(icon: .symbol("checkerboard.rectangle"), label: "Chess", palette: palette, action: openChess)
        case .prompter:
            ControlButton(icon: .symbol(PrompterSymbol.name), label: "Teleprompter", palette: palette, action: openPrompter)
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
