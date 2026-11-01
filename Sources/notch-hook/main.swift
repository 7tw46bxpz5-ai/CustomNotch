// notch-hook: called by Claude Code. It passes the JSON it gets on stdin to Custom Notch over a local
// Unix socket, as one line.
//
// - As a hook, for a PermissionRequest it waits for your answer in the notch and prints it for Claude Code;
//   for every other event it exits right away.
// - With --statusline (Claude Code's status line command) it passes on the session data, including your
//   plan limits, and prints a short status line: model · context · 5-hour and weekly usage.
// - If Custom Notch isn't running, or anything goes wrong, it prints nothing (or just the status line) and
//   exits 0, so Claude Code carries on and asks in the terminal as usual. It never approves anything itself.
import Foundation

signal(SIGPIPE, SIG_IGN)

let statusLineMode = CommandLine.arguments.contains("--statusline")
let input = FileHandle.standardInput.readDataToEndOfFile()
guard var message = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else {
    if statusLineMode { print("") }
    exit(0)
}
if statusLineMode { message["hook_event_name"] = "StatusLine" }
let event = message["hook_event_name"] as? String ?? ""

/// The status line Claude Code shows under the prompt.
func statusText(_ data: [String: Any]) -> String {
    func percent(_ value: Any?) -> Int? { (value as? NSNumber).map { Int($0.doubleValue.rounded()) } }
    var parts: [String] = []
    if let model = (data["model"] as? [String: Any])?["display_name"] as? String { parts.append(model) }
    if let context = percent((data["context_window"] as? [String: Any])?["used_percentage"]) {
        parts.append("context \(context)%")
    }
    if let limits = data["rate_limits"] as? [String: Any] {
        if let five = percent((limits["five_hour"] as? [String: Any])?["used_percentage"]) { parts.append("5h \(five)%") }
        if let week = percent((limits["seven_day"] as? [String: Any])?["used_percentage"]) { parts.append("week \(week)%") }
    }
    return parts.joined(separator: " · ")
}

/// Connects to the app; -1 if it isn't running.
func connectToApp() -> Int32 {
    // CUSTOM_NOTCH_SOCKET overrides the path (used only for testing).
    let path = ProcessInfo.processInfo.environment["CUSTOM_NOTCH_SOCKET"]
        ?? NSHomeDirectory() + "/Library/Application Support/Custom Notch/claude.sock"
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return -1 }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: path.utf8)
        buffer[path.utf8.count] = 0
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { close(fd); return -1 }
    return fd
}

let fd = connectToApp()
if fd >= 0, var line = try? JSONSerialization.data(withJSONObject: message) {
    line.append(0x0A)
    var sent = 0
    while sent < line.count {
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress! + sent, line.count - sent) }
        guard written > 0 else { break }
        sent += written
    }
}

if statusLineMode {
    print(statusText(message))
    exit(0)
}
guard fd >= 0, event == "PermissionRequest" else { exit(0) }    // app not running: Claude Code continues normally

// Wait for the answer (the app closes the connection when you decide). Stop well before Claude Code's
// 600-second hook timeout so it can still ask in the terminal.
var timeout = timeval(tv_sec: 590, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
var reply = Data()
var buffer = [UInt8](repeating: 0, count: 4096)
while true {
    let count = read(fd, &buffer, buffer.count)
    if count <= 0 { break }
    reply.append(contentsOf: buffer[0..<count])
}
// Only pass on a well-formed answer.
if !reply.isEmpty, (try? JSONSerialization.jsonObject(with: reply)) != nil {
    FileHandle.standardOutput.write(reply)
}
exit(0)
