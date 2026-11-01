import AppKit
import Intents
import IOKit.ps

/// Watches for the moments that get a short bubble under the notch: the charger being connected,
/// the battery reaching 20% and 10%, and Focus turning on or off.
/// Everything is event-driven except Focus, which macOS only lets apps read, not observe.
@MainActor
final class PeekSources {
    enum FocusAccess { case notAsked, granted, unavailable }

    private let settings: Settings
    private let show: (PeekContent) -> Void

    private var powerSource: CFRunLoopSource?
    private var onAC: Bool?
    private var warned20 = false
    private var warned10 = false

    private var focusTimer: Timer?
    private var lastFocused: Bool?

    init(settings: Settings, show: @escaping (PeekContent) -> Void) {
        self.settings = settings
        self.show = show
    }

    func start() {
        // Power: one callback per change of source or percentage.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let sources = Unmanaged<PeekSources>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { sources.powerChanged() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        powerChanged()
        updateFocusMonitoring()
    }

    // MARK: Power

    struct Battery {
        var onAC: Bool
        var charging: Bool
        var percent: Int?
    }

    static func readBattery() -> Battery {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var battery = Battery(onAC: type == kIOPMACPowerKey, charging: false, percent: nil)
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            battery.percent = current * 100 / maximum
            battery.charging = description[kIOPSIsChargingKey] as? Bool ?? false
        }
        return battery
    }

    private func powerChanged() {
        let battery = Self.readBattery()
        guard let percent = battery.percent else { return }       // a Mac without a battery
        defer { onAC = battery.onAC }

        if battery.onAC {
            warned20 = false
            warned10 = false
            if onAC == false, settings.peekCharger {
                show(PeekContent(symbol: "bolt.fill", title: battery.charging ? "Charging" : "Plugged In",
                                 subtitle: "Battery \(percent)%", duration: 3))
            }
            return
        }
        // On battery: warn once when crossing 20% and 10%. Already below at launch counts as warned.
        let firstReading = onAC == nil
        if percent <= 10, !warned10 {
            warned10 = true
            warned20 = true
            if !firstReading, settings.peekBattery {
                show(PeekContent(symbol: "battery.0", title: "Battery 10%", subtitle: "Connect the charger soon",
                                 tint: .critical, duration: 4))
            }
        } else if percent <= 20, !warned20 {
            warned20 = true
            if !firstReading, settings.peekBattery {
                show(PeekContent(symbol: "battery.25", title: "Battery 20%", subtitle: "Low battery",
                                 tint: .warning, duration: 4))
            }
        }
    }

    // MARK: Focus

    /// macOS only says whether *a* Focus is on (Do Not Disturb, Work, Sleep…), not which one, and only
    /// after you allow it. There is no change notification, so this checks every 3 seconds while on.
    var focusAccess: FocusAccess {
        switch INFocusStatusCenter.default.authorizationStatus {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .unavailable
        }
    }

    func requestFocusAccess(then done: @escaping () -> Void) {
        INFocusStatusCenter.default.requestAuthorization { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.focusAccess == .granted { self.settings.peekFocus = true }
                self.updateFocusMonitoring()
                done()
            }
        }
    }

    func updateFocusMonitoring() {
        let wanted = settings.peekFocus && focusAccess == .granted
        if wanted, focusTimer == nil {
            lastFocused = INFocusStatusCenter.default.focusStatus.isFocused
            let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkFocus() }
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            focusTimer = timer
        } else if !wanted {
            focusTimer?.invalidate()
            focusTimer = nil
            lastFocused = nil
        }
    }

    private func checkFocus() {
        guard let focused = INFocusStatusCenter.default.focusStatus.isFocused else { return }
        defer { lastFocused = focused }
        guard let lastFocused, lastFocused != focused else { return }
        show(PeekContent(symbol: focused ? "moon.fill" : "moon", title: focused ? "Focus On" : "Focus Off",
                         subtitle: focused ? "Notifications are silenced" : "Notifications are back",
                         tint: focused ? .accent : .neutral, duration: 3))
    }
}
