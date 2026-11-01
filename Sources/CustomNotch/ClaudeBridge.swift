import AppKit
import Carbon.HIToolbox

// MARK: - Socket server

/// One connection from notch-hook. A permission request keeps it open until you answer; if Claude Code
/// gives up on the hook (for example because you answered in the terminal), the connection closes.
final class HookConnection: @unchecked Sendable {
    private let fd: Int32
    private var hangUpSource: DispatchSourceRead?
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32) { self.fd = fd }

    /// Calls `handler` on the main thread if the other side goes away first.
    func watchHangUp(_ handler: @escaping @MainActor () -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var byte: UInt8 = 0
            if recv(self.fd, &byte, 1, MSG_PEEK) <= 0 {
                self.close()
                DispatchQueue.main.async { handler() }
            }
        }
        // libdispatch needs the descriptor open until the source is fully cancelled.
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        hangUpSource = source
        source.resume()
    }

    /// Sends the answer (or nothing) and closes.
    func reply(_ data: Data?) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        if let data {
            var sent = 0
            while sent < data.count {
                let written = data.withUnsafeBytes { write(fd, $0.baseAddress! + sent, data.count - sent) }
                if written <= 0 { break }
                sent += written
            }
        }
        closeLocked()
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()
    }

    private func closeLocked() {
        guard !closed else { return }
        closed = true
        if let hangUpSource {
            hangUpSource.cancel()       // its cancel handler closes the descriptor
        } else {
            Darwin.close(fd)
        }
    }
}

/// Listens on ~/Library/Application Support/Custom Notch/claude.sock (only your user can open it).
final class HookServer: @unchecked Sendable {
    static let path = NSHomeDirectory() + "/Library/Application Support/Custom Notch/claude.sock"

    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "CustomNotch.hooks")
    private let onMessage: @MainActor ([String: Any], HookConnection) -> Void

    init(onMessage: @escaping @MainActor ([String: Any], HookConnection) -> Void) {
        self.onMessage = onMessage
    }

    func start() {
        let directory = (Self.path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        unlink(Self.path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: Self.path.utf8.prefix(buffer.count - 1))
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 16) == 0 else { Darwin.close(listener); return }
        chmod(Self.path, 0o600)
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        acceptSource = source
        source.resume()
    }

    private func acceptAll() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            DispatchQueue.global().async { [weak self] in self?.readMessage(client) }
        }
    }

    /// Reads one line of JSON (up to 16 MB, 5 s at most), then hands it to the main thread.
    private func readMessage(_ fd: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count < 16_000_000 {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if buffer[count - 1] == 0x0A { break }
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Darwin.close(fd)
            return
        }
        let connection = HookConnection(fd: fd)
        let message = UncheckedMessage(object: object)
        DispatchQueue.main.async { [onMessage] in
            MainActor.assumeIsolated { onMessage(message.object, connection) }
        }
    }

    private struct UncheckedMessage: @unchecked Sendable { let object: [String: Any] }
}

// MARK: - Claude state

/// What Claude Code is doing, from its hooks: the current step, permission requests, and finished turns.
@MainActor @Observable
final class ClaudeBridge {
    enum Step: Equatable {
        case thinking, reading, editing, running, searching, browsing, delegating, other

        var symbol: String {
            switch self {
            case .thinking: return "sparkle"
            case .reading: return "doc.text"
            case .editing: return "pencil"
            case .running: return "terminal"
            case .searching: return "magnifyingglass"
            case .browsing: return "globe"
            case .delegating: return "person.2"
            case .other: return "hammer"
            }
        }

        static func of(tool: String) -> Step {
            switch tool {
            case "Read", "NotebookRead": return .reading
            case "Edit", "MultiEdit", "Write", "NotebookEdit": return .editing
            case "Bash", "PowerShell", "BashOutput", "KillShell": return .running
            case "Grep", "Glob", "LS": return .searching
            case "WebFetch", "WebSearch": return .browsing
            case "Agent", "Task", "Workflow": return .delegating
            default: return .other
            }
        }
    }

    struct Request: Identifiable, Equatable {
        let id = UUID()
        var sessionID: String
        var project: String
        var tool: String
        var title: String           // "Run a command", "Edit a file" …
        var detail: String          // the whole command or input, never shortened
        var note: String?           // Claude's description of the command, if any
        var received = Date()

        static func == (a: Request, b: Request) -> Bool { a.id == b.id }
    }

    private(set) var working = false
    private(set) var step: Step = .thinking
    private(set) var requests: [Request] = []

    /// Your Claude plan usage (5-hour and 7-day windows), from Claude Code's status line. Pro/Max only.
    struct Limits: Codable, Equatable {
        struct Window: Codable, Equatable {
            var usedPercent: Double
            var resetsAt: Date?
        }

        var fiveHour: Window?
        var sevenDay: Window?
        var updated: Date
    }

    private(set) var limits: Limits?
    /// Set by the permission view once the whole command has been on screen.
    var fullySeen: Set<UUID> = []

    @ObservationIgnored var onActivityChange: (() -> Void)?
    @ObservationIgnored var onRequestsChange: (() -> Void)?
    @ObservationIgnored var showPeek: ((PeekContent) -> Void)?

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private var server: HookServer?
    @ObservationIgnored private var connections: [UUID: HookConnection] = [:]
    @ObservationIgnored private var fallbacks: [UUID: DispatchWorkItem] = [:]
    @ObservationIgnored private var started: [String: Date] = [:]      // session → turn start
    @ObservationIgnored private var active: [String: (step: Step, at: Date)] = [:]   // sessions at work
    @ObservationIgnored private var staleWork: DispatchWorkItem?
    @ObservationIgnored private let hotKeys = HotKeys(signature: 0x4E544348)     // 'NTCH'
    /// While the teleprompter runs, requests go straight to the terminal so nothing covers the script.
    @ObservationIgnored private var approvalsPaused = false

    /// After this long without an answer in the notch, the request goes back to the terminal.
    static let fallbackDelay: TimeInterval = 90

    init(settings: Settings, preview: Request? = nil, previewLimits: Limits? = nil) {
        self.settings = settings
        if let preview { requests = [preview] }
        if let previewLimits {
            limits = previewLimits
        } else if let data = UserDefaults.standard.data(forKey: Self.limitsKey) {
            limits = try? JSONDecoder().decode(Limits.self, from: data)
        }
    }

    func start() {
        let server = HookServer { [weak self] message, connection in self?.handle(message, connection) }
        server.start()
        self.server = server
    }

    /// Pausing also hands any open request back to the terminal.
    func pauseApprovals(_ paused: Bool) {
        approvalsPaused = paused
        if paused { requests.forEach { answer($0.id, allow: nil) } }
    }

    // MARK: Events

    private func handle(_ message: [String: Any], _ connection: HookConnection) {
        let event = message["hook_event_name"] as? String ?? ""
        let session = message["session_id"] as? String ?? "?"
        let project = ((message["cwd"] as? String ?? "") as NSString).lastPathComponent

        if event == "PermissionRequest" {
            guard settings.claudeApprovals, !approvalsPaused else { connection.close(); return }    // the terminal asks instead
            addRequest(message, session: session, project: project, connection: connection)
            return
        }
        connection.close()

        switch event {
        case "StatusLine":
            updateLimits(from: message["rate_limits"] as? [String: Any])
        case "UserPromptSubmit":
            handBack(session)           // a request left over from an interrupted turn
            started[session] = Date()
            setWorking(session, step: .thinking)
        case "PreToolUse":
            if started[session] == nil { started[session] = Date() }
            setWorking(session, step: .of(tool: message["tool_name"] as? String ?? ""))
        case "Notification":
            let kind = message["notification_type"] as? String ?? ""
            switch kind {
            case "idle_prompt":
                // About a minute after a turn ends. Stop doesn't run when you interrupt Claude,
                // so this is what clears an interrupted session; no bubble (Done already said it).
                handBack(session)
                endWork(session)
            case "permission_prompt" where requests.contains(where: { $0.sessionID == session }):
                break
            case "permission_prompt", "agent_needs_input", "elicitation_dialog":
                showPeek?(PeekContent(symbol: "bubble.left.and.exclamationmark.bubble.right",
                                      title: kind == "permission_prompt" ? "Claude needs your permission" : "Claude is waiting for you",
                                      subtitle: project.isEmpty ? nil : project, duration: 4))
            default:
                break
            }
        case "Stop":
            let duration = started[session].map { Date().timeIntervalSince($0) }
            started[session] = nil
            handBack(session)
            endWork(session)
            if settings.claudeInNotch {
                let time = duration.map(Self.format) ?? ""
                showPeek?(PeekContent(symbol: "checkmark.circle.fill", title: "Done",
                                      subtitle: [project, time].filter { !$0.isEmpty }.joined(separator: " · "),
                                      duration: 4))
            }
        default:
            break
        }
    }

    private func setWorking(_ session: String, step: Step) {
        active[session] = (step, Date())
        refreshActivity()
        // A session that vanishes without any event (closed terminal) is dropped after 15 quiet minutes.
        staleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.active = self.active.filter { Date().timeIntervalSince($0.value.at) < 15 * 60 }
            self.refreshActivity()
        }
        staleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15 * 60 + 1, execute: work)
    }

    private func endWork(_ session: String) {
        active[session] = nil
        refreshActivity()
    }

    /// The pill follows the most recently active session; it stays while any session is working.
    private func refreshActivity() {
        let latest = active.max { $0.value.at < $1.value.at }
        let newWorking = latest != nil
        let newStep = latest?.value.step ?? .thinking
        guard newWorking != working || newStep != step else { return }
        working = newWorking
        step = newStep
        onActivityChange?()
    }

    /// Gives a session's open requests back to Claude Code without deciding (they are stale).
    private func handBack(_ session: String) {
        for request in requests where request.sessionID == session { answer(request.id, allow: nil) }
    }

    // MARK: Permission requests

    private func addRequest(_ message: [String: Any], session: String, project: String, connection: HookConnection) {
        let tool = message["tool_name"] as? String ?? "Tool"
        let input = message["tool_input"] as? [String: Any] ?? [:]
        let (title, detail, note) = Self.describe(tool: tool, input: input)
        let request = Request(sessionID: session, project: project, tool: tool, title: title, detail: detail, note: note)
        requests.append(request)
        connections[request.id] = connection
        connection.watchHangUp { [weak self] in self?.remove(request.id) }

        let fallback = DispatchWorkItem { [weak self] in self?.answer(request.id, allow: nil) }
        fallbacks[request.id] = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fallbackDelay, execute: fallback)

        if requests.count == 1 {
            hotKeys.register([(kVK_ANSI_Y, { [weak self] in self?.answerFirst(allow: true) }),
                              (kVK_ANSI_N, { [weak self] in self?.answerFirst(allow: false) })])
        }
        if started[session] == nil { started[session] = Date() }
        setWorking(session, step: .of(tool: tool))
        onRequestsChange?()
    }

    /// `allow: nil` hands the request back to the terminal without deciding.
    func answer(_ id: UUID, allow: Bool?) {
        guard let connection = connections[id] else { return }
        var reply: Data?
        if let allow {
            let decision: [String: Any] = allow
                ? ["behavior": "allow"]
                : ["behavior": "deny", "message": "Denied from the notch."]
            reply = try? JSONSerialization.data(withJSONObject: [
                "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]])
        }
        connection.reply(reply)
        remove(id)
    }

    /// The shortcuts answer the oldest request, and Allow only once its whole command has been shown.
    private func answerFirst(allow: Bool) {
        guard let first = requests.first else { return }
        if allow && !fullySeen.contains(first.id) { NSSound.beep(); return }
        answer(first.id, allow: allow)
    }

    private func remove(_ id: UUID) {
        connections.removeValue(forKey: id)?.close()
        fallbacks.removeValue(forKey: id)?.cancel()
        fullySeen.remove(id)
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        requests.remove(at: index)
        if requests.isEmpty { hotKeys.unregister() }
        onRequestsChange?()
    }

    // MARK: Text

    /// What the request is about, in full: the command for Bash, the URL for web tools, otherwise the input as JSON.
    static func describe(tool: String, input: [String: Any]) -> (String, String, String?) {
        let note = input["description"] as? String
        switch tool {
        case "Bash", "PowerShell":
            return ("Run a command", input["command"] as? String ?? "", note)
        case "WebFetch":
            return ("Open a web page", input["url"] as? String ?? "", input["prompt"] as? String)
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return (tool == "Write" ? "Write a file" : "Edit a file", json(input), nil)
        default:
            return ("Use \(tool)", json(input), note)
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) min \(total % 60) s" }
        return "\(total / 3600) h \(total % 3600 / 60) min"
    }

    // MARK: Settings lines

    static var helperPath: String { "$HOME/Applications/Custom Notch.app/Contents/Helpers/notch-hook" }

    // MARK: Plan limits

    @ObservationIgnored private static let limitsKey = "claudeLimits"

    /// Claude Code sends `rate_limits` once the session has had its first reply; until then the last known
    /// values stay (they are saved, so they survive a restart).
    private func updateLimits(from object: [String: Any]?) {
        guard let object else { return }
        func window(_ key: String) -> Limits.Window? {
            guard let entry = object[key] as? [String: Any],
                  let used = (entry["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            let resets = (entry["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return Limits.Window(usedPercent: used, resetsAt: resets)
        }
        let new = Limits(fiveHour: window("five_hour") ?? limits?.fiveHour,
                         sevenDay: window("seven_day") ?? limits?.sevenDay, updated: Date())
        guard new.fiveHour != nil || new.sevenDay != nil else { return }
        limits = new
        if let data = try? JSONEncoder().encode(new) { UserDefaults.standard.set(data, forKey: Self.limitsKey) }
    }

    /// The status line entry for ~/.claude/settings.json (it shows the Claude limit in the cards).
    static var statusLineSnippet: String {
        """
        "statusLine": { "type": "command", "command": "\\"\(helperPath)\\" --statusline" }
        """
    }

    /// The block to merge into ~/.claude/settings.json.
    static var settingsSnippet: String {
        let command = "\"\\\"\(helperPath)\\\"\""
        func entry(_ event: String, matcher: Bool, timeout: Int? = nil) -> String {
            let timeoutPart = timeout.map { ", \"timeout\": \($0)" } ?? ""
            let matcherPart = matcher ? "\"matcher\": \"*\", " : ""
            return "    \"\(event)\": [{ \(matcherPart)\"hooks\": [{ \"type\": \"command\", \"command\": \(command)\(timeoutPart) }] }]"
        }
        return """
        {
          "hooks": {
        \(entry("UserPromptSubmit", matcher: false)),
        \(entry("PreToolUse", matcher: true)),
        \(entry("PermissionRequest", matcher: true, timeout: 600)),
        \(entry("Notification", matcher: false)),
        \(entry("Stop", matcher: false))
          }
        }
        """
    }
}

// MARK: - Global shortcuts

/// ⌃⌥ shortcuts, registered only while they are needed (Claude's Allow/Deny, the teleprompter's controls).
/// Carbon hot keys need no Accessibility permission. Each set has its own signature, so one set never
/// answers another set's keys.
@MainActor
final class HotKeys {
    private let signature: OSType
    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    init(signature: OSType) {
        self.signature = signature
    }

    /// Registers ⌃⌥ plus each key code. Keys another app already uses are skipped.
    func register(_ keys: [(key: Int, action: () -> Void)]) {
        guard refs.isEmpty else { return }
        installHandler()
        for (index, entry) in keys.enumerated() {
            let id = UInt32(index + 1)
            actions[id] = entry.action
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(entry.key), UInt32(controlKey | optionKey),
                                             EventHotKeyID(signature: signature, id: id), GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) }
        }
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let keys = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard id.signature == keys.signature, let action = keys.actions[id.id] else { return false }
                action()
                return true
            }
            return handled ? noErr : OSStatus(eventNotHandledErr)     // not ours: the next handler gets it
        }, 1, &type, context, &handler)
    }
}
