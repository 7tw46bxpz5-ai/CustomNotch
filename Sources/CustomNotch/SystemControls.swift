import SwiftUI
import AppKit
import AudioToolbox
import CoreAudio
@preconcurrency import CoreWLAN

/// Wi-Fi, AirDrop, dark mode, volume, brightness and the app grid.
/// Nothing is monitored in the background: states are read when the island opens and after each action.
@MainActor @Observable
final class SystemControls {
    enum AirDropMode: Equatable { case off, contactsOnly, everyone }

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
    var showingSliders = false

    /// Called after opening another app, so the island can close.
    @ObservationIgnored var onOpenedApp: (() -> Void)?
    /// Called after the dark-mode button switched macOS, so the tiles can follow.
    @ObservationIgnored var onDarkModeSwitched: (() -> Void)?
    @ObservationIgnored private let isPreview: Bool
    @ObservationIgnored private let workQueue = DispatchQueue(label: "CustomNotch.controls")
    @ObservationIgnored private var noticeWork: DispatchWorkItem?

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

    // MARK: AirDrop (no public API to switch it: the button opens the AirDrop window)

    private static func readAirDrop() -> AirDropMode {
        let value = CFPreferencesCopyAppValue("DiscoverableMode" as CFString, "com.apple.sharingd" as CFString) as? String ?? ""
        if value.localizedCaseInsensitiveContains("everyone") { return .everyone }
        if value.localizedCaseInsensitiveContains("contacts") { return .contactsOnly }
        return .off
    }

    func openAirDrop() {
        open("/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
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

    // MARK: App grid

    func openAppGrid() {
        // macOS 26 replaced Launchpad with Apps.
        let apps = "/System/Applications/Apps.app"
        open(FileManager.default.fileExists(atPath: apps) ? apps : "/System/Applications/Launchpad.app")
    }

    // MARK: Helpers

    private func open(_ path: String) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
        onOpenedApp?()
    }

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

    private enum Item { case wifi, airDrop, darkMode, volume, brightness, apps }

    var body: some View {
        let padding: CGFloat = cells == 1 ? 6 : 9
        let spacing: CGFloat = 6
        let columns = cells == 1 ? 2 : 3
        // One cell has room for four buttons.
        let items: [Item] = cells == 1 ? [.wifi, .darkMode, .volume, .brightness]
                                       : [.wifi, .airDrop, .darkMode, .volume, .brightness, .apps]
        let width = (Metrics.tileWidth(cells: cells) - 2 * padding - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let height = (Metrics.tileHeight - 2 * padding - spacing) / 2

        Group {
            if let notice = controls.notice {
                NoticeView(notice: notice, palette: palette, open: controls.openSettings)
            } else if controls.showingSliders {
                SlidersPanel(controls: controls, palette: palette)
            } else {
                VStack(spacing: spacing) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: spacing) {
                            ForEach(0..<columns, id: \.self) { column in
                                button(items[row * columns + column])
                                    .frame(width: width, height: height)
                            }
                        }
                    }
                }
            }
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func button(_ item: Item) -> some View {
        switch item {
        case .wifi:
            ControlButton(symbol: controls.wifiOn ? "wifi" : "wifi.slash", active: controls.wifiOn,
                          dots: controls.wifiOn ? controls.wifiBars : 0, palette: palette, action: controls.toggleWiFi)
        case .airDrop:
            // Dots show who can see this Mac: all five for Everyone, three for Contacts Only.
            ControlButton(symbol: "dot.radiowaves.left.and.right", active: controls.airDrop != .off,
                          dots: controls.airDrop == .everyone ? 5 : controls.airDrop == .contactsOnly ? 3 : 0,
                          palette: palette, action: controls.openAirDrop)
        case .darkMode:
            ControlButton(symbol: "circle.lefthalf.filled", active: controls.darkMode, dots: nil,
                          palette: palette, action: controls.toggleDarkMode)
        case .volume:
            ControlButton(symbol: VolumeSymbol.name(controls.volume, muted: controls.muted), active: false, dots: nil,
                          palette: palette) { controls.showingSliders = true }
        case .brightness:
            ControlButton(symbol: "sun.max", active: false, dots: nil, palette: palette) { controls.showingSliders = true }
        case .apps:
            ControlButton(symbol: "square.grid.3x3", active: false, dots: nil, palette: palette, action: controls.openAppGrid)
        }
    }
}

struct ControlButton: View {
    let symbol: String
    let active: Bool
    let dots: Int?
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(active ? palette.controlActive : palette.control)
                VStack(spacing: 4) {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(active ? palette.accent : palette.text)
                    if let dots {
                        HStack(spacing: 2.5) {
                            ForEach(0..<5, id: \.self) { index in
                                Circle()
                                    .fill(index < dots ? palette.accent : palette.secondary.opacity(0.35))
                                    .frame(width: 2.5, height: 2.5)
                            }
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    var body: some View {
        HStack(spacing: 4) {
            Button { controls.showingSliders = false } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.secondary)
                    .frame(width: 14)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(spacing: 6) {
                SliderRow(symbol: VolumeSymbol.name(controls.volume, muted: controls.muted),
                          value: controls.muted ? 0 : controls.volume, enabled: true, palette: palette,
                          onIcon: controls.toggleMute, onChange: controls.setVolume)
                SliderRow(symbol: "sun.max", value: controls.brightness, enabled: controls.brightnessAvailable,
                          palette: palette, onIcon: {}, onChange: controls.setBrightness)
            }
        }
    }
}

struct SliderRow: View {
    let symbol: String
    let value: Double
    let enabled: Bool
    let palette: Palette
    let onIcon: () -> Void
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onIcon) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.text)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            FlatSlider(value: value, palette: palette, onChange: onChange)
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(palette.control, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
