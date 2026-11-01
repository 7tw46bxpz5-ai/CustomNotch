import AppKit
import Security

/// The newest Slack messages, read with your own Slack user token (kept in your keychain). It talks only to
/// slack.com, and only when the island opens (at most once a minute). Your own messages are left out.
///
/// The token needs two user scopes: `search:read` (the newest messages) and `users:read` (names).
@MainActor @Observable
final class SlackService {
    struct Message: Identifiable, Equatable {
        var id: String
        var author: String
        var channel: String         // "#design", or the person's name for a direct message
        var text: String
        var date: Date
        var link: URL?
    }

    enum State: Equatable { case notConnected, loading, ready, failed(String) }

    private(set) var state: State = .notConnected
    private(set) var messages: [Message] = []
    private(set) var team: String?

    @ObservationIgnored var onOpenedApp: (() -> Void)?
    @ObservationIgnored private let session = URLSession(configuration: .ephemeral)
    @ObservationIgnored private var userID: String?
    @ObservationIgnored private var names: [String: String] = [:]
    @ObservationIgnored private var lastFetch = Date.distantPast
    @ObservationIgnored private let isPreview: Bool

    init(preview: [Message]? = nil, team: String? = nil) {
        isPreview = preview != nil
        if let preview {
            messages = preview
            self.team = team
            state = .ready
        } else if Keychain.token != nil {
            state = .loading
        }
    }

    // MARK: Connecting

    /// Checks the token with Slack and keeps it in the keychain if it works. Returns an error to show, or nil.
    func connect(token: String) async -> String? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("xox") else { return "That doesn't look like a Slack token (it starts with xoxp-)." }
        do {
            let auth = try await call("auth.test", token: token)
            Keychain.token = token
            userID = auth["user_id"] as? String
            team = auth["team"] as? String
            lastFetch = .distantPast
            await refresh()
            return nil
        } catch let error as SlackError {
            return error.message
        } catch {
            return "Couldn't reach Slack. Check your connection and try again."
        }
    }

    func disconnect() {
        Keychain.token = nil
        messages = []
        team = nil
        userID = nil
        names = [:]
        state = .notConnected
    }

    func refreshIfStale() {
        guard !isPreview, Keychain.token != nil, Date().timeIntervalSince(lastFetch) > 60 else { return }
        Task { await refresh() }
    }

    func open(_ message: Message) {
        if let link = message.link { NSWorkspace.shared.open(link) }
        onOpenedApp?()
    }

    // MARK: Fetching

    private func refresh() async {
        guard let token = Keychain.token else { state = .notConnected; return }
        lastFetch = Date()
        if messages.isEmpty { state = .loading }
        do {
            if userID == nil {
                let auth = try await call("auth.test", token: token)
                userID = auth["user_id"] as? String
                team = auth["team"] as? String
            }
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
            let day = yesterday.formatted(.iso8601.year().month().day())
            let result = try await call("search.messages", token: token, parameters: [
                "query": "after:\(day)", "sort": "timestamp", "sort_dir": "desc", "count": "20"])
            let matches = (result["messages"] as? [String: Any])?["matches"] as? [[String: Any]] ?? []
            var list: [Message] = []
            for match in matches where (match["user"] as? String) != userID {
                guard let ts = match["ts"] as? String, let seconds = Double(ts) else { continue }
                let channel = match["channel"] as? [String: Any] ?? [:]
                let user = match["user"] as? String
                let author = await name(of: user, token: token) ?? (match["username"] as? String ?? "Someone")
                let isDirect = channel["is_im"] as? Bool ?? false
                let channelName = isDirect ? author : "#" + (channel["name"] as? String ?? "channel")
                list.append(Message(id: ts + (channel["id"] as? String ?? ""), author: author, channel: channelName,
                                    text: Self.plainText(match["text"] as? String ?? ""),
                                    date: Date(timeIntervalSince1970: seconds),
                                    link: (match["permalink"] as? String).flatMap(URL.init(string:))))
                if list.count == 5 { break }
            }
            messages = list
            state = .ready
        } catch let error as SlackError {
            state = .failed(error.message)
        } catch {
            if messages.isEmpty { state = .failed("Couldn't reach Slack.") }
        }
    }

    /// A person's display name (cached).
    private func name(of user: String?, token: String) async -> String? {
        guard let user else { return nil }
        if let known = names[user] { return known }
        guard let info = try? await call("users.info", token: token, parameters: ["user": user]),
              let profile = (info["user"] as? [String: Any])?["profile"] as? [String: Any] else { return nil }
        let name = [profile["display_name"], profile["real_name"]].compactMap { $0 as? String }.first { !$0.isEmpty }
        names[user] = name
        return name
    }

    private struct SlackError: Error {
        var message: String
    }

    private func call(_ method: String, token: String, parameters: [String: String] = [:]) async throws -> [String: Any] {
        var components = URLComponents(string: "https://slack.com/api/\(method)")!
        if !parameters.isEmpty { components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: request)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SlackError(message: "Slack sent an unexpected answer.")
        }
        guard object["ok"] as? Bool == true else {
            let code = object["error"] as? String ?? "unknown"
            switch code {
            case "invalid_auth", "not_authed", "token_revoked", "account_inactive":
                throw SlackError(message: "Slack didn't accept the token (\(code)).")
            case "missing_scope":
                throw SlackError(message: "The token needs the scopes search:read and users:read.")
            case "not_allowed_token_type":
                throw SlackError(message: "Use a user token (xoxp-), not a bot token.")
            default:
                throw SlackError(message: "Slack error: \(code)")
            }
        }
        return object
    }

    /// Slack's markup to plain text: <@U123> mentions, <#C1|name> channels, <url|label> links, &amp; entities.
    static func plainText(_ text: String) -> String {
        var result = text
        let patterns: [(String, String)] = [
            ("<#[A-Z0-9]+\\|([^>]+)>", "#$1"),
            ("<@[A-Z0-9]+\\|([^>]+)>", "@$1"),
            ("<@[A-Z0-9]+>", "@someone"),
            ("<!(here|channel|everyone)[^>]*>", "@$1"),
            ("<(https?://[^|>]+)\\|([^>]+)>", "$2"),
            ("<(https?://[^>]+)>", "$1"),
        ]
        for (pattern, template) in patterns {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return result.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "\n", with: " ")
    }
}

/// The Slack token in your login keychain (only this app reads it).
enum Keychain {
    private static let service = "local.customnotch.slack"
    private static let account = "user-token"

    static var token: String? {
        get {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: account, kSecReturnData as String: true,
                                        kSecMatchLimit as String: kSecMatchLimitOne]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: account]
            SecItemDelete(query as CFDictionary)
            guard let newValue, let data = newValue.data(using: .utf8) else { return }
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
