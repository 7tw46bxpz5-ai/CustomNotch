import SwiftUI

// MARK: - Themes

enum ThemeName: String, CaseIterable {
    case automatic, darkMatte, light

    /// The saved choice; "liquidGlass" is the light theme from before the island became always black.
    init(saved: String?) {
        self = saved == "liquidGlass" ? .light : ThemeName(rawValue: saved ?? "") ?? .automatic
    }

    var title: String {
        switch self {
        case .automatic: return "Automatic (Dark or Light, like macOS)"
        case .darkMatte: return "Dark"
        case .light: return "Light"
        }
    }
}

/// The island itself is always black, like the notch; the theme colours the tiles and buttons on it.
/// Anything drawn straight on the black (peeks, the pill, headings outside tiles) uses `darkMatte`.
/// The accent is the only colour for "active" or "new"; caution / warning / critical are muted and
/// reserved for warnings.
struct Palette {
    let isDark: Bool            // dark tiles and buttons
    let tile: Color
    let control: Color          // buttons inside tiles
    let controlActive: Color    // a button whose feature is on
    let text: Color
    let secondary: Color
    let accent: Color
    let caution: Color
    let warning: Color
    let critical: Color

    var colorScheme: ColorScheme { isDark ? .dark : .light }

    // Apple's dark greys (systemGray6/5/4) for tiles and buttons.
    static let darkMatte = Palette(
        isDark: true, tile: Color(hex: 0x1C1C1E),
        control: Color(hex: 0x2C2C2E), controlActive: Color(hex: 0x3A3A3C),
        text: Color(hex: 0xF5F5F7), secondary: Color(hex: 0x98989D), accent: Color(hex: 0x935B29),
        caution: Color(hex: 0xD6BC6E), warning: Color(hex: 0xD69A6A), critical: Color(hex: 0xD47F7F))

    // Light mode: solid light tiles and buttons with Apple's light label colours; an active button is
    // tinted with the accent.
    static let light = Palette(
        isDark: false, tile: Color(hex: 0xEDEDF0),
        control: Color(hex: 0xDCDCE1), controlActive: Color(hex: 0xDBD0C8),
        text: Color(hex: 0x1D1D1F), secondary: Color(hex: 0x6E6E73), accent: Color(hex: 0x935B29),
        caution: Color(hex: 0xB28E2E), warning: Color(hex: 0xBC7238), critical: Color(hex: 0xB95656))
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

// MARK: - Tiles

enum TileKind: String, Codable, CaseIterable, Identifiable {
    case music, weather, cards, controls, calendar, timer, chess

    var id: String { rawValue }

    /// Saved layouts from before the cards had "messages" in this place.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let kind = raw == "messages" ? .cards : TileKind(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown tile \(raw)"))
        }
        self = kind
    }

    var title: String {
        switch self {
        case .music: return "Music"
        case .weather: return "Weather"
        case .cards: return "Calendar · Batteries · Slack"
        case .controls: return "Quick Controls"
        case .calendar: return "Next Event"
        case .timer: return "Focus Timer"
        case .chess: return "Chess"
        }
    }
}

struct TileConfig: Codable, Equatable, Identifiable {
    var kind: TileKind
    var visible: Bool
    var cells: Int          // 1, 2 or 3

    var id: TileKind { kind }

    static let defaults: [TileConfig] = [
        TileConfig(kind: .music, visible: true, cells: 3),
        TileConfig(kind: .weather, visible: true, cells: 2),
        TileConfig(kind: .cards, visible: true, cells: 3),
        TileConfig(kind: .controls, visible: true, cells: 2),
        TileConfig(kind: .calendar, visible: false, cells: 2),
        TileConfig(kind: .timer, visible: false, cells: 2),
        TileConfig(kind: .chess, visible: true, cells: 2),
    ]
}

/// Edits return a new list, so the island can resize its window before applying them.
extension Array where Element == TileConfig {
    func setting(_ kind: TileKind, visible: Bool) -> [TileConfig] {
        map { $0.kind == kind ? TileConfig(kind: kind, visible: visible, cells: $0.cells) : $0 }
    }

    func setting(_ kind: TileKind, cells: Int) -> [TileConfig] {
        map { $0.kind == kind ? TileConfig(kind: kind, visible: $0.visible, cells: Swift.min(Swift.max(cells, 1), 3)) : $0 }
    }

    /// Swaps the tile with its visible neighbour on the left (-1) or right (+1).
    func moving(_ kind: TileKind, by offset: Int) -> [TileConfig] {
        guard let index = firstIndex(where: { $0.kind == kind }) else { return self }
        let candidates = indices.filter { self[$0].visible || $0 == index }
        guard let position = candidates.firstIndex(of: index),
              candidates.indices.contains(position + offset) else { return self }
        var tiles = self
        tiles.swapAt(index, candidates[position + offset])
        return tiles
    }

    func canMove(_ kind: TileKind, by offset: Int) -> Bool { moving(kind, by: offset) != self }
}

// MARK: - Teleprompter

enum PrompterTextSize: String, CaseIterable {
    case small, medium, large

    var points: CGFloat {
        switch self {
        case .small: return 18
        case .medium: return 21
        case .large: return 25
        }
    }

    var title: String { rawValue.capitalized }
}

/// Narrow keeps your eyes closest to the camera; wide fits more words on a line.
enum PrompterWidth: String, CaseIterable {
    case narrow, medium, wide

    var points: CGFloat {
        switch self {
        case .narrow: return 400
        case .medium: return 480
        case .wide: return 580
        }
    }

    var title: String { rawValue.capitalized }
}

// MARK: - Weather location

struct WeatherLocation: Codable, Equatable {
    var name: String
    var country: String
    var latitude: Double
    var longitude: Double
}

// MARK: - Settings

/// Everything the user can change, persisted in UserDefaults.
@MainActor @Observable
final class Settings {
    static let shared = Settings()

    @ObservationIgnored private let defaults = UserDefaults.standard

    var theme: ThemeName {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    /// macOS is in dark mode (kept up to date by the app; not saved).
    var systemDark = false

    /// The colours of tiles and buttons: Automatic picks Dark in dark mode and Light in light mode.
    var palette: Palette {
        switch theme {
        case .darkMatte: return .darkMatte
        case .light: return .light
        case .automatic: return systemDark ? .darkMatte : .light
        }
    }

    /// All tiles in display order, hidden ones included.
    var tiles: [TileConfig] {
        didSet { save(tiles, forKey: Keys.tiles) }
    }

    var weatherLocation: WeatherLocation? {
        didSet { save(weatherLocation, forKey: Keys.weatherLocation) }
    }

    /// Show the black pill with the cover while music plays.
    var musicInNotch: Bool {
        didSet { defaults.set(musicInNotch, forKey: Keys.musicInNotch) }
    }

    /// Fetch synced lyrics from LRCLIB.
    var lyricsEnabled: Bool {
        didSet { defaults.set(lyricsEnabled, forKey: Keys.lyricsEnabled) }
    }

    /// Load Spotify covers from Spotify's image server (off by default: it is an extra destination).
    var spotifyCovers: Bool {
        didSet { defaults.set(spotifyCovers, forKey: Keys.spotifyCovers) }
    }

    // Peeks. Focus is off until you allow the Focus permission from the menu.
    var peekCharger: Bool { didSet { defaults.set(peekCharger, forKey: Keys.peekCharger) } }
    var peekBattery: Bool { didSet { defaults.set(peekBattery, forKey: Keys.peekBattery) } }
    var peekFocus: Bool { didSet { defaults.set(peekFocus, forKey: Keys.peekFocus) } }

    /// Read AirPods batteries from their Bluetooth broadcast (asks for the Bluetooth permission once).
    var airpodsBatteries: Bool { didSet { defaults.set(airpodsBatteries, forKey: Keys.airpodsBatteries) } }

    /// Claude Code: show what it's doing in the pill, and answer its permission requests from the notch.
    var claudeInNotch: Bool { didSet { defaults.set(claudeInNotch, forKey: Keys.claudeInNotch) } }
    var claudeApprovals: Bool { didSet { defaults.set(claudeApprovals, forKey: Keys.claudeApprovals) } }

    /// Teleprompter: reading speed in words per minute, text size and column width.
    var prompterWPM: Int { didSet { defaults.set(prompterWPM, forKey: Keys.prompterWPM) } }
    /// The text follows your voice (microphone, recognized on this Mac); otherwise it scrolls at `prompterWPM`.
    var prompterFollowVoice: Bool { didSet { defaults.set(prompterFollowVoice, forKey: Keys.prompterFollowVoice) } }
    var prompterTextSize: PrompterTextSize { didSet { defaults.set(prompterTextSize.rawValue, forKey: Keys.prompterTextSize) } }
    var prompterWidth: PrompterWidth { didSet { defaults.set(prompterWidth.rawValue, forKey: Keys.prompterWidth) } }

    /// Which Claude model plays chess against you.
    var chessOpponent: ChessOpponent { didSet { defaults.set(chessOpponent.rawValue, forKey: Keys.chessOpponent) } }

    private init() {
        theme = ThemeName(saved: defaults.string(forKey: Keys.theme))
        weatherLocation = Self.load(WeatherLocation.self, from: defaults, key: Keys.weatherLocation)
        defaults.register(defaults: [Keys.musicInNotch: true, Keys.lyricsEnabled: true, Keys.spotifyCovers: false,
                                     Keys.peekCharger: true, Keys.peekBattery: true,
                                     Keys.peekFocus: false, Keys.claudeInNotch: true, Keys.claudeApprovals: true,
                                     Keys.prompterWPM: 130, Keys.prompterFollowVoice: true])
        claudeInNotch = defaults.bool(forKey: Keys.claudeInNotch)
        airpodsBatteries = defaults.bool(forKey: Keys.airpodsBatteries)
        claudeApprovals = defaults.bool(forKey: Keys.claudeApprovals)
        peekCharger = defaults.bool(forKey: Keys.peekCharger)
        peekBattery = defaults.bool(forKey: Keys.peekBattery)
        peekFocus = defaults.bool(forKey: Keys.peekFocus)
        musicInNotch = defaults.bool(forKey: Keys.musicInNotch)
        lyricsEnabled = defaults.bool(forKey: Keys.lyricsEnabled)
        spotifyCovers = defaults.bool(forKey: Keys.spotifyCovers)
        prompterWPM = min(max(defaults.integer(forKey: Keys.prompterWPM), Teleprompter.speeds.lowerBound),
                          Teleprompter.speeds.upperBound)
        prompterFollowVoice = defaults.bool(forKey: Keys.prompterFollowVoice)
        prompterTextSize = PrompterTextSize(rawValue: defaults.string(forKey: Keys.prompterTextSize) ?? "") ?? .medium
        prompterWidth = PrompterWidth(rawValue: defaults.string(forKey: Keys.prompterWidth) ?? "") ?? .medium
        chessOpponent = ChessOpponent(rawValue: defaults.string(forKey: Keys.chessOpponent) ?? "") ?? .sonnet
        // Keep the saved order and add any tile kinds introduced since.
        var tiles = Self.load([TileConfig].self, from: defaults, key: Keys.tiles) ?? TileConfig.defaults
        for config in TileConfig.defaults where !tiles.contains(where: { $0.kind == config.kind }) {
            tiles.append(config)
        }
        self.tiles = tiles
    }

    // Stored as JSON strings, so they can be read and written with `defaults` too.
    private func save<T: Encodable>(_ value: T?, forKey key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let string = defaults.string(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: Data(string.utf8))
    }

    private enum Keys {
        static let theme = "appearance"      // new key: everyone starts on Automatic
        static let tiles = "tiles"
        static let weatherLocation = "weatherLocation"
        static let musicInNotch = "musicInNotch"
        static let lyricsEnabled = "lyricsEnabled"
        static let spotifyCovers = "spotifyCovers"
        static let peekCharger = "peekCharger"
        static let peekBattery = "peekBattery"
        static let peekFocus = "peekFocus"
        static let claudeInNotch = "claudeInNotch"
        static let airpodsBatteries = "airpodsBatteries"
        static let claudeApprovals = "claudeApprovals"
        static let prompterWPM = "prompterWPM"
        static let prompterFollowVoice = "prompterFollowVoice"
        static let prompterTextSize = "prompterTextSize"
        static let prompterWidth = "prompterWidth"
        static let chessOpponent = "chessOpponent"
    }
}
