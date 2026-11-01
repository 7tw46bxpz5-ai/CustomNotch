import SwiftUI
import AppKit
import CoreImage
import CryptoKit

// MARK: - AppleScript

/// Runs AppleScript on one serial queue. The first script for an app shows macOS's Automation prompt
/// and waits for the answer, so nothing here ever runs on the main thread.
enum AppleScript {
    struct Result: @unchecked Sendable {
        let descriptor: NSAppleEventDescriptor?
        let errorNumber: Int?

        var notAuthorized: Bool { errorNumber == -1743 }
    }

    private static let queue = DispatchQueue(label: "CustomNotch.applescript")
    nonisolated(unsafe) private static var compiled: [String: NSAppleScript] = [:]   // only used on `queue`

    /// With `requiring`, the script is skipped unless that app is already running: even compiling a
    /// script that names an app can launch it.
    static func run(_ source: String, requiring bundleID: String? = nil) async -> Result {
        await withCheckedContinuation { continuation in
            queue.async {
                if let bundleID, NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                    return continuation.resume(returning: Result(descriptor: nil, errorNumber: -600))
                }
                let script = compiled[source] ?? NSAppleScript(source: source)
                compiled[source] = script
                var error: NSDictionary?
                let descriptor = script?.executeAndReturnError(&error)
                continuation.resume(returning: Result(descriptor: error == nil ? descriptor : nil,
                                                      errorNumber: error?[NSAppleScript.errorNumber] as? Int))
            }
        }
    }

    /// True if Apple events to `bundleID` are already allowed. Never shows a prompt.
    static func isAuthorized(_ bundleID: String) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
                let status = target.aeDesc.map { AEDeterminePermissionToAutomateTarget($0, typeWildCard, typeWildCard, false) }
                continuation.resume(returning: status == noErr)
            }
        }
    }

    /// Wraps commands so they only run if the app is already open: AppleScript would otherwise launch it.
    static func ifRunning(_ bundleID: String, _ body: String, otherwise: String = "") -> String {
        """
        if application id "\(bundleID)" is running then
            tell application id "\(bundleID)"
                \(body)
            end tell
        end if
        \(otherwise)
        """
    }
}

// MARK: - Now playing

/// Spotify and Apple Music. Track changes arrive as system notifications (no permission needed);
/// AppleScript reads the position and cover and sends play/pause/next/previous.
/// Players are never launched: every script checks that the app is already running.
@MainActor @Observable
final class MusicService {
    enum Player: String, CaseIterable {
        case spotify = "com.spotify.client"
        case music = "com.apple.Music"

        var name: String { self == .spotify ? "Spotify" : "Music" }
    }

    struct Track: Equatable {
        var player: Player
        var id: String
        var title: String
        var artist: String
        var album: String
        var duration: Double        // seconds
    }

    private(set) var track: Track?
    private(set) var isPlaying = false
    private(set) var artwork: NSImage?
    private(set) var backdrop: NSImage?         // blurred cover, for Dark Matte
    private(set) var labelColor: NSColor?       // average cover colour, for the record's label
    private(set) var lyrics: Lyrics?
    private(set) var runningPlayers: Set<Player> = []
    private(set) var notice: TileNotice?

    /// Called whenever the track or play state changes (drives the compact pill).
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let lyricsStore = LyricsStore()
    @ObservationIgnored private let session = URLSession(configuration: .ephemeral)
    @ObservationIgnored private var anchor: (position: Double, date: Date) = (0, Date())
    @ObservationIgnored private var isOpen = false
    @ObservationIgnored private var resync: Timer?
    @ObservationIgnored private var extrasFor: String?
    @ObservationIgnored private var lyricsFor: String?
    @ObservationIgnored private static let ciContext = CIContext()

    init(settings: Settings) {
        self.settings = settings
        runningPlayers = Set(Player.allCases.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.rawValue).isEmpty })

        let center = DistributedNotificationCenter.default()
        for (name, player) in [("com.spotify.client.PlaybackStateChanged", Player.spotify), ("com.apple.Music.playerInfo", .music)] {
            center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                MainActor.assumeIsolated { self?.handle(player, info) }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                MainActor.assumeIsolated { self?.playerLaunchedOrQuit(bundleID, launched: name == NSWorkspace.didLaunchApplicationNotification) }
            }
        }
        // If permission was granted earlier, show what's already playing without asking again.
        Task { await sync(askPermission: false) }
    }

    /// Sample data for snapshots.
    init(preview track: Track, artwork: NSImage?, lyrics: Lyrics?, position: Double, settings: Settings) {
        self.settings = settings
        self.track = track
        self.isPlaying = true
        self.lyrics = lyrics
        runningPlayers = [track.player]
        anchor = (position, .distantFuture)     // frozen
        if let artwork { apply(artwork: artwork) }
    }

    func position(at date: Date) -> Double {
        guard let track else { return 0 }
        let elapsed = isPlaying && anchor.date != .distantFuture ? date.timeIntervalSince(anchor.date) : 0
        return min(max(anchor.position + max(elapsed, 0), 0), track.duration)
    }

    // MARK: Island open / closed

    func islandOpened() {
        isOpen = true
        // Ask for Automation only once there is music to show; an idle player waits for "Show … Here".
        Task { await sync(askPermission: track != nil) }
        // Re-read the position now and then: Music doesn't announce seeks.
        resync?.invalidate()
        resync = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                Task { await self.sync(askPermission: false) }
            }
        }
    }

    /// Lyrics or Spotify covers were switched on or off: apply it to the current song right away.
    func settingsChanged() {
        if !settings.lyricsEnabled { lyrics = nil }
        if track?.player == .spotify && !settings.spotifyCovers {
            artwork = nil
            backdrop = nil
            labelColor = nil
        }
        extrasFor = nil
        lyricsFor = nil
        Task { await loadExtras(askPermission: false) }
        onChange?()
    }

    /// The idle tile's button: reads the running players, asking for permission if needed.
    func connect() {
        Task { await sync(askPermission: true) }
    }

    func islandClosed() {
        isOpen = false
        resync?.invalidate()
        resync = nil
    }

    // MARK: Controls

    func playPause() {
        let position = position(at: Date())
        isPlaying.toggle()
        anchor = (position, Date())
        send("playpause")
        onChange?()
    }

    func next() { send("next track") }
    func previous() { send("previous track") }

    func seek(to fraction: Double) {
        guard let track else { return }
        let seconds = min(max(fraction, 0), 1) * track.duration
        anchor = (seconds, Date())
        send("set player position to \(String(format: "%.2f", seconds))")
    }

    private func send(_ command: String) {
        guard let player = track?.player, runningPlayers.contains(player) else { return }
        Task {
            let result = await AppleScript.run(AppleScript.ifRunning(player.rawValue, command), requiring: player.rawValue)
            if result.notAuthorized { showPermissionNotice(player) }
        }
    }

    // MARK: Notifications

    private func handle(_ player: Player, _ info: [AnyHashable: Any]) {
        runningPlayers.insert(player)
        let state = (info["Player State"] as? String ?? "").lowercased()
        if state == "stopped" || info["Name"] == nil {
            if track?.player == player { clearTrack() }
            return
        }
        let playing = state == "playing"
        // A paused player doesn't take over from one that is playing.
        if !playing, let track, track.player != player, isPlaying { return }

        let title = info["Name"] as? String ?? ""
        let artist = info["Artist"] as? String ?? ""
        let album = info["Album"] as? String ?? ""
        let milliseconds = (info["Duration"] as? NSNumber ?? info["Total Time"] as? NSNumber)?.doubleValue ?? 0
        let id = player == .spotify ? (info["Track ID"] as? String ?? "\(title)|\(artist)") : "\(title)|\(artist)|\(album)"
        let current = position(at: Date())
        let new = Track(player: player, id: id, title: title, artist: artist, album: album, duration: milliseconds / 1000)
        let changed = new.id != track?.id || player != track?.player

        track = new
        isPlaying = playing
        if let seconds = info["Playback Position"] as? NSNumber {
            anchor = (seconds.doubleValue, Date())
        } else {
            anchor = (changed ? 0 : current, Date())
        }
        if changed { resetExtras() }
        Task { await loadExtras(askPermission: false) }
        onChange?()
    }

    private func playerLaunchedOrQuit(_ bundleID: String?, launched: Bool) {
        guard let bundleID, let player = Player(rawValue: bundleID) else { return }
        if launched {
            runningPlayers.insert(player)
        } else {
            runningPlayers.remove(player)
            if track?.player == player { clearTrack() }
        }
    }

    private func clearTrack() {
        track = nil
        isPlaying = false
        resetExtras()
        onChange?()
    }

    private func resetExtras() {
        artwork = nil
        backdrop = nil
        labelColor = nil
        lyrics = nil
        extrasFor = nil
        lyricsFor = nil
    }

    // MARK: AppleScript sync

    /// Reads state and position from the running players. With `askPermission`, macOS may show its
    /// Automation prompt (once per player); without it, players that aren't allowed yet are skipped.
    private func sync(askPermission: Bool) async {
        var players = Player.allCases.filter { runningPlayers.contains($0) }
        if let current = track?.player, let index = players.firstIndex(of: current) {
            players.swapAt(0, index)
        }
        var applied = false
        for player in players {
            if !askPermission, !(await AppleScript.isAuthorized(player.rawValue)) { continue }
            let result = await AppleScript.run(Self.queryScript(player), requiring: player.rawValue)
            if result.notAuthorized { showPermissionNotice(player); continue }
            guard let list = result.descriptor, list.numberOfItems >= 7 else { continue }   // closed or stopped
            let state = list.atIndex(1)?.stringValue ?? ""
            let title = list.atIndex(2)?.stringValue ?? ""
            let artist = list.atIndex(3)?.stringValue ?? ""
            let album = list.atIndex(4)?.stringValue ?? ""
            var duration = list.atIndex(5)?.doubleValue ?? 0
            if player == .spotify { duration /= 1000 }      // Spotify reports milliseconds
            let position = list.atIndex(6)?.doubleValue ?? 0
            let id = player == .spotify ? (list.atIndex(7)?.stringValue ?? title) : "\(title)|\(artist)|\(album)"
            let playing = state == "playing"
            // A paused player never replaces one that is playing, or one already read in this pass.
            if !playing, applied { continue }
            if !playing, isPlaying, let track, track.player != player { continue }

            let new = Track(player: player, id: id, title: title, artist: artist, album: album, duration: duration)
            if new.id != track?.id { resetExtras() }
            track = new
            isPlaying = playing
            anchor = (position, Date())
            notice = nil
            applied = true
            onChange?()
            if playing { break }
        }
        await loadExtras(askPermission: askPermission)
    }

    private static func queryScript(_ player: Player) -> String {
        let idProperty = player == .spotify ? "id of t" : "persistent ID of t"
        return AppleScript.ifRunning(player.rawValue, """
            try
                set s to player state as string
                if s is "stopped" then return {"stopped"}
                set t to current track
                return {s, name of t, artist of t, album of t, duration of t, player position, \(idProperty)}
            end try
            return {"stopped"}
            """, otherwise: "return {\"closed\"}")
    }

    // MARK: Cover and lyrics

    private func loadExtras(askPermission: Bool) async {
        guard let track else { return }
        if extrasFor != track.id {
            let allowed = askPermission ? true : await AppleScript.isAuthorized(track.player.rawValue)
            if allowed {
                extrasFor = track.id
                await loadArtwork(for: track)
            }
        }
        if isOpen, settings.lyricsEnabled, lyricsFor != track.id {
            lyricsFor = track.id
            let found = await lyricsStore.lyrics(title: track.title, artist: track.artist,
                                                 album: track.album, duration: track.duration)
            if self.track?.id == track.id { lyrics = found }
        }
    }

    private func loadArtwork(for track: Track) async {
        var image: NSImage?
        switch track.player {
        case .music:
            let script = AppleScript.ifRunning(track.player.rawValue, """
                try
                    return raw data of artwork 1 of current track
                end try
                """)
            if let data = await AppleScript.run(script, requiring: track.player.rawValue).descriptor?.data, !data.isEmpty {
                image = NSImage(data: data)
            }
        case .spotify:
            // Spotify only offers the cover as a web address; it is loaded only if you turned that on.
            guard settings.spotifyCovers else { break }
            let script = AppleScript.ifRunning(track.player.rawValue, "return artwork url of current track")
            if let string = await AppleScript.run(script, requiring: track.player.rawValue).descriptor?.stringValue,
               let url = URL(string: string), url.scheme == "https", url.host?.hasSuffix(".scdn.co") == true,
               let (data, _) = try? await session.data(from: url) {
                image = NSImage(data: data)
            }
        }
        guard self.track?.id == track.id, let image else { return }
        apply(artwork: image)
        onChange?()
    }

    private func apply(artwork image: NSImage) {
        artwork = image
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let input = CIImage(cgImage: cgImage)
        let scale = 96 / max(input.extent.width, input.extent.height, 1)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Blur a clamped copy and crop it back, so the edges stay opaque (no light frame).
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 9).cropped(to: small.extent)
        if let output = Self.ciContext.createCGImage(blurred, from: small.extent) {
            backdrop = NSImage(cgImage: output, size: small.extent.size)
        }
        let average = small.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: small.extent)])
        var pixel = [UInt8](repeating: 0, count: 4)
        Self.ciContext.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                              format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        labelColor = NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                             blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }

    private func showPermissionNotice(_ player: Player) {
        notice = TileNotice(text: "Allow Custom Notch to control \(player.name) in Privacy & Security → Automation.",
                            settings: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"))
    }
}

// MARK: - Lyrics

struct Lyrics: Codable, Equatable {
    struct Line: Codable, Equatable {
        var time: Double
        var text: String
    }

    var lines: [Line]       // synced lines; empty when only unsynced lyrics exist
    var instrumental: Bool

    /// The line being sung at `position` (index and text), or nil before the first line.
    func line(at position: Double) -> (index: Int, text: String)? {
        var current: Int?
        for (index, line) in lines.enumerated() {
            if line.time <= position + 0.2 { current = index } else { break }
        }
        return current.map { ($0, lines[$0].text) }
    }

    /// Parses LRC text: "[mm:ss.xx] words", possibly with several time tags per line.
    static func parse(_ lrc: String) -> [Line] {
        var result: [Line] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                let parts = tag.split(separator: ":")
                if parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) {
                    times.append(minutes * 60 + seconds)
                }
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            result += times.map { Line(time: $0, text: text) }
        }
        return result.sorted { $0.time < $1.time }
    }
}

/// Synced lyrics from LRCLIB (free, no key), cached on disk. Only title, artist, album and duration
/// are sent. Misses are remembered for a week so the same song isn't asked for again and again.
actor LyricsStore {
    private struct CacheEntry: Codable {
        var lyrics: Lyrics?
        var fetched: Date
    }

    private struct Record: Decodable {
        let duration: Double?
        let instrumental: Bool?
        let syncedLyrics: String?
    }

    private let directory: URL
    private let session = URLSession(configuration: .ephemeral)

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("local.customnotch.CustomNotch/Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func lyrics(title: String, artist: String, album: String, duration: Double) async -> Lyrics? {
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        let key = "\(artist)\n\(title)\n\(album)\n\(Int(duration.rounded()))"
        let file = directory.appendingPathComponent(SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined() + ".json")

        if let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(CacheEntry.self, from: data) {
            if entry.lyrics != nil || Date().timeIntervalSince(entry.fetched) < 7 * 24 * 3600 { return entry.lyrics }
        }
        guard let record = await fetch(title: title, artist: artist, album: album, duration: duration) else {
            return nil      // network problem: don't cache, try again next time
        }
        let lines = record.syncedLyrics.map(Lyrics.parse) ?? []
        let lyrics: Lyrics? = lines.isEmpty && record.instrumental != true ? nil
            : Lyrics(lines: lines, instrumental: record.instrumental ?? false)
        if let data = try? JSONEncoder().encode(CacheEntry(lyrics: lyrics, fetched: Date())) {
            try? data.write(to: file, options: .atomic)
        }
        return lyrics
    }

    /// The best LRCLIB record, an empty record if there is none, or nil if LRCLIB couldn't be reached.
    private func fetch(title: String, artist: String, album: String, duration: Double) async -> Record? {
        var exact = URLComponents(string: "https://lrclib.net/api/get")!
        exact.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist),
                            URLQueryItem(name: "album_name", value: album),
                            URLQueryItem(name: "duration", value: String(Int(duration.rounded())))]
        switch await get(exact.url!) {
        case .found(let data):
            if let record = try? JSONDecoder().decode(Record.self, from: data), record.syncedLyrics != nil { return record }
        case .missing: break
        case .failed: return nil
        }
        // Fall back to a search, picking a synced result of about the same length.
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        switch await get(search.url!) {
        case .found(let data):
            let records = (try? JSONDecoder().decode([Record].self, from: data)) ?? []
            return records.first { $0.syncedLyrics != nil && abs(($0.duration ?? duration) - duration) < 4 }
                ?? Record(duration: nil, instrumental: nil, syncedLyrics: nil)
        case .missing: return Record(duration: nil, instrumental: nil, syncedLyrics: nil)
        case .failed: return nil
        }
    }

    private enum Response { case found(Data), missing, failed }

    private func get(_ url: URL) async -> Response {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("CustomNotch/0.1 (local macOS app)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .failed }
        switch status {
        case 200: return .found(data)
        case 404: return .missing
        default: return .failed
        }
    }
}

// MARK: - Tile: Music

struct MusicTile: View {
    let music: MusicService
    let cells: Int
    let palette: Palette

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                // Dark Matte: the blurred cover fills the tile. It is blurred once, with opaque edges,
                // and the tile clips it, so no light frame appears. White Matte keeps the plain tile.
                if palette.isDark, music.track != nil, let backdrop = music.backdrop {
                    Image(nsImage: backdrop)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .overlay(Color.black.opacity(0.45))
                        .clipped()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let track = music.track {
            switch cells {
            case 1: small
            case 2: layout(track, cover: 52, column: 66, top: 17, large: false)
            default: layout(track, cover: 69, column: 122, top: 9.5, large: true)
            }
        } else if let notice = music.notice {
            NoticeView(notice: notice, palette: palette, open: { NSWorkspace.shared.open($0) }).padding(10)
        } else {
            idle
        }
    }

    private var label: Color { music.labelColor.map(Color.init(nsColor:)) ?? palette.secondary }

    /// Cover and vinyl on the left, text and controls on the right (sizes from the reference screenshot).
    private func layout(_ track: MusicService.Track, cover: CGFloat, column: CGFloat, top: CGFloat, large: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VinylCover(artwork: music.artwork, label: label, playing: music.isPlaying, size: cover, palette: palette)
                .padding(.top, top)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 0) {
                titleRow(track, size: large ? 11 : 10.5, withArtist: large)
                TimelineView(.animation(minimumInterval: 0.5, paused: !music.isPlaying)) { context in
                    let position = music.position(at: context.date)
                    VStack(alignment: .leading, spacing: 0) {
                        secondRow(track, position: position, size: large ? 10 : 9.5)
                        ProgressBar(fraction: track.duration > 0 ? position / track.duration : 0,
                                    palette: palette, onSeek: music.seek)
                            .frame(height: 3.2)
                            .padding(.top, large ? 7 : 6)
                        if large {
                            HStack {
                                Text(Self.time(position))
                                Spacer()
                                Text(Self.time(track.duration))
                            }
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(palette.secondary)
                            .padding(.top, 7.6)
                        }
                    }
                }
                controls(size: large ? 12.5 : 11.5, spacing: large ? 16 : 11)
                    .padding(.top, large ? 3.5 : 8)
            }
            .frame(width: column, alignment: .leading)
            .padding(.top, large ? 9 : 15)
        }
        .padding(.horizontal, 9)
    }

    private var small: some View {
        VStack(spacing: 7) {
            VinylCover(artwork: music.artwork, label: label, playing: music.isPlaying, size: 42, palette: palette)
                .offset(x: -7)      // centre cover and record together
            controls(size: 10, spacing: 9)
        }
        .padding(.top, 9)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func titleRow(_ track: MusicService.Track, size: CGFloat, withArtist: Bool) -> some View {
        // While lyrics take the second row, the artist moves up next to the title (if there is room).
        if hasSyncedLyrics && withArtist {
            (Text(track.title).foregroundColor(palette.text)
                + Text("  \(track.artist)").font(.system(size: size - 2, weight: .regular)).foregroundColor(palette.secondary))
                .font(.system(size: size, weight: .semibold))
                .lineLimit(1)
        } else {
            Text(track.title)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(palette.text)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func secondRow(_ track: MusicService.Track, position: Double, size: CGFloat) -> some View {
        if hasSyncedLyrics, let line = music.lyrics?.line(at: position) {
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .id(line.index)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: line.index)
                .padding(.top, 1)
        } else {
            Text(hasSyncedLyrics ? "♪" : track.artist)
                .font(.system(size: size))
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                .padding(.top, 1)
        }
    }

    private var hasSyncedLyrics: Bool { !(music.lyrics?.lines.isEmpty ?? true) }

    private func controls(size: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            Button(action: music.previous) { Image(systemName: "backward.fill") }
            Button(action: music.playPause) {
                Image(systemName: music.isPlaying ? "pause.fill" : "play.fill").frame(width: size + 2)
            }
            Button(action: music.next) { Image(systemName: "forward.fill") }
        }
        .font(.system(size: size))
        .foregroundStyle(palette.text)
        .buttonStyle(.plain)
    }

    private var idle: some View {
        let open = music.runningPlayers.map(\.name).sorted()
        return VStack(alignment: .leading, spacing: 3) {
            Image(systemName: "music.note")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.secondary)
                .padding(.bottom, 2)
            Text("Nothing playing").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.text)
            Text(open.isEmpty ? "Open Spotify or Music to see it here." : "Play something in \(open.joined(separator: " or ")).")
                .font(.system(size: 10.5))
                .foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !open.isEmpty && cells > 1 {
                Button(action: music.connect) {
                    Text("Show \(open.joined(separator: " & ")) Here")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(palette.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(10)
    }

    static func time(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The cover as a small vinyl record: the disc slides out from behind the cover while playing.
struct VinylCover: View {
    let artwork: NSImage?
    let label: Color
    let playing: Bool
    let size: CGFloat
    let palette: Palette

    var body: some View {
        let disc = size * 0.9
        let shift = size * (playing ? 0.416 : 0.24)
        ZStack(alignment: .leading) {
            VinylDisc(label: label)
                .frame(width: disc, height: disc)
                .offset(x: (size - disc) / 2 + shift)
            cover
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.115, style: .continuous))
        }
        .frame(width: size, height: size, alignment: .leading)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: playing)
    }

    @ViewBuilder
    private var cover: some View {
        if let artwork {
            Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                palette.controlActive
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.32, weight: .medium))
                    .foregroundStyle(palette.secondary)
            }
        }
    }
}

/// A flat black record: grooves, a lighter wedge, a label in the cover's colour.
struct VinylDisc: View {
    let label: Color

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            func circle(_ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            }
            let black = Color(hex: 0x141416)
            context.fill(circle(radius), with: .color(black))
            var wedge = Path()
            wedge.move(to: center)
            wedge.addArc(center: center, radius: radius * 0.96, startAngle: .degrees(12), endAngle: .degrees(58), clockwise: false)
            wedge.closeSubpath()
            context.fill(wedge, with: .color(.white.opacity(0.13)))
            for fraction in [0.88, 0.75, 0.62] {
                context.stroke(circle(radius * fraction), with: .color(.white.opacity(0.08)), lineWidth: 0.6)
            }
            context.fill(circle(radius * 0.3), with: .color(label))
            context.fill(circle(radius * 0.045), with: .color(black))
        }
    }
}

/// Grey track and fill, as in the reference; click anywhere on it to seek.
struct ProgressBar: View {
    let fraction: Double
    let palette: Palette
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(palette.secondary.opacity(palette.isDark ? 0.2 : 0.14))
                Capsule().fill(palette.secondary.opacity(palette.isDark ? 0.7 : 0.38))
                    .frame(width: max(3.5, width * min(max(fraction, 0), 1)))
            }
            .contentShape(Rectangle().inset(by: -6))
            .onTapGesture(count: 1, coordinateSpace: .local) { location in onSeek(location.x / width) }
        }
    }
}
