import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A teleprompter right under the camera: your script in a narrow column below the notch, following your
/// voice (or scrolling at a fixed speed), so your eyes stay next to the lens. The script is kept only on this Mac.
@MainActor @Observable
final class Teleprompter {
    enum Phase: Equatable { case idle, preparing(String), countdown(Int), running, paused, finished }

    struct Line: Identifiable, Equatable {
        let id: Int
        let text: String
        let firstWord: Int          // index of the line's first word in the script
        var wordCount = 0
        let weight: Double          // reading time in words, with short pauses for punctuation
        let sentenceStart: Bool     // a sentence starts on this line
        var isEnd = false           // the closing line after the script
    }

    private(set) var phase: Phase = .idle
    private(set) var lines: [Line] = []
    /// The line at the reading position, right under the notch (where the text is going, while it scrolls).
    private(set) var position: Double = 0
    /// How the text moves to `position`. Core Animation plays it, so scrolling costs the app almost nothing.
    private(set) var motion = PrompterMotion(from: 0, to: 0, duration: 0)
    /// Following your voice: the words before this index have been said (they are dimmed).
    private(set) var spokenWords = 0
    /// This run follows your voice (otherwise it scrolls at a fixed speed).
    private(set) var followsVoice = false
    /// The microphone is on, and whether you are talking right now.
    private(set) var listening = false
    private(set) var hearing = false

    var script: String {
        didSet { scheduleSave() }
    }

    var isActive: Bool { phase != .idle }

    @ObservationIgnored var onShow: (() -> Void)?
    @ObservationIgnored var onHide: (() -> Void)?
    @ObservationIgnored var onNeedsScript: (() -> Void)?

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let isPreview: Bool
    @ObservationIgnored private let hotKeys = HotKeys(signature: 0x4E545052)     // 'NTPR'
    @ObservationIgnored private var stepTimer: Timer?
    @ObservationIgnored private var countdownTimer: Timer?
    @ObservationIgnored private var resumeWork: DispatchWorkItem?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private let listener = SpeechListener()
    @ObservationIgnored private var tracker = ScriptTracker(script: "")
    /// Words heard before the text started (during the countdown) don't count.
    @ObservationIgnored private var heardBefore = 0
    @ObservationIgnored private var heardCount = 0
    /// The animation in flight, so a pause can stop the text exactly where it is on screen.
    @ObservationIgnored private var segment: (from: Double, to: Double, start: Date, duration: TimeInterval)?

    static let speeds = 60...240
    static let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Custom Notch/Teleprompter.txt")

    init(settings: Settings, preview: String? = nil, phase: Phase = .idle, position: Double = 0, previewSpoken: Int? = nil) {
        self.settings = settings
        isPreview = preview != nil
        script = preview ?? (try? String(contentsOf: Self.fileURL, encoding: .utf8)) ?? ""
        listener.onText = { [weak self] text in self?.heard(text) }
        listener.onSpeaking = { [weak self] speaking in self?.hearing = speaking }
        listener.onRestart = { [weak self] in
            self?.heardBefore = 0
            self?.heardCount = 0
        }
        if preview != nil {
            relayout()
            self.phase = phase
            self.position = position
            motion = PrompterMotion(from: position, to: position, duration: 0)
            if let previewSpoken {
                followsVoice = true
                listening = true
                hearing = true
                spokenWords = previewSpoken
            }
        }
    }

    // MARK: Controls

    func start() {
        guard !Self.words(in: script).isEmpty else { onNeedsScript?(); return }
        if case .preparing = phase { return }
        guard phase == .idle else { countdown(from: 3); return }
        relayout()
        move(to: 0)
        tracker = ScriptTracker(script: script)
        spokenWords = 0
        registerHotKeys()
        followsVoice = false
        guard settings.prompterFollowVoice, !isPreview else {
            onShow?()
            countdown(from: 3)
            return
        }
        // Permissions and the speech model first (macOS may ask), then the countdown.
        phase = .preparing("Getting the microphone ready…")
        onShow?()
        let script = script
        Task {
            let problem = await listener.prepare(script: script) { [weak self] message in
                guard let self, case .preparing = self.phase else { return }
                self.phase = .preparing(message)
            }
            guard case .preparing = phase else { return }       // stopped meanwhile
            followsVoice = problem == nil
            if let problem {
                phase = .preparing(problem)
                try? await Task.sleep(for: .seconds(4))
                guard case .preparing = phase else { return }
            }
            countdown(from: 3)
        }
    }

    func stop() {
        guard phase != .idle else { return }
        cancelTimers()
        segment = nil
        countdownTimer?.invalidate()
        hotKeys.unregister()
        stopListening()
        phase = .idle
        onHide?()
    }

    /// ⌃⌥Space: pause or carry on; at the end it starts again from the top.
    func togglePause() {
        switch phase {
        case .idle: start()
        case .preparing: break
        case .countdown:
            countdownTimer?.invalidate()
            stopListening()
            phase = .paused
        case .running:
            freeze()
            stopListening()
            phase = .paused
        case .paused:
            if followsVoice {
                // Straight back to reading (the text stays where it is); a new listening session starts fresh.
                startListening()
                phase = .running
            } else {
                phase = .running
                advance()
            }
        case .finished:
            move(to: 0, duration: 0.35, easeInOut: true)
            tracker.move(to: 0)
            spokenWords = 0
            countdown(from: 3)
        }
    }

    /// Fixed speed only; while following your voice, your voice sets the pace.
    func changeSpeed(by step: Int) {
        guard !followsVoice || phase == .idle else { NSSound.beep(); return }
        let speed = min(max(settings.prompterWPM + step, Self.speeds.lowerBound), Self.speeds.upperBound)
        guard speed != settings.prompterWPM else { NSSound.beep(); return }
        settings.prompterWPM = speed
        if phase == .running {
            freeze()
            advance()
        }
    }

    /// ⌃⌥→: the next line where a sentence starts.
    func nextSentence() {
        freeze()
        let current = Int((position + 0.05).rounded(.down))
        let target = lines.first { $0.id > current && ($0.sentenceStart || $0.isEnd) }?.id ?? lines.count - 1
        jump(to: Double(target))
    }

    /// ⌃⌥←: back to the start of the sentence, or to the one before if already there.
    func previousSentence() {
        freeze()
        let target = lines.last { Double($0.id) < position - 0.3 && $0.sentenceStart }?.id ?? 0
        jump(to: Double(target))
    }

    /// Two-finger scrolling over the text moves it by hand; it carries on from there half a second later.
    func scroll(byLines delta: Double) {
        guard phase == .running || phase == .paused || phase == .finished, !lines.isEmpty else { return }
        freeze()
        move(to: min(max(position + delta, 0), Double(lines.count - 1)))
        if phase == .finished, position < Double(lines.count - 1) { phase = .paused }
        scheduleResume(after: 0.5)
    }

    // MARK: Following your voice

    private func startListening() {
        guard followsVoice, !listening else { return }
        listening = true
        heardBefore = 0
        heardCount = 0
        Task {
            do {
                try await listener.start()
            } catch {
                // The microphone went away (or another app holds it): carry on at a fixed speed.
                listening = false
                followsVoice = false
                if phase == .running { advance() }
            }
        }
    }

    private func stopListening() {
        guard listening else { return }
        listening = false
        hearing = false
        listener.stop()
    }

    /// New words from the recognizer: find your place and bring its line to the reading position.
    private func heard(_ text: String) {
        let words = Self.words(in: text).map { ScriptTracker.normalize(String($0)) }.filter { !$0.isEmpty }
        heardCount = words.count
        guard phase == .running, followsVoice else { return }
        let fresh = words.count > heardBefore ? Array(words[heardBefore...]) : []
        guard tracker.update(heard: fresh) else { return }
        follow()
    }

    private func follow() {
        let cursor = tracker.cursor
        spokenWords = cursor
        guard cursor < tracker.words.count else {
            move(to: Double(lines.count - 1), duration: 0.4, easeInOut: true)
            stopListening()
            phase = .finished
            return
        }
        // Move on once you are at the last words of a line: recognition lags a little, and the next line is
        // already readable below.
        let last = max(cursor - 1, 0)
        guard let line = lines.last(where: { !$0.isEnd && $0.wordCount > 0 && $0.firstWord <= last }) else { return }
        var target = line.id
        let atEnd = line.wordCount > 2 ? last - line.firstWord >= line.wordCount - 2 : last - line.firstWord >= line.wordCount - 1
        if cursor > 0, atEnd, let next = lines.first(where: { $0.id > line.id && ($0.wordCount > 0 || $0.isEnd) }) {
            target = next.id
        }
        if Double(target) != position { move(to: Double(target), duration: 0.4, easeInOut: true) }
    }

    /// After moving by hand (keys or scrolling), carry on from the start of the line you're looking at.
    private func listenFrom(line index: Int) {
        guard followsVoice, lines.indices.contains(index) else { return }
        tracker.move(to: lines[index].firstWord)
        spokenWords = tracker.cursor
        heardBefore = heardCount        // what was said before doesn't count for the new place
    }

    /// Text size or width changed: wrap the script again, keeping the line you are on.
    func relayout() {
        if isActive { freeze() }
        let word = lines.indices.contains(Int(position)) ? lines[Int(position)].firstWord : 0
        let layout = PrompterLayout(settings: settings)
        lines = Self.layout(script, font: layout.font, width: layout.textWidth)
        guard isActive else { return }
        let line = lines.last { $0.firstWord <= word && !$0.isEnd }?.id ?? 0
        move(to: Double(line))
        scheduleResume(after: 0.3)
    }

    /// Word count and reading time, for the editor.
    var summary: String {
        let count = Self.words(in: script).count
        guard count > 0 else { return "" }
        let font = PrompterLayout(settings: settings).font
        let weight = Self.layout(script, font: font, width: 10_000).map(\.weight).reduce(0, +)
        let seconds = Int(weight / (Double(settings.prompterWPM) / 60))
        return "\(count) words · about \(seconds / 60):\(String(format: "%02d", seconds % 60)) at \(settings.prompterWPM) words per minute"
    }

    // MARK: Scrolling

    private func countdown(from value: Int) {
        cancelTimers()
        countdownTimer?.invalidate()
        startListening()            // starts during the countdown, so it is ready when the text is
        withAnimation(.snappy) { phase = .countdown(value) }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, case .countdown(let left) = self.phase else { timer.invalidate(); return }
                if left > 1 {
                    withAnimation(.snappy) { self.phase = .countdown(left - 1) }
                } else {
                    timer.invalidate()
                    withAnimation(.easeOut(duration: 0.25)) { self.phase = .running }
                    if self.followsVoice {
                        self.heardBefore = self.heardCount
                    } else {
                        self.advance()
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)       // keeps counting while a menu is open
        countdownTimer = timer
    }

    /// Scrolls to the next line at the reading speed, then again from there.
    private func advance() {
        guard phase == .running, !followsVoice, lines.count > 1 else { return }
        let end = Double(lines.count - 1)
        guard position < end - 0.001 else { phase = .finished; return }
        let index = min(Int(position.rounded(.down)), lines.count - 2)
        let target = Double(index + 1)
        let duration = max(0.05, seconds(for: lines[index]) * (target - position))
        move(to: target, duration: duration)
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.segment = nil
                self?.advance()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        stepTimer = timer
    }

    private func seconds(for line: Line) -> TimeInterval {
        line.weight / (Double(settings.prompterWPM) / 60)
    }

    private func jump(to target: Double) {
        guard phase != .idle, !lines.isEmpty else { return }
        if case .countdown = phase { return }
        freeze()
        move(to: target, duration: 0.3, easeInOut: true)
        if phase == .finished, target < Double(lines.count - 1) { phase = .paused }
        scheduleResume(after: 0.35)
    }

    private func scheduleResume(after delay: TimeInterval) {
        resumeWork?.cancel()
        let index = Int(position.rounded())
        if followsVoice {
            listenFrom(line: index)
            return
        }
        guard phase == .running else { return }
        let work = DispatchWorkItem { [weak self] in self?.advance() }
        resumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Stops the scrolling where the text is right now (part-way through its animation).
    private func freeze() {
        cancelTimers()
        guard segment != nil else { return }
        move(to: displayed)
    }

    /// Where the text is on screen right now, part-way through a move.
    private var displayed: Double {
        guard let segment else { return position }
        let progress = min(1, max(0, Date().timeIntervalSince(segment.start) / segment.duration))
        return segment.from + (segment.to - segment.from) * progress
    }

    private func cancelTimers() {
        stepTimer?.invalidate()
        stepTimer = nil
        resumeWork?.cancel()
    }

    /// Moves the text from where it is on screen now to `value`.
    private func move(to value: Double, duration: TimeInterval = 0, easeInOut: Bool = false) {
        let from = displayed
        motion = PrompterMotion(from: from, to: value, duration: duration, easeInOut: easeInOut)
        segment = duration > 0 ? (from, value, Date(), duration) : nil
        position = value
    }

    private func registerHotKeys() {
        hotKeys.register([
            (kVK_Space, { [weak self] in self?.togglePause() }),
            (kVK_UpArrow, { [weak self] in self?.changeSpeed(by: 10) }),
            (kVK_DownArrow, { [weak self] in self?.changeSpeed(by: -10) }),
            (kVK_RightArrow, { [weak self] in self?.nextSentence() }),
            (kVK_LeftArrow, { [weak self] in self?.previousSentence() }),
            (kVK_ANSI_Period, { [weak self] in self?.stop() }),
        ])
    }

    // MARK: Saving

    private func scheduleSave() {
        guard !isPreview else { return }
        saveWork?.cancel()
        let text = script
        let work = DispatchWorkItem {
            let url = Self.fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: Layout

    nonisolated static func words(in text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }

    /// Wraps the script into lines that fit the column. A blank line in the script becomes a short pause.
    static func layout(_ script: String, font: NSFont, width: CGFloat) -> [Line] {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let fits = width * 0.97         // a little slack, so SwiftUI never has to shrink a line
        var lines: [Line] = []
        var wordIndex = 0
        var sentenceStarts = true

        func add(_ words: [Substring], first: Int, startsSentence: Bool) {
            let text = words.joined(separator: " ")
            let pauses = words.reduce(0.0) { total, word in
                guard let last = word.last else { return total }
                if ".!?…".contains(last) { return total + 0.8 }
                if ",;:–—".contains(last) { return total + 0.35 }
                return total
            }
            lines.append(Line(id: lines.count, text: text, firstWord: first, wordCount: words.count,
                              weight: Double(words.count) + pauses, sentenceStart: startsSentence))
        }

        for paragraph in script.components(separatedBy: .newlines) {
            let words = Self.words(in: paragraph)
            if words.isEmpty {
                // One short pause per blank line run, never at the start.
                if let last = lines.last, !last.text.isEmpty {
                    lines.append(Line(id: lines.count, text: "", firstWord: wordIndex, weight: 0.8, sentenceStart: false))
                }
                sentenceStarts = true
                continue
            }
            var current: [Substring] = []
            var first = wordIndex
            var startsSentence = false
            for word in words {
                let candidate = (current + [word]).joined(separator: " ")
                if !current.isEmpty, (candidate as NSString).size(withAttributes: attributes).width > fits {
                    add(current, first: first, startsSentence: startsSentence)
                    current = []
                    first = wordIndex
                    startsSentence = false
                }
                if sentenceStarts { startsSentence = true }
                current.append(word)
                sentenceStarts = word.last.map { ".!?…".contains($0) } ?? false
                wordIndex += 1
            }
            if !current.isEmpty { add(current, first: first, startsSentence: startsSentence) }
            sentenceStarts = true
        }
        if lines.last?.text.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { return [] }
        lines.append(Line(id: lines.count, text: "", firstWord: wordIndex, weight: 0, sentenceStart: false, isEnd: true))
        return lines
    }

    static let sampleScript = """
        Guten Morgen zusammen und danke, dass ihr heute dabei seid. In den nächsten zehn Minuten zeige ich euch, \
        wie wir das neue Onboarding aufgebaut haben, was die ersten Zahlen sagen und wo wir eure Hilfe brauchen.

        Fangen wir mit dem Wichtigsten an: Die Abbruchrate im ersten Schritt ist um ein Drittel gesunken.
        """
}

// MARK: - Layout

/// Sizes of the teleprompter island. The reading line sits right under the notch, so you look at the lens.
struct PrompterLayout: Equatable {
    static let sidePadding: CGFloat = 22
    static let visibleLines: CGFloat = 2.5      // the reading line, the next one and a glimpse of the third
    static let topInset: CGFloat = 4
    static let bottomPadding: CGFloat = 6
    static let radius: CGFloat = 24
    static let spokenOpacity = 0.38     // words you have already said

    let font: NSFont
    let lineHeight: CGFloat
    let width: CGFloat              // the island

    @MainActor init(settings: Settings) {
        let size = settings.prompterTextSize.points
        font = .systemFont(ofSize: size, weight: .semibold)
        lineHeight = (size * 1.4).rounded()
        width = settings.prompterWidth.points
    }

    var textWidth: CGFloat { width - 2 * Self.sidePadding }
    /// Where the reading line starts, measured from the top of the text area. The line you just read stays
    /// visible above it, dimmed, so you can still finish it if you fall behind.
    var readingTop: CGFloat { Self.topInset + 0.8 * lineHeight }
    /// The text area below the notch.
    var areaHeight: CGFloat { readingTop + Self.visibleLines * lineHeight + Self.bottomPadding }
}

/// One move of the text: from one line position to another, over `duration` seconds (0 jumps).
struct PrompterMotion: Equatable {
    let id = UUID()
    var from: Double
    var to: Double
    var duration: TimeInterval
    var easeInOut = false
}

// MARK: - View

/// The script scrolling under the camera, with small controls on the two wings next to the notch.
struct PrompterView: View {
    let prompter: Teleprompter
    let settings: Settings
    let notch: CGSize
    private let palette = Palette.darkMatte         // always on black, like the notch
    @Environment(\.staticRendering) private var staticRendering

    var body: some View {
        let layout = PrompterLayout(settings: settings)
        let wing = max(0, (layout.width - notch.width) / 2)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leftWing.frame(width: wing)
                Color.clear.frame(width: notch.width)
                rightWing.frame(width: wing)
            }
            .frame(height: notch.height)
            text(layout)
        }
        .frame(width: layout.width, alignment: .top)
    }

    private var leftWing: some View {
        HStack(spacing: 12) {
            button("xmark", help: "Stop (⌃⌥.)", color: palette.secondary) { prompter.stop() }
            button(playSymbol, help: "Pause or continue (⌃⌥Space)", color: palette.accent) { prompter.togglePause() }
        }
    }

    private var playSymbol: String {
        switch prompter.phase {
        case .running, .countdown, .preparing: return "pause.fill"
        case .finished: return "arrow.counterclockwise"
        case .paused, .idle: return "play.fill"
        }
    }

    @ViewBuilder
    private var rightWing: some View {
        if prompter.followsVoice || (isPreparing && settings.prompterFollowVoice) { voiceIndicator } else { speedControls }
    }

    /// Following your voice: whether the microphone is on and hears you.
    private var voiceIndicator: some View {
        let hearing = prompter.listening && prompter.hearing
        return HStack(spacing: 5) {
            Image(systemName: prompter.listening ? (hearing ? "waveform" : "mic.fill") : "mic.slash.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(hearing ? palette.accent : palette.secondary)
                .frame(width: 18)
                .contentTransition(.symbolEffect(.replace))
            Text(prompter.listening ? "Listening" : isPreparing ? "Starting…" : "Mic off")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(palette.secondary)
        }
        .help("The text follows your voice. Speech is recognized on this Mac; no audio leaves it.")
    }

    private var isPreparing: Bool {
        if case .preparing = prompter.phase { return true }
        return false
    }

    private var speedControls: some View {
        HStack(spacing: 6) {
            button("minus", help: "Slower (⌃⌥↓)", color: palette.secondary) { prompter.changeSpeed(by: -10) }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(settings.prompterWPM)")
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(palette.text)
                    .contentTransition(.numericText())
                Text("wpm").font(.system(size: 9, weight: .medium)).foregroundStyle(palette.secondary)
            }
            .help("Words per minute")
            button("plus", help: "Faster (⌃⌥↑)", color: palette.secondary) { prompter.changeSpeed(by: 10) }
        }
    }

    private func button(_ symbol: String, help: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func text(_ layout: PrompterLayout) -> some View {
        let lines = prompter.lines
        let position = prompter.position
        // Only the lines near the reading position; the rest are off screen anyway.
        let first = max(0, Int(position.rounded(.down)) - 2)
        let last = min(lines.count, Int(position.rounded(.up)) + Int(PrompterLayout.visibleLines.rounded(.up)) + 2)
        let visible = first < last ? Array(lines[first..<last]) : []
        let dimmed: Double
        switch prompter.phase {
        case .countdown, .preparing: dimmed = 0
        case .paused: dimmed = 0.7
        default: dimmed = 1
        }
        return ZStack(alignment: .top) {
            Group {
                if staticRendering {
                    // Snapshots can't draw the Core Animation view: the same text drawn by SwiftUI, standing still.
                    ZStack(alignment: .top) {
                        ForEach(visible) { line in
                            lineView(line, layout: layout, spoken: prompter.spokenWords)
                                .offset(y: layout.readingTop + (CGFloat(line.id) - CGFloat(position)) * layout.lineHeight)
                        }
                    }
                    .frame(width: layout.width, height: layout.areaHeight, alignment: .top)
                    .clipped()
                    .mask { readingMask(layout) }
                } else {
                    PrompterScroller(lines: lines, motion: prompter.motion, layout: layout, spoken: prompter.spokenWords,
                                     text: NSColor(palette.text), secondary: NSColor(palette.secondary),
                                     mask: Self.maskStops(layout))
                }
            }
            .frame(width: layout.width, height: layout.areaHeight)
            .opacity(dimmed)

            if case .countdown(let left) = prompter.phase {
                Text("\(left)")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.text)
                    .contentTransition(.numericText(countsDown: true))
                    .frame(width: layout.width, height: layout.areaHeight)
            } else if case .preparing(let message) = prompter.phase {
                Text(message)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(palette.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, PrompterLayout.sidePadding)
                    .frame(width: layout.width, height: layout.areaHeight)
            }
        }
        .frame(width: layout.width, height: layout.areaHeight)
    }

    @ViewBuilder
    private func lineView(_ line: Teleprompter.Line, layout: PrompterLayout, spoken: Int) -> some View {
        if line.isEnd {
            Text("End · ⌃⌥. closes")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondary)
                .frame(width: layout.textWidth, height: layout.lineHeight)
        } else {
            Text(spokenText(line, spoken: spoken))
                .font(Font(layout.font))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: layout.textWidth, height: layout.lineHeight)
        }
    }

    /// Words already said are dimmed (only while following your voice).
    private func spokenText(_ line: Teleprompter.Line, spoken: Int) -> AttributedString {
        let words = line.text.split(separator: " ")
        let said = min(max(spoken - line.firstWord, 0), words.count)
        var string = AttributedString()
        for (index, word) in words.enumerated() {
            var part = AttributedString((index > 0 ? " " : "") + word)
            part.foregroundColor = index < said ? palette.text.opacity(PrompterLayout.spokenOpacity) : palette.text
            string += part
        }
        return string
    }

    /// Fixed in place while the text moves under it: the reading line is fully bright, the line above and the
    /// lines below are dimmer, and the text fades out at the edges. The changes are spread over most of a
    /// line, so text scrolling through them dims gently rather than at a hard edge.
    private func readingMask(_ layout: PrompterLayout) -> some View {
        LinearGradient(stops: Self.maskStops(layout).map { .init(color: .black.opacity($0.opacity), location: $0.location) },
                       startPoint: .top, endPoint: .bottom)
    }

    /// The mask as (opacity, location from the top) pairs, shared by both drawings.
    static func maskStops(_ layout: PrompterLayout) -> [(opacity: Double, location: CGFloat)] {
        let height = layout.areaHeight
        let line = layout.lineHeight
        let top = layout.readingTop
        func at(_ y: CGFloat) -> CGFloat { min(max(y / height, 0), 1) }
        return [(0, 0), (0.3, at(0.35 * line)), (0.35, at(top - 0.55 * line)), (1, at(top + 0.05 * line)),
                (1, at(top + 1.0 * line)), (0.5, at(top + 1.4 * line)),
                (0.42, at(height - PrompterLayout.bottomPadding - 0.45 * line)), (0, 1)]
    }
}

// MARK: - Scrolling with Core Animation

/// The script as one text layer per line, moved by Core Animation outside the app (like the equalizer), so
/// SwiftUI doesn't redraw the island for every frame of scrolling.
struct PrompterScroller: NSViewRepresentable {
    let lines: [Teleprompter.Line]
    let motion: PrompterMotion
    let layout: PrompterLayout
    let spoken: Int
    let text: NSColor
    let secondary: NSColor
    let mask: [(opacity: Double, location: CGFloat)]

    func makeNSView(context: Context) -> PrompterScrollView { PrompterScrollView() }

    func updateNSView(_ view: PrompterScrollView, context: Context) {
        view.show(lines: lines, layout: layout, text: text, secondary: secondary, mask: mask)
        view.mark(spoken: spoken)
        view.apply(motion)
    }
}

final class PrompterScrollView: NSView {
    private let content = CALayer()
    private let fade = CAGradientLayer()
    private var shownLines: [Teleprompter.Line] = []
    private var shownLayout: PrompterLayout?
    private var shownSpoken = 0
    private var textColor = NSColor.white
    private var lastMotion: UUID?
    private var lastTarget: Double = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.mask = fade
        content.anchorPoint = .zero
        layer?.addSublayer(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        place(at: lastTarget)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        content.sublayers?.forEach { $0.contentsScale = scale }
    }

    func show(lines: [Teleprompter.Line], layout: PrompterLayout, text: NSColor, secondary: NSColor,
              mask: [(opacity: Double, location: CGFloat)]) {
        guard lines != shownLines || layout != shownLayout else { return }
        shownLines = lines
        shownLayout = layout
        shownSpoken = 0
        textColor = text
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Top to bottom in a layer whose origin is at the bottom.
        fade.colors = mask.map { NSColor.black.withAlphaComponent($0.opacity).cgColor }
        fade.locations = mask.map { NSNumber(value: Double($0.location)) }
        fade.startPoint = CGPoint(x: 0.5, y: 1)
        fade.endPoint = CGPoint(x: 0.5, y: 0)

        content.sublayers?.forEach { $0.removeFromSuperlayer() }
        let height = CGFloat(lines.count) * layout.lineHeight
        content.bounds = CGRect(x: 0, y: 0, width: layout.width, height: height)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let small = NSFont.systemFont(ofSize: 12, weight: .medium)
        for line in lines {
            let font = line.isEnd ? small : layout.font
            let string = line.isEnd ? "End · ⌃⌥. closes" : line.text
            let layer = CATextLayer()
            layer.string = line.isEnd
                ? NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: secondary])
                : Self.attributed(line, spoken: 0, font: font, color: text)
            layer.contentsScale = scale
            layer.alignmentMode = .center           // CATextLayer ignores the paragraph style's alignment
            layer.truncationMode = .none
            let textHeight = (font.ascender - font.descender + font.leading).rounded(.up)
            let top = CGFloat(line.id) * layout.lineHeight + (layout.lineHeight - textHeight) / 2
            layer.frame = CGRect(x: PrompterLayout.sidePadding, y: height - top - textHeight,
                                 width: layout.textWidth, height: textHeight)
            content.addSublayer(layer)
        }
        place(at: lastTarget)
        CATransaction.commit()
    }

    /// Dims the words already said; only the lines whose words changed are redrawn.
    func mark(spoken: Int) {
        guard spoken != shownSpoken, let layout = shownLayout, let layers = content.sublayers else { return }
        let range = min(spoken, shownSpoken)..<max(spoken, shownSpoken)
        shownSpoken = spoken
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for line in shownLines where !line.isEnd && line.wordCount > 0 && layers.indices.contains(line.id) {
            guard line.firstWord < range.upperBound, line.firstWord + line.wordCount > range.lowerBound else { continue }
            (layers[line.id] as? CATextLayer)?.string = Self.attributed(line, spoken: spoken, font: layout.font, color: textColor)
        }
        CATransaction.commit()
    }

    static func attributed(_ line: Teleprompter.Line, spoken: Int, font: NSFont, color: NSColor) -> NSAttributedString {
        let words = line.text.split(separator: " ")
        let said = min(max(spoken - line.firstWord, 0), words.count)
        let result = NSMutableAttributedString()
        for (index, word) in words.enumerated() {
            let shade = index < said ? color.withAlphaComponent(PrompterLayout.spokenOpacity) : color
            result.append(NSAttributedString(string: (index > 0 ? " " : "") + word,
                                             attributes: [.font: font, .foregroundColor: shade]))
        }
        return result
    }

    func apply(_ motion: PrompterMotion) {
        guard motion.id != lastMotion else { return }
        lastMotion = motion.id
        lastTarget = motion.to
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.removeAnimation(forKey: "scroll")
        place(at: motion.to)
        CATransaction.commit()
        guard motion.duration > 0 else { return }
        let animation = CABasicAnimation(keyPath: "position.y")
        animation.fromValue = originY(at: motion.from)
        animation.toValue = originY(at: motion.to)
        animation.duration = motion.duration
        animation.timingFunction = CAMediaTimingFunction(name: motion.easeInOut ? .easeInEaseOut : .linear)
        content.add(animation, forKey: "scroll")
    }

    /// Bottom of the text so that line `position` starts at the reading line.
    private func originY(at position: Double) -> CGFloat {
        guard let layout = shownLayout else { return 0 }
        let lineTop = content.bounds.height - CGFloat(position) * layout.lineHeight     // from the text's bottom
        return bounds.height - layout.readingTop - lineTop
    }

    private func place(at position: Double) {
        content.position = CGPoint(x: 0, y: originY(at: position))
    }
}


// MARK: - Script editor

/// The teleprompter's window: paste or type the script, choose how it scrolls, its size and width, then Start.
/// Like the other prompts it takes typing without activating the app, so the app you are in stays in front.
/// Everything you type is saved as you go.
@MainActor
final class PrompterEditor: NSObject {
    /// Applies a layout change (the island resizes around it while the teleprompter is out).
    var applyLayout: (() -> Void) -> Void = { $0() }

    static let size = NSSize(width: 760, height: 500)

    private let prompter: Teleprompter
    private let settings: Settings
    private var panel: KeyPanel?

    init(prompter: Teleprompter, settings: Settings) {
        self.prompter = prompter
        self.settings = settings
    }

    func show() {
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = makePanel()
        // Under the notch, on the notch screen.
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.maxY - 60))
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)         // the script view takes the cursor when it lands in the window
    }

    /// The window with its content (also used by the snapshots).
    func makePanel() -> KeyPanel {
        let panel = KeyPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                             styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.title = "Teleprompter"
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 640, height: 400)
        panel.contentView = NSHostingView(rootView: PrompterEditorView(
            prompter: prompter, settings: settings,
            applyLayout: { [weak self] change in self?.applyLayout(change) ?? change() },
            done: { [weak self] in self?.panel?.close() },
            start: { [weak self] in self?.startClicked() }))
        return panel
    }

    private func startClicked() {
        guard !Teleprompter.words(in: prompter.script).isEmpty else { NSSound.beep(); return }
        panel?.close()
        prompter.start()
    }
}

/// The editor's content: the script on the left, the options in a column on the right, Start at the bottom.
/// Standard controls in the system's colours, so it looks like macOS in light and dark mode; only Start and the
/// selections carry the app's accent.
struct PrompterEditorView: View {
    let prompter: Teleprompter
    let settings: Settings
    let applyLayout: (@escaping () -> Void) -> Void
    let done: () -> Void
    let start: () -> Void

    @State private var editing = ScriptEditing()
    @State private var showsShortcuts = false

    private var isEmpty: Bool { Teleprompter.words(in: prompter.script).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                scriptCard
                options.frame(width: 232)
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 16)
            Divider()
            bottomBar
        }
        .tint(Palette.darkMatte.accent)
        .frame(minWidth: 640, minHeight: 360)
    }

    // MARK: Script

    private var scriptCard: some View {
        VStack(spacing: 0) {
            ScriptTextView(prompter: prompter, editing: editing, start: start)
                .overlay { if isEmpty { emptyState } }
            Divider()
            HStack(spacing: 10) {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.numericText())
                Spacer(minLength: 8)
                Button { editing.paste() } label: { Image(systemName: "doc.on.clipboard") }
                    .help("Paste from the clipboard at the cursor (⌘V)")
                Button { editing.clear() } label: { Image(systemName: "trash") }
                    .help("Clear the script (⌘Z brings it back)")
                    .disabled(prompter.script.isEmpty)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .frame(height: 36)
        }
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)) }
    }

    /// Shown in the empty script, over the text view; only its button takes clicks, so a click anywhere else
    /// still puts the cursor in the text.
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
                .allowsHitTesting(false)
            VStack(spacing: 4) {
                Text("Your Script").font(.title3.weight(.semibold))
                Text("Paste it, type it, or dictate it with the 🎤 key.\nA blank line adds a short pause.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .allowsHitTesting(false)
            Button("Paste from Clipboard") { editing.paste() }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(24)
    }

    /// Word count and, at a fixed speed, the reading time. Following your voice there is no fixed reading time.
    private var summary: String {
        let full = prompter.summary
        guard !full.isEmpty else { return "No script yet" }
        return settings.prompterFollowVoice ? full.components(separatedBy: " · about").first ?? full : full
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Scrolling") {
                Picker("Scrolling", selection: followVoice) {
                    Text("Follow Voice").tag(true)
                    Text("Fixed Speed").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(settings.prompterFollowVoice
                     ? "The text moves on as you speak. Speech is recognized on this Mac; no audio leaves it."
                     : "The text scrolls at a steady speed. A blank line in the script adds a short pause.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            section("Speed") {
                HStack(spacing: 10) {
                    // No `step`: that draws a tick mark every 10 words. The binding rounds instead.
                    Slider(value: speed, in: Double(Teleprompter.speeds.lowerBound)...Double(Teleprompter.speeds.upperBound))
                        .labelsHidden()
                    Text("\(settings.prompterWPM)")
                        .font(.body.monospacedDigit())
                        .frame(width: 30, alignment: .trailing)
                        .contentTransition(.numericText())
                }
                Text(settings.prompterFollowVoice ? "Your voice sets the pace." : "Words per minute")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(settings.prompterFollowVoice)
            section("Text Size") {
                Picker("Text Size", selection: textSize) {
                    ForEach(PrompterTextSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            section("Width") {
                Picker("Width", selection: width) {
                    ForEach(PrompterWidth.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Narrow keeps your eyes closest to the camera.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    // Changes go through the teleprompter, so a running one picks them up (and the island resizes around it).

    private var followVoice: Binding<Bool> {
        Binding(get: { settings.prompterFollowVoice },
                set: { value in withAnimation(.snappy) { settings.prompterFollowVoice = value } })
    }

    private var speed: Binding<Double> {
        Binding(get: { Double(settings.prompterWPM) },
                set: { value in
                    let speed = Int((value / 10).rounded()) * 10
                    guard speed != settings.prompterWPM else { return }
                    prompter.changeSpeed(by: speed - settings.prompterWPM)
                })
    }

    private var textSize: Binding<PrompterTextSize> {
        Binding(get: { settings.prompterTextSize },
                set: { size in
                    guard size != settings.prompterTextSize else { return }
                    applyLayout { [settings, prompter] in
                        settings.prompterTextSize = size
                        prompter.relayout()
                    }
                })
    }

    private var width: Binding<PrompterWidth> {
        Binding(get: { settings.prompterWidth },
                set: { width in
                    guard width != settings.prompterWidth else { return }
                    applyLayout { [settings, prompter] in
                        settings.prompterWidth = width
                        prompter.relayout()
                    }
                })
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button { showsShortcuts.toggle() } label: { Label("Shortcuts", systemImage: "keyboard") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .popover(isPresented: $showsShortcuts, arrowEdge: .top) { ShortcutList() }
            Spacer()
            Button("Done", action: done)
                .controlSize(.large)
            Button(action: start) {
                Label("Start", systemImage: "play.fill")
                    .padding(.horizontal, 6)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)     // plain ↩ is a new line
            .disabled(isEmpty)
            .help("Start after 3-2-1 (⌘↩)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// The shortcuts that work while the teleprompter runs, as keycaps.
private struct ShortcutList: View {
    private static let rows: [(keys: [String], action: String)] = [
        (["⌃", "⌥", "Space"], "Pause or continue"),
        (["⌃", "⌥", "←", "→"], "Previous or next sentence"),
        (["⌃", "⌥", "↑", "↓"], "Faster or slower (fixed speed)"),
        (["⌃", "⌥", "."], "Stop"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("While It Runs").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(Self.rows, id: \.action) { row in
                    GridRow {
                        HStack(spacing: 3) { ForEach(row.keys, id: \.self) { keycap($0) } }
                        Text(row.action)
                    }
                }
                GridRow {
                    Image(systemName: "hand.draw").frame(minWidth: 22)
                    Text("Two fingers on the text move it by hand")
                }
            }
            .font(.callout)
        }
        .padding(16)
    }

    private func keycap(_ key: String) -> some View {
        Text(key)
            .font(.callout.weight(.medium))
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, key.count > 1 ? 6 : 0)
            .background(.quaternary, in: .rect(cornerRadius: 5))
    }
}

/// Lets the buttons next to the script paste into and clear the text view, with undo.
@MainActor
final class ScriptEditing {
    weak var textView: NSTextView?

    func paste() {
        guard let textView, let string = NSPasteboard.general.string(forType: .string), !string.isEmpty else {
            NSSound.beep()
            return
        }
        textView.window?.makeFirstResponder(textView)
        textView.insertText(string, replacementRange: textView.selectedRange())
    }

    func clear() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.selectAll(nil)
        textView.delete(nil)
    }
}

/// The script as plain text in an AppKit text view: pasting (through `KeyPanel`), undo and dictation work as
/// everywhere else in macOS. It saves to the teleprompter as you type.
struct ScriptTextView: NSViewRepresentable {
    let prompter: Teleprompter
    let editing: ScriptEditing
    let start: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(prompter: prompter) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let textView = ScriptNSTextView(frame: .zero)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 14, height: 16)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        textView.defaultParagraphStyle = paragraph
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .labelColor
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor,
                                     .paragraphStyle: paragraph]
        textView.string = prompter.script
        textView.delegate = context.coordinator
        textView.onCommandReturn = start

        scroll.documentView = textView
        editing.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Only when the script changed elsewhere: setting it on every keystroke would lose the selection and undo.
        guard let textView = scroll.documentView as? NSTextView, textView.string != prompter.script else { return }
        textView.string = prompter.script
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let prompter: Teleprompter

        init(prompter: Teleprompter) { self.prompter = prompter }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            prompter.script = textView.string
        }
    }
}

final class ScriptNSTextView: NSTextView {
    var onCommandReturn: () -> Void = {}

    /// Takes the cursor as soon as the window shows, so you can paste or type right away.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    /// ⌘↩ starts; plain ↩ is a new line.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            onCommandReturn()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
