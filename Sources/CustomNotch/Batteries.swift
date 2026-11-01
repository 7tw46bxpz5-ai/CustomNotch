import AppKit
import CoreBluetooth
import IOKit
import IOKit.ps

/// Battery levels of this Mac and the Apple devices it can see, for the batteries card.
/// - This Mac, and Bluetooth devices macOS reports a level for while they're connected: no permission.
/// - AirPods that macOS doesn't report (e.g. AirPods Max): optionally read from the battery message they
///   broadcast over Bluetooth. That needs the Bluetooth permission, asked only when you turn it on. Only
///   models paired with this Mac and close by are shown, so a stranger's AirPods don't appear.
/// - iPhone, iPad and Apple Watch: macOS offers apps no way to read them.
@MainActor @Observable
final class BatteryService {
    struct Device: Identifiable, Equatable {
        enum Kind: Equatable { case mac, buds, headphones, keyboard, mouse, trackpad, other }

        var id: String
        var name: String
        var kind: Kind
        var level: Int?             // the main value (for buds: the lower of the two)
        var caseLevel: Int?
        var charging = false

        var symbol: String {
            switch kind {
            case .mac: return "laptopcomputer"
            case .buds: return name.localizedCaseInsensitiveContains("pro") ? "airpodspro" : "airpods"
            case .headphones: return name.localizedCaseInsensitiveContains("max") ? "airpodsmax" : "headphones"
            case .keyboard: return "keyboard"
            case .mouse: return "magicmouse"
            case .trackpad: return "hand.point.up.left"
            case .other: return "battery.75percent"
            }
        }
    }

    enum Bluetooth: Equatable { case off, waiting, on, denied, unavailable }

    private(set) var devices: [Device] = []
    private(set) var bluetooth: Bluetooth = .off

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let isPreview: Bool
    @ObservationIgnored private var scanner: AirPodsScanner?
    @ObservationIgnored private var broadcast: [UInt16: (device: Device, seen: Date)] = [:]
    @ObservationIgnored private var reported: [Device] = []          // from macOS (system_profiler)
    @ObservationIgnored private var paired: [UInt16: String] = [:]    // product ID → your device's name
    @ObservationIgnored private var lastReport = Date.distantPast
    @ObservationIgnored private var stopWork: DispatchWorkItem?

    init(settings: Settings? = nil, preview: [Device]? = nil) {
        self.settings = settings ?? .shared
        isPreview = preview != nil
        if let preview { devices = preview }
    }

    // MARK: Island

    func islandOpened() {
        guard !isPreview else { return }
        rebuild()
        if Date().timeIntervalSince(lastReport) > 60 { readReported() }
        if settings.airpodsBatteries { startScan() }
    }

    func islandClosed() {
        scanner?.stop()
        stopWork?.cancel()
    }

    /// Turns on reading AirPods over Bluetooth (macOS asks for the Bluetooth permission the first time).
    func enableBluetooth() {
        settings.airpodsBatteries = true
        startScan()
    }

    func disableBluetooth() {
        settings.airpodsBatteries = false
        scanner?.stop()
        scanner = nil
        broadcast = [:]
        bluetooth = .off
        rebuild()
    }

    func openBluetoothSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
    }

    // MARK: Building the list

    private func rebuild() {
        var list: [Device] = []
        let mac = PeekSources.readBattery()
        if let percent = mac.percent {
            list.append(Device(id: "mac", name: "Mac", kind: .mac, level: percent, charging: mac.charging))
        }
        // Prefer what macOS reports; add broadcasts (seen in the last 10 minutes) for models it doesn't.
        list += reported
        let fresh = broadcast.values.filter { Date().timeIntervalSince($0.seen) < 600 }.map(\.device)
        list += fresh.filter { item in !reported.contains { $0.name == item.name } }
        list += Self.accessories().filter { item in !list.contains { $0.name == item.name } }
        devices = list
    }

    // MARK: What macOS reports (no permission)

    private func readReported() {
        lastReport = Date()
        Task.detached(priority: .utility) {
            let (devices, paired) = Self.systemProfiler()
            await MainActor.run {
                self.reported = devices
                self.paired = paired
                self.rebuild()
            }
        }
    }

    /// Connected Bluetooth devices with a battery level, and the product IDs of every paired Apple audio device.
    nonisolated static func systemProfiler() -> ([Device], [UInt16: String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return ([], [:]) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let section = (root["SPBluetoothDataType"] as? [[String: Any]])?.first else { return ([], [:]) }

        func level(_ value: Any?) -> Int? {
            guard let text = value as? String else { return nil }
            return Int(text.filter(\.isNumber))
        }
        var devices: [Device] = []
        var paired: [UInt16: String] = [:]
        for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
            for entry in section[key] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let product = (info["device_productID"] as? String).flatMap { UInt16($0.dropFirst(2), radix: 16) }
                    let minor = info["device_minorType"] as? String ?? ""
                    if let product, minor == "Headphones", paired[product] == nil || connected,
                       !name.localizedCaseInsensitiveContains("Find My") {
                        paired[product] = name
                    }
                    // Only connected devices: other entries are old values (and can be someone else's).
                    guard connected else { continue }
                    let left = level(info["device_batteryLevelLeft"]), right = level(info["device_batteryLevelRight"])
                    let main = level(info["device_batteryLevelMain"])
                    let buds = [left, right].compactMap { $0 }.min()
                    guard let value = main ?? buds else { continue }
                    let kind: Device.Kind = minor == "Keyboard" ? .keyboard : minor == "Mouse" ? .mouse
                        : minor == "Headphones" ? (buds != nil ? .buds : .headphones) : .other
                    devices.append(Device(id: "bt-\(name)", name: name, kind: kind, level: value,
                                          caseLevel: level(info["device_batteryLevelCase"])))
                }
            }
        }
        return (devices, paired)
    }

    /// Magic Keyboard, Mouse and Trackpad report their level to macOS directly.
    nonisolated static func accessories() -> [Device] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [Device] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let percent = property("BatteryPercent") as? Int, let name = property("Product") as? String else { continue }
            let lower = name.lowercased()
            let kind: Device.Kind = lower.contains("keyboard") ? .keyboard : lower.contains("mouse") ? .mouse
                : lower.contains("trackpad") ? .trackpad : .other
            devices.append(Device(id: "hid-\(name)", name: name, kind: kind, level: percent))
        }
        return devices
    }

    // MARK: AirPods over Bluetooth (with permission)

    private func startScan() {
        if scanner == nil {
            bluetooth = .waiting
            scanner = AirPodsScanner(
                onState: { [weak self] state in MainActor.assumeIsolated { self?.bluetoothChanged(state) } },
                onAdvertisement: { [weak self] data, rssi in MainActor.assumeIsolated { self?.received(data, rssi: rssi) } })
        }
        scanner?.start()
        // Short bursts only: scanning while the island is open, for at most 15 seconds.
        stopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scanner?.stop() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    private func bluetoothChanged(_ state: CBManagerState) {
        switch state {
        case .poweredOn: bluetooth = .on
        case .unauthorized: bluetooth = .denied
        case .poweredOff, .unsupported: bluetooth = .unavailable
        default: bluetooth = .waiting
        }
    }

    private func received(_ data: Data, rssi: Int) {
        guard rssi > -70, let message = Self.parseProximity(data) else { return }   // only devices close by
        // Only models paired with this Mac (if macOS told us which), named after your device.
        guard paired.isEmpty || paired[message.model] != nil, let info = Self.models[message.model] else { return }
        let name = paired[message.model] ?? info.name
        let level = info.single ? [message.left, message.right].compactMap { $0 }.max()
                                : [message.left, message.right].compactMap { $0 }.min()
        guard let level else { return }
        let device = Device(id: "ble-\(message.model)", name: name, kind: info.single ? .headphones : .buds,
                            level: level, caseLevel: info.single ? nil : message.caseLevel, charging: message.charging)
        let changed = broadcast[message.model]?.device != device
        broadcast[message.model] = (device, Date())
        if changed { rebuild() }
    }

    struct Proximity: Equatable {
        var model: UInt16
        var left: Int?
        var right: Int?
        var caseLevel: Int?
        var charging: Bool
    }

    /// Apple's "proximity pairing" broadcast (manufacturer data, company 0x004C, message type 0x07). Layout as
    /// documented by open-source projects (OpenPods, LibrePods): byte 3–4 model, 5 status, 6 the two buds'
    /// levels (one per half-byte, in tens of percent, 15 = unknown), 7 charging flags and the case level.
    nonisolated static func parseProximity(_ data: Data) -> Proximity? {
        let bytes = [UInt8](data)
        guard bytes.count >= 11, bytes[0] == 0x4C, bytes[1] == 0x00 else { return nil }
        let p = Array(bytes.dropFirst(2))
        guard p[0] == 0x07, p[1] >= 0x09 else { return nil }
        let model = UInt16(p[3]) | UInt16(p[4]) << 8
        let flipped = (p[5] & 0x20) == 0
        let high = Int(p[6] >> 4), low = Int(p[6] & 0x0F)
        let charge = Int(p[7] >> 4)
        func percent(_ value: Int) -> Int? { value <= 10 ? value * 10 : nil }
        return Proximity(model: model,
                         left: percent(flipped ? high : low), right: percent(flipped ? low : high),
                         caseLevel: percent(Int(p[7] & 0x0F)),
                         charging: charge & 0b011 != 0)
    }

    /// Product IDs of Apple and Beats audio devices that broadcast their battery. `single`: one battery.
    static let models: [UInt16: (name: String, single: Bool)] = [
        0x2002: ("AirPods", false), 0x200F: ("AirPods", false), 0x2013: ("AirPods", false),
        0x2019: ("AirPods 4", false), 0x201B: ("AirPods 4", false),
        0x200E: ("AirPods Pro", false), 0x2014: ("AirPods Pro", false), 0x2024: ("AirPods Pro", false),
        0x2027: ("AirPods Pro", false),
        0x200A: ("AirPods Max", true), 0x201F: ("AirPods Max", true),
        0x2012: ("Beats Fit Pro", false), 0x2016: ("Beats Studio Buds+", false), 0x2011: ("Beats Studio Buds", false),
        0x200B: ("Powerbeats Pro", false), 0x2009: ("Beats Studio 3", true), 0x2017: ("Beats Studio Pro", true),
    ]
}

/// Listens for Bluetooth broadcasts while asked to; the first use triggers macOS's Bluetooth permission.
final class AirPodsScanner: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager?
    private var wanted = false
    private let onState: (CBManagerState) -> Void
    private let onAdvertisement: (Data, Int) -> Void

    init(onState: @escaping (CBManagerState) -> Void, onAdvertisement: @escaping (Data, Int) -> Void) {
        self.onState = onState
        self.onAdvertisement = onAdvertisement
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func start() {
        wanted = true
        if let central, central.state == .poweredOn, !central.isScanning {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    func stop() {
        wanted = false
        if let central, central.isScanning { central.stopScan() }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onState(central.state)
        if central.state == .poweredOn && wanted { start() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        onAdvertisement(data, RSSI.intValue)
    }
}
