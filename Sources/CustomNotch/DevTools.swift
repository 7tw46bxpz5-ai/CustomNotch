import AppKit
import AVFoundation
import ServiceManagement
import Speech
import Intents
import SwiftUI

/// Developer aids, started from the command line. None of them is reachable from the menu.
@MainActor
enum DevTools {
    /// Handles a developer flag and quits; returns false for a normal launch.
    static func handleLaunchArguments() -> Bool {
        // Development aid: `CustomNotch -snapshot <folder>` renders every state to PNG files and quits.
        if let folder = UserDefaults.standard.string(forKey: "snapshot") {
            Snapshot.render(to: URL(fileURLWithPath: folder))
            exit(0)
        }

        // Development aid: `CustomNotch -chessPerft YES` counts the move generator's positions against the
        // published perft numbers and quits.
        if UserDefaults.standard.bool(forKey: "chessPerft") {
            let cases: [(String, String, Int, Int)] = [
                ("start", ChessPosition.startFEN, 4, 197_281),
                ("kiwipete", "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", 3, 97_862),
                ("position 3", "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", 4, 43_238),
                ("position 4", "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", 3, 9_467),
                ("position 5", "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", 3, 62_379),
            ]
            var failed = false
            for (name, fen, depth, expected) in cases {
                let count = ChessPosition(fen: fen)!.perft(depth)
                failed = failed || count != expected
                print("\(count == expected ? "OK  " : "FAIL") \(name) depth \(depth): \(count) (expected \(expected))")
            }
            exit(failed ? 1 : 0)
        }

        // Development aid: `CustomNotch -chessMove "<moves in UCI, space-separated>"` asks Claude (the chosen
        // opponent) for the next move through the same code the game uses, prints it and quits.
        if let list = UserDefaults.standard.string(forKey: "chessMove") {
            var position = ChessPosition.start
            var history: [String] = []
            for move in list.split(separator: " ").compactMap({ ChessMove(uci: String($0)) }) {
                history.append(position.san(move))
                position = position.applying(move)
            }
            let model = Settings.shared.chessOpponent.model
            Task { @MainActor in
                let start = Date()
                switch await ClaudeChessPlayer.chooseMove(position: position, history: history, model: model) {
                case .success(let choice):
                    print("\(model): \(position.san(choice.move)) (\(choice.move.uci)) in \(String(format: "%.1f", Date().timeIntervalSince(start))) s\(choice.note.map { " · \($0)" } ?? "")")
                    exit(0)
                case .failure(let failure):
                    print("failed: \(failure.message)")
                    exit(1)
                }
            }
            return true
        }

        // `CustomNotch -loginStatus YES` prints the Launch at Login state; `-unregisterLogin YES` turns it off
        // (used by scripts/uninstall.sh). Both quit afterwards.
        if UserDefaults.standard.bool(forKey: "loginStatus") || UserDefaults.standard.bool(forKey: "unregisterLogin") {
            let service = SMAppService.mainApp
            if UserDefaults.standard.bool(forKey: "unregisterLogin"), service.status != .notRegistered {
                try? service.unregister()
            }
            let names = [SMAppService.Status.notRegistered: "off", .enabled: "on", .requiresApproval: "waiting for approval",
                         .notFound: "off (not found)"]
            print("Launch at Login: \(names[service.status] ?? "unknown")")
            exit(0)
        }

        // Development aid: `CustomNotch -appearanceTest YES` switches the app's own appearance (not macOS's)
        // between dark and light, prints what the theme watcher saw each time, and quits.
        if UserDefaults.standard.bool(forKey: "appearanceTest") {
            let settings = Settings.shared
            let watcher = AppearanceWatcher(settings: settings)
            print("start: macOS \(AppearanceWatcher.systemIsDark ? "dark" : "light"), systemDark \(settings.systemDark)")
            for name in [NSAppearance.Name.darkAqua, .aqua, .darkAqua, .aqua] {
                NSApp.appearance = NSAppearance(named: name)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                print("app \(name.rawValue) → systemDark \(settings.systemDark)")
            }
            NSApp.appearance = nil
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            print("back to macOS → systemDark \(settings.systemDark)")
            withExtendedLifetime(watcher) {}
            exit(0)
        }

        // Development aid: `CustomNotch -prompterLayers <file.png>` draws the teleprompter's Core Animation text
        // (sample script, part-way through line 1) to a PNG and quits. Core Animation leaves out the fade mask here.
        if let path = UserDefaults.standard.string(forKey: "prompterLayers") {
            let layout = PrompterLayout(settings: .shared)
            let lines = Teleprompter.layout(Teleprompter.sampleScript, font: layout.font, width: layout.textWidth)
            let view = PrompterScrollView()
            view.frame = NSRect(x: 0, y: 0, width: layout.width, height: layout.areaHeight)
            view.show(lines: lines, layout: layout, text: .white, secondary: .gray, mask: PrompterView.maskStops(layout))
            view.apply(PrompterMotion(from: 1.5, to: 1.5, duration: 0))
            view.mark(spoken: 9)            // following your voice: the first nine words have been said
            view.layout()
            let scale = 2
            if let layer = view.layer, let context = CGContext(
                data: nil, width: Int(layout.width) * scale, height: Int(layout.areaHeight) * scale, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.setFillColor(NSColor.black.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
                context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                layer.render(in: context)
                if let image = context.makeImage() {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path))
                }
            }
            exit(0)
        }

        // Development aid: `CustomNotch -prompterListen <script.txt> -audio <speech.aiff>` plays a recording, in real
        // time, into the same recognizer and tracker the teleprompter uses (no microphone), prints where it thinks
        // the speaker is, and quits.
        if let scriptPath = UserDefaults.standard.string(forKey: "prompterListen"),
           let audioPath = UserDefaults.standard.string(forKey: "audio") {
            Task { @MainActor in
                await listenTest(script: scriptPath, audio: audioPath)
                exit(0)
            }
            return true
        }

        // Development aid: `CustomNotch -prompterRun YES` runs the teleprompter (sample script, 240 words per minute,
        // nothing on screen) and prints where it is, with a pause, a resume and a sentence jump, then quits.
        if UserDefaults.standard.bool(forKey: "prompterRun") {
            let settings = Settings.shared
            let savedSpeed = settings.prompterWPM
            settings.prompterWPM = 240
            let prompter = Teleprompter(settings: settings, preview: Teleprompter.sampleScript)
            prompter.start()
            let began = Date()
            var step = 0
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                MainActor.assumeIsolated {
                    step += 1
                    let time = String(format: "%4.1fs", Date().timeIntervalSince(began))
                    print(time, "phase \(prompter.phase)", String(format: "line %.2f", prompter.position),
                          "of \(prompter.lines.count - 1)")
                    switch step {
                    case 12: prompter.togglePause(); print("     → pause")
                    case 15: prompter.togglePause(); print("     → continue")
                    case 17: prompter.nextSentence(); print("     → next sentence")
                    case 40:
                        timer.invalidate()
                        settings.prompterWPM = savedSpeed
                        exit(0)
                    default: break
                    }
                }
            }
            return true
        }

        // Development aid: `CustomNotch -hookSettings YES` prints the lines for ~/.claude/settings.json and quits.
        if UserDefaults.standard.bool(forKey: "hookSettings") {
            print(ClaudeBridge.settingsSnippet)
            exit(0)
        }

        // Development aid: `CustomNotch -batteryStatus YES` prints what the battery peeks and card read, and quits.
        if UserDefaults.standard.bool(forKey: "batteryStatus") {
            let battery = PeekSources.readBattery()
            print("Mac: \(battery.onAC ? "AC" : "battery") · charging: \(battery.charging) ·",
                  "percent: \(battery.percent.map(String.init) ?? "none")")
            let (reported, paired) = BatteryService.systemProfiler()
            for device in reported + BatteryService.accessories() {
                print("\(device.name): \(device.level.map { "\($0)%" } ?? "–")\(device.caseLevel.map { ", case \($0)%" } ?? "")")
            }
            print("paired Apple audio:", paired.map { String(format: "0x%04X ", $0.key) + $0.value }.sorted().joined(separator: ", "))
            exit(0)
        }

        // Development aid: `CustomNotch -parseProximity <hex>` decodes an AirPods Bluetooth broadcast and quits.
        if let hex = UserDefaults.standard.string(forKey: "parseProximity") {
            let bytes = stride(from: 0, to: hex.count - 1, by: 2).compactMap { offset -> UInt8? in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)
            }
            if let message = BatteryService.parseProximity(Data(bytes)) {
                let model = BatteryService.models[message.model]?.name ?? String(format: "unknown 0x%04X", message.model)
                print("\(model): left \(message.left.map { "\($0)%" } ?? "–") · right \(message.right.map { "\($0)%" } ?? "–")",
                      "· case \(message.caseLevel.map { "\($0)%" } ?? "–") · charging \(message.charging)")
            } else {
                print("not an AirPods battery broadcast")
            }
            exit(0)
        }

        // Development aid: `CustomNotch -slackCheck YES` tries Slack with a made-up token (tests the error path) and quits.
        if UserDefaults.standard.bool(forKey: "slackCheck") {
            Task {
                let problem = await SlackService(preview: [], team: nil).connect(token: "xoxp-0000-not-a-real-token")
                print("Slack answered:", problem ?? "accepted (unexpected)")
                exit(0)
            }
            return true
        }

        // Development aid: `CustomNotch -focusStatus YES` prints the Focus permission state (never asks) and quits.
        if UserDefaults.standard.bool(forKey: "focusStatus") {
            let center = INFocusStatusCenter.default
            let names = ["not determined", "restricted", "denied", "authorized"]
            print("Focus permission: \(names[min(max(center.authorizationStatus.rawValue, 0), 3)])",
                  "· isFocused: \(center.focusStatus.isFocused.map(String.init) ?? "unknown")")
            exit(0)
        }

        // Development aid: `CustomNotch -lyrics "Artist|Title|Album|Seconds"` looks up lyrics (cache first) and quits.
        if let query = UserDefaults.standard.string(forKey: "lyrics") {
            let parts = query.components(separatedBy: "|") + ["", "", "", ""]
            Task {
                let lyrics = await LyricsStore().lyrics(title: parts[1], artist: parts[0], album: parts[2],
                                                        duration: Double(parts[3]) ?? 0)
                print(lyrics.map { "\($0.lines.count) synced lines; at 0:40 → \($0.line(at: 40)?.text ?? "–")" } ?? "no lyrics")
                exit(0)
            }
            return true
        }

        return false
    }
}

extension DevTools {
    /// See `-prompterListen`: the recording stands in for the microphone.
    static func listenTest(script path: String, audio: String) async {
        guard let script = try? String(contentsOfFile: path, encoding: .utf8),
              let file = try? AVAudioFile(forReading: URL(fileURLWithPath: audio)) else {
            print("Couldn't read the script or the recording.")
            return
        }
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable else {
            print("This test needs SpeechAnalyzer (macOS 26).")
            return
        }
        guard let locale = await SpeechListener.locale(for: script) else {
            print("No speech recognizer for this script's language.")
            return
        }
        let words = Teleprompter.words(in: script).map(String.init)
        print("language \(locale.identifier) · \(words.count) words")
        var tracker = ScriptTracker(script: script)
        var played = 0.0
        var lastText = ""
        do {
            try await AnalyzerBackend.installModel(for: locale)
            let backend = AnalyzerBackend(locale: locale, contextual: SpeechListener.contextualStrings(for: script))
            try await backend.start { text in
                lastText = text
                let heard = Teleprompter.words(in: text).map { ScriptTracker.normalize(String($0)) }.filter { !$0.isEmpty }
                guard tracker.update(heard: heard) else { return }
                let word = tracker.cursor > 0 ? words[tracker.cursor - 1] : "–"
                print(String(format: "%5.1fs", played), "→ word \(tracker.cursor)/\(words.count)", "“\(word)”")
            }
            let format = file.processingFormat
            let chunk = AVAudioFrameCount(format.sampleRate / 10)
            while file.framePosition < file.length, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) {
                try file.read(into: buffer, frameCount: min(chunk, AVAudioFrameCount(file.length - file.framePosition)))
                guard buffer.frameLength > 0 else { break }
                backend.feed.push(buffer)
                played += Double(buffer.frameLength) / format.sampleRate
                try await Task.sleep(for: .milliseconds(100))           // real time, like a microphone
            }
            await backend.finish()
        } catch {
            print("Recognition failed:", error)
        }
        print("heard: \(lastText.trimmingCharacters(in: .whitespaces))")
        print("end: word \(tracker.cursor) of \(words.count)")
    }
}

// MARK: - Snapshots

/// Renders each state in both themes to PNG, for comparing against the reference screenshots.
@MainActor
enum Snapshot {
    static func render(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let settings = Settings.shared
        let savedTheme = settings.theme
        let savedTiles = settings.tiles
        let savedPrompter = (settings.prompterTextSize, settings.prompterWidth, settings.prompterWPM)
        defer {
            settings.theme = savedTheme
            settings.tiles = savedTiles
            (settings.prompterTextSize, settings.prompterWidth, settings.prompterWPM) = savedPrompter
        }
        settings.prompterTextSize = .medium
        settings.prompterWidth = .medium
        settings.prompterWPM = 130

        let lisbon = WeatherLocation(name: "Lisbon", country: "Portugal", latitude: 38.72, longitude: -9.14)
        let sample = WeatherService.Report(temperature: 18, code: 2, isDay: true, high: 20, low: 14,
                                           fetched: Date(), location: lisbon)
        // Sample song, matching the reference screenshot.
        let track = MusicService.Track(player: .music, id: "sample", title: "Low Tide", artist: "Nova Lane",
                                       album: "Shoreline", duration: 214)
        let sampleLyrics = Lyrics(lines: [Lyrics.Line(time: 120, text: "We wait for the water to turn"),
                                          Lyrics.Line(time: 131, text: "Hold the light until the low tide")],
                                  instrumental: false)
        func music(lyrics: Lyrics?) -> MusicService {
            MusicService(preview: track, artwork: sampleArtwork(), lyrics: lyrics, position: 134, settings: settings)
        }

        // `-live YES` renders this Mac's real state (controls, cached weather, current song) instead of samples.
        let live = UserDefaults.standard.bool(forKey: "live")
        let now = Date()
        let event = CalendarService.Event(title: "Design review", start: now.addingTimeInterval(25 * 60),
                                          end: now.addingTimeInterval(70 * 60), location: "Studio B",
                                          isAllDay: false, calendar: "Work")
        let command = """
            git fetch origin && git rebase origin/main && swift build -c release 2>&1 | tee build.log && \
            ./scripts/deploy.sh --target staging --notify "#releases" && rm -rf .build/checkouts/old-*
            """
        let request = ClaudeBridge.Request(sessionID: "sample", project: "Custom Notch", tool: "Bash", title: "Run a command",
                                           detail: command, note: "Rebuild and deploy to staging")
        let limits = ClaudeBridge.Limits(
            fiveHour: .init(usedPercent: 23, resetsAt: now.addingTimeInterval(2 * 3600)),
            sevenDay: .init(usedPercent: 41, resetsAt: now.addingTimeInterval(3 * 86_400)), updated: now.addingTimeInterval(-240))
        let claude = ClaudeBridge(settings: settings, preview: request, previewLimits: limits)
        let todayEvents = [event, CalendarService.Event(title: "1:1 with Sam", start: now.addingTimeInterval(3 * 3600),
                                                  end: now.addingTimeInterval(3.5 * 3600), location: nil, isAllDay: false,
                                                  calendar: "Work")]
        let devices = [
            BatteryService.Device(id: "mac", name: "Mac", kind: .mac, level: 68),
            BatteryService.Device(id: "max", name: "AirPods Max", kind: .headphones, level: 82, charging: true),
            BatteryService.Device(id: "pro", name: "AirPods Pro", kind: .buds, level: 55, caseLevel: 18),
        ]
        let slackMessages = [
            SlackService.Message(id: "1", author: "Sam", channel: "#design", text: "Pushed the new icons to the shared folder",
                                 date: now.addingTimeInterval(-600)),
            SlackService.Message(id: "2", author: "Lea", channel: "Lea", text: "Can we move the review to 4?",
                                 date: now.addingTimeInterval(-3_000)),
        ]
        let italian = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6", "d2d3", "f8c5"]
        let chessSample = ChessGame(settings: settings, preview: italian)
        func makeServices(calendar: CalendarService, music: MusicService, prompter: Teleprompter? = nil,
                          chess: ChessGame? = nil) -> Services {
            Services(weather: WeatherService(settings: settings, preview: sample), controls: SystemControls(preview: true),
                     music: music, batteries: BatteryService(preview: devices),
                     slack: SlackService(preview: slackMessages, team: "Studio"), calendar: calendar,
                     timer: FocusTimer(preview: 18 * 60 + 42), claude: claude,
                     prompter: prompter ?? Teleprompter(settings: settings, preview: Teleprompter.sampleScript),
                     chess: chess ?? chessSample)
        }
        func playing(_ game: ChessGame) -> Services {
            makeServices(calendar: CalendarService(preview: event, today: todayEvents), music: music(lyrics: nil), chess: game)
        }
        // The teleprompter with the sample script, at a given moment.
        func prompting(_ phase: Teleprompter.Phase, at position: Double, spoken: Int? = nil) -> Services {
            makeServices(calendar: CalendarService(preview: event, today: todayEvents), music: music(lyrics: nil),
                         prompter: Teleprompter(settings: settings, preview: Teleprompter.sampleScript, phase: phase,
                                                position: position, previewSpoken: spoken))
        }
        func sampleLineCount() -> Int {
            let layout = PrompterLayout(settings: settings)
            return Teleprompter.layout(Teleprompter.sampleScript, font: layout.font, width: layout.textWidth).count
        }
        let services = live
            ? Services(weather: WeatherService(settings: settings), controls: SystemControls(), music: MusicService(settings: settings),
                       batteries: BatteryService(), slack: SlackService(), calendar: CalendarService(), timer: FocusTimer(),
                       claude: ClaudeBridge(settings: settings))
            : makeServices(calendar: CalendarService(preview: event, today: todayEvents), music: music(lyrics: nil))
        if live {
            services.controls.refresh()
            services.batteries.islandOpened()
        }
        let withLyrics = live ? services : makeServices(calendar: CalendarService(preview: event, today: todayEvents), music: music(lyrics: sampleLyrics))
        // Nothing left in the calendar today: the first card shows the Claude limit.
        let freeDay = live ? services : makeServices(calendar: CalendarService(preview: nil, today: []), music: music(lyrics: nil))

        // Reference layout, plus other tile sizes and the lyric line.
        let defaults = TileConfig.defaults
        var jobs: [(name: String, state: IslandState, tiles: [TileConfig], services: Services, compact: CompactContent, page: Int)] = []
        func add(_ name: String, _ state: IslandState, _ tiles: [TileConfig], _ services: Services,
                 _ compact: CompactContent, _ page: Int = 0) {
            jobs.append((name, state, tiles, services, compact, page))
        }
        let sparkle = CompactContent(leading: .symbol("sparkle"), trailing: .activity)
        add("resting", .resting, defaults, services, sparkle, 0)
        add("compact", .compact, defaults, services, sparkle, 0)
        add("compact-music", .compact, defaults, services, CompactContent(leading: .artwork(sampleArtwork()), trailing: .equalizer))
        add("compact-claude", .compact, defaults, services, CompactContent(leading: .symbol("terminal"), trailing: .activity))
        add("permission", .permission, defaults, services, sparkle, 0)
        add("peek", .peek, defaults, services, sparkle, 0)
        add("peek-battery10", .peek, defaults, services, sparkle, 0)
        add("peek-focus", .peek, defaults, services, sparkle, 0)
        add("expanded", .expanded, defaults, services, sparkle, 0)
        add("expanded-lyrics", .expanded, defaults, withLyrics, sparkle, 0)
        add("expanded-sizes", .expanded, defaults.setting(.weather, cells: 1).setting(.controls, cells: 3)
            .setting(.music, cells: 2).setting(.cards, visible: false).setting(.timer, visible: true), withLyrics, sparkle)
        add("expanded-small", .expanded, defaults.setting(.weather, cells: 3).setting(.controls, cells: 1)
            .setting(.music, cells: 1).setting(.cards, visible: false), services, sparkle)
        add("expanded-optional", .expanded, defaults.setting(.music, visible: false).setting(.weather, visible: false)
            .setting(.cards, cells: 2).setting(.calendar, visible: true).setting(.timer, visible: true)
            .setting(.controls, cells: 1), services, sparkle)
        add("expanded-one-cell", .expanded, defaults.setting(.music, visible: false).setting(.weather, visible: false)
            .setting(.controls, visible: false).setting(.cards, cells: 1).setting(.calendar, visible: true)
            .setting(.calendar, cells: 1).setting(.timer, visible: true).setting(.timer, cells: 1), services, sparkle)
        // The cards, one page each.
        add("cards-claude", .expanded, defaults, freeDay, sparkle, 0)
        add("cards-batteries", .expanded, defaults, services, sparkle, 1)
        add("cards-slack", .expanded, defaults, services, sparkle, 2)
        add("prompter", .prompter, defaults, prompting(.running, at: 0), sparkle)
        add("prompter-scrolling", .prompter, defaults, prompting(.running, at: 1.5), sparkle)
        add("prompter-countdown", .prompter, defaults, prompting(.countdown(3), at: 0), sparkle)
        add("prompter-paused", .prompter, defaults, prompting(.paused, at: 2), sparkle)
        add("prompter-voice", .prompter, defaults, prompting(.running, at: 1, spoken: 9), sparkle)
        add("prompter-preparing", .prompter, defaults, prompting(.preparing("Getting the microphone ready…"), at: 0, spoken: 0), sparkle)
        add("prompter-end", .prompter, defaults, prompting(.finished, at: Double(sampleLineCount() - 1)), sparkle)
        add("chess", .chess, defaults, playing(ChessGame(settings: settings, preview: italian, selected: "f3")), sparkle)
        add("chess-thinking", .chess, defaults, playing(ChessGame(settings: settings, preview: italian + ["c2c3"], thinking: true)), sparkle)
        add("chess-black", .chess, defaults, playing(ChessGame(settings: settings, preview: ["e2e4", "c7c5", "g1f3"], player: .black)), sparkle)
        add("chess-mate", .chess, defaults, playing(ChessGame(settings: settings, preview: ["f2f3", "e7e5", "g2g4", "d8h4"])), sparkle)
        add("chess-tile-sizes", .expanded, defaults.setting(.music, visible: false).setting(.cards, visible: false)
            .setting(.chess, cells: 3).setting(.timer, visible: true).setting(.timer, cells: 1), services, sparkle)
        add("cards-sizes", .expanded, defaults.setting(.music, cells: 2).setting(.cards, cells: 2)
            .setting(.controls, cells: 1).setting(.weather, cells: 1), services, sparkle, 1)

        for theme in [ThemeName.darkMatte, .light] {
            settings.theme = theme
            let backdrop = theme == .darkMatte ? Color(hex: 0x343748) : Color(hex: 0xC9D3DE)
            for job in jobs {
                settings.tiles = job.tiles
                let model = IslandModel(geometry: .detect(), settings: settings)
                model.claude = job.services.claude
                model.prompter = job.services.prompter
                model.chess = job.services.chess
                model.state = job.state
                model.compact = job.compact
                switch job.name {
                case "peek-battery10":
                    model.peek = PeekContent(symbol: "battery.0", title: "Battery 10%", subtitle: "Connect the charger soon",
                                             tint: .critical)
                case "peek-focus":
                    model.peek = PeekContent(symbol: "moon.fill", title: "Focus On", subtitle: "Notifications are silenced")
                default:
                    model.peek = PeekContent(symbol: "bolt.fill", title: "Charging", subtitle: "Battery 76%")
                }
                let size = model.size(for: job.state)
                let view = IslandRootView(model: model, settings: settings, services: job.services)
                    .environment(\.staticRendering, true)
                    .environment(\.cardPage, job.page)
                    .frame(width: size.width + 2 * Metrics.shadowMargin, height: size.height + Metrics.shadowMargin)
                    .background(backdrop)
                if job.name == "expanded" {
                    renderClosing(model: model, services: job.services, settings: settings,
                                  to: folder.appendingPathComponent("\(theme.rawValue)-closing.png"))
                }
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.cgImage else { continue }
                let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                try? png?.write(to: folder.appendingPathComponent("\(theme.rawValue)-\(job.name).png"))
            }
        }

        // Teleprompter sizes (always on black, so one theme is enough).
        for (size, width) in [(PrompterTextSize.small, PrompterWidth.narrow), (.large, .wide), (.large, .narrow)] {
            settings.prompterTextSize = size
            settings.prompterWidth = width
            let services = prompting(.running, at: 1)
            let model = IslandModel(geometry: .detect(), settings: settings)
            model.prompter = services.prompter
            model.state = .prompter
            let island = model.size(for: .prompter)
            let view = IslandRootView(model: model, settings: settings, services: services)
                .environment(\.staticRendering, true)
                .frame(width: island.width + 2 * Metrics.shadowMargin, height: island.height + Metrics.shadowMargin)
                .background(Color(hex: 0x343748))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.cgImage {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: folder.appendingPathComponent("prompter-\(size.rawValue)-\(width.rawValue).png"))
            }
        }

        renderEditor(settings: settings, to: folder)
    }

    /// The script window, with the sample script and empty, in light and dark mode. ImageRenderer can't draw the
    /// text view and the AppKit controls, so the window is drawn off screen instead (materials come out flat).
    static func renderEditor(settings: Settings, to folder: URL) {
        for (name, script) in [("", Teleprompter.sampleScript), ("-empty", "")] {
            for (appearance, look) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let prompter = Teleprompter(settings: settings, preview: script)
                let editor = PrompterEditor(prompter: prompter, settings: settings)
                let panel = editor.makePanel()
                panel.appearance = NSAppearance(named: appearance)
                panel.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
                panel.orderFrontRegardless()
                panel.makeKey()
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                guard let view = panel.contentView?.superview,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: folder.appendingPathComponent("editor\(name)-\(look).png"))
                if name == "", look == "light" {
                    func find(_ v: NSView) -> ScriptNSTextView? { (v as? ScriptNSTextView) ?? v.subviews.lazy.compactMap(find).first }
                    if let tv = find(view) {
                        print("TEST firstResponder:", panel.firstResponder === tv)
                        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                        tv.insertText(" Extra Wort", replacementRange: tv.selectedRange())
                        print("TEST insert synced:", prompter.script.hasSuffix("Extra Wort"))
                        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                        tv.selectAll(nil); tv.delete(nil)
                        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                        print("TEST cleared:", prompter.script.isEmpty)
                        print("TEST canUndo:", tv.undoManager?.canUndo ?? false, tv.undoManager?.groupingLevel ?? -1)
                        tv.undoManager?.undo()
                        print("TEST undo restored:", prompter.script.hasSuffix("Extra Wort"))
                        let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                  windowNumber: panel.windowNumber, context: nil, characters: "\r",
                                                  charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                        print("TEST cmd-return handled:", panel.performKeyEquivalent(with: ev), "phase:", prompter.phase)
                        prompter.stop()
                    }
                }
                panel.close()
                withExtendedLifetime(editor) {}
            }
        }
    }

    /// Three moments of closing (open, part-way, nearly shut), stacked, to check the collapse effect.
    static func renderClosing(model: IslandModel, services: Services, settings: Settings, to url: URL) {
        let full = model.size(for: .expanded)
        let views = [1.0, 0.6, 0.3].map { progress in
            ClosingFrame(model: model, services: services, palette: settings.palette, progress: progress)
                .frame(width: full.width + 2 * Metrics.shadowMargin, height: full.height + 12)
        }
        let stack = VStack(spacing: 0) { ForEach(0..<3, id: \.self) { views[$0] } }
            .background(settings.theme == .darkMatte ? Color(hex: 0x343748) : Color(hex: 0xC9D3DE))
            .environment(\.staticRendering, true)
        let renderer = ImageRenderer(content: stack)
        renderer.scale = 2
        if let image = renderer.cgImage {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    /// A flat cover like the one in the reference: night sky, moon, water.
    static func sampleArtwork() -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: true) { rect in
            NSColor(srgbRed: 0.17, green: 0.29, blue: 0.43, alpha: 1).setFill()
            rect.fill()
            NSColor(srgbRed: 0.36, green: 0.50, blue: 0.60, alpha: 1).setFill()
            NSRect(x: 0, y: 210, width: 300, height: 90).fill()
            NSColor(white: 0.93, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 172, y: 58, width: 66, height: 66)).fill()
            return true
        }
    }
}

/// The island part-way through closing: its shape interpolated toward the notch, the tiles collapsing with it.
private struct ClosingFrame: View {
    let model: IslandModel
    let services: Services
    let palette: Palette
    let progress: CGFloat

    var body: some View {
        let full = model.size(for: .expanded)
        let notch = model.geometry.notch.size
        let size = CGSize(width: notch.width + (full.width - notch.width) * progress,
                          height: notch.height + (full.height - notch.height) * progress)
        let shape = IslandShape(ear: 0, radius: Metrics.notchRadius + (Metrics.islandRadius - Metrics.notchRadius) * progress)
        ZStack(alignment: .top) {
            shape.fill(Color.black).frame(width: size.width, height: size.height)
            IslandShape(ear: Metrics.ear, radius: Metrics.notchRadius).fill(Color.black)
                .frame(width: notch.width + 2 * Metrics.ear, height: notch.height)
            ExpandedView(model: model, services: services, palette: palette)
                .frame(width: full.width, height: full.height, alignment: .top)
                .modifier(CollapseEffect(progress: progress, smallest: min(notch.width / full.width, notch.height / full.height)))
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
