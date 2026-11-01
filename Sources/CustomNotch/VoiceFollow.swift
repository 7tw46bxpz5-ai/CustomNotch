import AVFoundation
import NaturalLanguage
import Speech

// MARK: - Where you are in the script

/// Finds where you are in the script from the last few words you said. It moves forward freely, goes back
/// only on strong evidence (several words you repeat), and stays put while you speak off-script.
struct ScriptTracker {
    let words: [String]             // the script's words, normalized
    private(set) var cursor = 0     // the next word to say; everything before it has been said

    init(script: String) {
        words = Teleprompter.words(in: script).map { Self.normalize(String($0)) }
    }

    mutating func move(to index: Int) {
        cursor = min(max(index, 0), words.count)
    }

    /// `heard`: the words recognized so far (normalized, newest last). Returns true if the cursor moved.
    @discardableResult
    mutating func update(heard: [String]) -> Bool {
        let tail = Array(heard.filter { !$0.isEmpty }.suffix(6))
        guard let last = tail.last, !words.isEmpty else { return false }
        // Near where you are first; then, for a long skip, the rest of the script with stronger evidence.
        let near = max(0, cursor - 20)...min(words.count - 1, cursor + 40)
        var best = bestMatch(tail, in: near) { jump in
            switch jump {
            case 0...3: return last.count >= 5 ? 1 : 2      // the next words; a short one needs its neighbour too
            case 4...10: return 2
            default: return 3                               // further ahead (a skipped passage), or back (repeated)
            }
        }
        if best == nil, tail.count >= 4, near.upperBound + 1 < words.count {
            best = bestMatch(tail, in: (near.upperBound + 1)...(words.count - 1)) { _ in 4 }
        }
        guard let best, best + 1 != cursor else { return false }
        cursor = best + 1
        return true
    }

    /// The script position (last word said) that best fits the heard words; ties go to the nearest.
    private func bestMatch(_ tail: [String], in range: ClosedRange<Int>, needed: (Int) -> Double) -> Int? {
        guard let last = tail.last, !range.isEmpty else { return nil }
        var best: (end: Int, score: Double)?
        for end in range where Self.similar(words[end], last) {
            let score = Double(Self.recentMatches(tail, endingAt: end, in: words))
            guard score >= needed(end + 1 - cursor) else { continue }
            if let current = best {
                let closer = abs(end + 1 - cursor) < abs(current.end + 1 - cursor)
                if score > current.score + 0.01 || (abs(score - current.score) <= 0.01 && closer) { best = (end, score) }
            } else {
                best = (end, score)
            }
        }
        return best?.end
    }

    /// How many of the newest heard words match the script, walking back from `end`. One slip is allowed
    /// (a word the recognizer added, dropped or got wrong); a second one ends the run, so older words that
    /// happen to match elsewhere don't count as evidence for a new place.
    static func recentMatches(_ tail: [String], endingAt end: Int, in words: [String]) -> Int {
        var i = tail.count - 1, j = end, matches = 0, slips = 0
        while i >= 0, j >= 0 {
            if similar(tail[i], words[j]) {
                matches += 1
                i -= 1
                j -= 1
                continue
            }
            slips += 1
            guard slips <= 1 else { break }
            if i > 0, similar(tail[i - 1], words[j]) {
                i -= 1                  // a word heard that isn't in the script
            } else if j > 0, similar(tail[i], words[j - 1]) {
                j -= 1                  // a script word the recognizer missed
            } else {
                i -= 1                  // misheard
                j -= 1
            }
        }
        return matches
    }

    /// Same word, allowing a typo-sized difference for longer words (endings, recognizer spelling). The first
    /// letter must agree, so words that only sound alike ("erstens", "zweitens") stay apart.
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard min(a.count, b.count) >= 4, a.first == b.first else { return false }
        return distance(a, b) <= (max(a.count, b.count) >= 9 ? 2 : 1)
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }

    /// Lower case, no accents or punctuation, ß as ss, and small numbers as digits, so "zehn" matches "10".
    static func normalize(_ word: String) -> String {
        let plain = word.lowercased().replacingOccurrences(of: "ß", with: "ss")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
        return numbers[plain] ?? plain
    }

    private static let numbers: [String: String] = {
        let german = ["null", "eins", "zwei", "drei", "vier", "funf", "sechs", "sieben", "acht", "neun", "zehn", "elf",
                      "zwolf", "dreizehn", "vierzehn", "funfzehn", "sechzehn", "siebzehn", "achtzehn", "neunzehn", "zwanzig"]
        let english = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                       "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]
        var map: [String: String] = [:]
        for (value, word) in german.enumerated() { map[word] = String(value) }
        for (value, word) in english.enumerated() { map[word] = String(value) }
        return map
    }()
}

// MARK: - Listening

/// Hears you through the microphone and turns it into text on this Mac: Apple's on-device speech recognition
/// (SpeechAnalyzer on macOS 26, the older on-device recognizer before). No audio leaves the Mac.
@MainActor
final class SpeechListener {
    /// Everything heard since `start`, newest words last (words still being recognized included).
    var onText: (String) -> Void = { _ in }
    /// You started or stopped talking, from the microphone level.
    var onSpeaking: (Bool) -> Void = { _ in }
    /// Listening started over (another microphone was chosen): the text from `onText` starts from scratch.
    var onRestart: () -> Void = {}

    private(set) var locale: Locale?
    private var contextual: [String] = []
    private var engine: AVAudioEngine?
    private var backend: SpeechBackend?
    private let level = LevelMeter()
    private var configurationObserver: NSObjectProtocol?

    /// Permissions, language and the speech model, before the countdown. Returns what went wrong, or nil.
    /// `progress` gets a line to show while something takes longer (the model download).
    func prepare(script: String, progress: (String) -> Void = { _ in }) async -> String? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { return Self.micOff }
        default: return Self.micOff
        }
        guard let locale = await Self.locale(for: script) else {
            return "This language can't be recognized on this Mac. Scrolling at a fixed speed instead."
        }
        self.locale = locale
        contextual = Self.contextualStrings(for: script)
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
            do {
                if await !AnalyzerBackend.modelInstalled(for: locale) {
                    progress("Downloading the \(Self.name(of: locale)) speech model from Apple (only this once)…")
                }
                try await AnalyzerBackend.installModel(for: locale)
            } catch {
                return "The speech model for \(Self.name(of: locale)) couldn't be downloaded. Scrolling at a fixed speed instead."
            }
            return nil
        }
        // macOS 14 and 15: the older recognizer, on this Mac only. It needs the Speech Recognition permission.
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            return "Speech Recognition is off for Custom Notch (System Settings → Privacy & Security). Scrolling at a fixed speed instead."
        }
        guard SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true else {
            return "\(Self.name(of: locale)) can't be recognized on this Mac without sending audio to Apple. Scrolling at a fixed speed instead."
        }
        return nil
    }

    /// Unusual words in the script (names, terms, long words) help the recognizer get them right.
    static func contextualStrings(for script: String) -> [String] {
        let words = Teleprompter.words(in: script).map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 6 || $0.first?.isUppercase == true }
        var seen = Set<String>()
        return Array(words.filter { seen.insert($0).inserted }.prefix(100))
    }

    /// Turns the microphone on and starts recognizing. On failure everything is torn down again.
    func start() async throws {
        guard backend == nil, let locale else { return }
        do {
            try await begin(locale: locale)
        } catch {
            stop()
            throw error
        }
    }

    private func begin(locale: Locale) async throws {
        let backend = try Self.makeBackend(locale: locale, contextual: contextual)
        self.backend = backend
        // Text from a recognizer that has been stopped (it can still be finishing) is ignored.
        try await backend.start { [weak self, weak backend] text in
            guard let self, let backend, self.backend === backend else { return }
            self.onText(text)
        }
        guard self.backend === backend else {               // stopped while starting
            await backend.stop()
            return
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ListenError.noMicrophone }
        let feed = backend.feed
        let level = level
        level.onChange = { [weak self] speaking in self?.onSpeaking(speaking) }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            feed.push(buffer)
            level.measure(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        // AirPods connecting, or another input chosen in Settings: listen again on the new microphone.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
    }

    private func restart() {
        guard engine != nil else { return }
        stop()
        onRestart()
        Task { try? await start() }
    }

    /// Turns the microphone off.
    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        let backend = backend
        self.backend = nil
        level.reset()
        Task { await backend?.stop() }
    }

    static func makeBackend(locale: Locale, contextual: [String]) throws -> SpeechBackend {
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
            return AnalyzerBackend(locale: locale, contextual: contextual)
        }
        guard let backend = RecognizerBackend(locale: locale, contextual: contextual) else { throw ListenError.unavailable }
        return backend
    }

    /// The script's language (recognized on this Mac), in your region's variant when there is one.
    static func locale(for script: String) async -> Locale? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(script)
        let language = recognizer.dominantLanguage?.rawValue ?? Locale.current.language.languageCode?.identifier ?? "en"
        let supported: [Locale]
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
            supported = await SpeechTranscriber.supportedLocales
        } else {
            supported = Array(SFSpeechRecognizer.supportedLocales())
        }
        let candidates = supported.filter { $0.language.languageCode?.identifier == language }
        let region = Locale.current.region?.identifier
        let fallback = ["en": "US", "de": "DE", "fr": "FR", "es": "ES", "it": "IT", "pt": "BR", "nl": "NL"][language]
        return candidates.first { $0.region?.identifier == region }
            ?? candidates.first { $0.region?.identifier == fallback }
            ?? candidates.first
    }

    static func name(of locale: Locale) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "") ?? "This language"
    }

    private static let micOff = "The microphone is off for Custom Notch (System Settings → Privacy & Security → Microphone). Scrolling at a fixed speed instead."

    enum ListenError: Error { case noMicrophone, unavailable, noAudioFormat }
}

/// Whether you are talking, from the microphone level (with a short hold, so pauses between words don't count).
final class LevelMeter: @unchecked Sendable {
    var onChange: @MainActor (Bool) -> Void = { _ in }
    private let lock = NSLock()
    private var speaking = false
    private var lastLoud = Date.distantPast

    func measure(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let decibels = 10 * log10(max(sum / Float(buffer.frameLength), 1e-10))
        let now = Date()
        let changed: Bool? = lock.withLock {
            if decibels > -45 { lastLoud = now }
            let talking = now.timeIntervalSince(lastLoud) < 0.6
            guard talking != speaking else { return nil }
            speaking = talking
            return talking
        }
        if let changed {
            DispatchQueue.main.async { [onChange] in MainActor.assumeIsolated { onChange(changed) } }
        }
    }

    func reset() {
        lock.withLock { speaking = false; lastLoud = .distantPast }
    }
}

/// Audio buffers from the microphone's thread to whichever recognizer is listening.
final class AudioFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((AVAudioPCMBuffer) -> Void)?

    func set(_ handler: ((AVAudioPCMBuffer) -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { handler }?(buffer)
    }
}

@MainActor
protocol SpeechBackend: AnyObject {
    var feed: AudioFeed { get }
    func start(onText: @escaping @MainActor (String) -> Void) async throws
    func stop() async
}

/// macOS 26: SpeechAnalyzer with SpeechTranscriber, on this Mac, reporting words while they are still being
/// recognized (volatile results) so the text can follow without waiting for the end of a sentence.
@available(macOS 26, *)
@MainActor
final class AnalyzerBackend: SpeechBackend {
    let feed = AudioFeed()
    private let locale: Locale
    private let contextual: [String]
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?

    init(locale: Locale, contextual: [String]) {
        self.locale = locale
        self.contextual = contextual
    }

    private func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                          attributeOptions: [])
    }

    static func modelInstalled(for locale: Locale) async -> Bool {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                            attributeOptions: [])
        return await AssetInventory.status(forModules: [transcriber]) == .installed
    }

    /// Downloads the language's model from Apple the first time (no audio is involved).
    static func installModel(for locale: Locale) async throws {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                            attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    func start(onText: @escaping @MainActor (String) -> Void) async throws {
        let transcriber = makeTranscriber()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechListener.ListenError.noAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !contextual.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextual
            try? await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let converter = BufferConverter(output: format)
        feed.set { buffer in
            if let converted = converter.convert(buffer) { continuation.yield(AnalyzerInput(buffer: converted)) }
        }
        results = Task { @MainActor in
            var finished = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finished += " " + text
                        onText(finished)
                    } else {
                        onText(finished + " " + text)
                    }
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        self.continuation = continuation
    }

    func stop() async {
        feed.set(nil)
        continuation?.finish()
        continuation = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        results?.cancel()
        results = nil
    }

    /// For testing with a file: lets the recognizer finish what it has heard, then stops.
    func finish() async {
        feed.set(nil)
        continuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
    }
}

/// macOS 14 and 15: Apple's older recognizer, restricted to on-device recognition. A recognition task ends
/// after a while, so a new one picks up where it stopped.
@MainActor
final class RecognizerBackend: SpeechBackend {
    let feed = AudioFeed()
    private let recognizer: SFSpeechRecognizer
    private let contextual: [String]
    private var task: SFSpeechRecognitionTask?
    private var earlier = ""
    private var running = false
    private var onText: @MainActor (String) -> Void = { _ in }

    init?(locale: Locale, contextual: [String]) {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else { return nil }
        self.recognizer = recognizer
        self.contextual = contextual
    }

    func start(onText: @escaping @MainActor (String) -> Void) async throws {
        self.onText = onText
        running = true
        begin()
    }

    private func begin() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = contextual
        feed.set { request.append($0) }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    if let result {
                        let text = result.bestTranscription.formattedString
                        self.onText(self.earlier + " " + text)
                        if result.isFinal {
                            self.earlier += " " + text
                            self.begin()
                        }
                    } else if error != nil {
                        self.begin()
                    }
                }
            }
        }
    }

    func stop() async {
        running = false
        feed.set(nil)
        task?.cancel()
        task = nil
    }
}

/// Converts microphone audio to the format the recognizer wants (used on the audio thread only).
final class BufferConverter {
    private let output: AVAudioFormat
    private var converter: AVAudioConverter?

    init(output: AVAudioFormat) {
        self.output = output
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == output { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: output)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate).rounded(.up)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || converted.frameLength == 0 ? nil : converted
    }
}
