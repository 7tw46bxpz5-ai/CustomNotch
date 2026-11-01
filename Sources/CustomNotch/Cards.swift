import SwiftUI

/// The swipeable field: cards side by side, flipped with a two-finger swipe on the trackpad (they snap
/// into place), with page dots like iOS. Order: today's calendar (or the Claude limit when nothing is
/// left today), batteries, Slack.
struct CardsTile: View {
    let services: Services
    let cells: Int
    let palette: Palette

    enum Card: Int, CaseIterable, Identifiable {
        case agenda, batteries, slack
        var id: Int { rawValue }
    }

    @State private var page: Int? = 0
    @Environment(\.staticRendering) private var staticRendering
    @Environment(\.cardPage) private var snapshotPage

    var body: some View {
        let width = Metrics.tileWidth(cells: cells)
        ZStack(alignment: .bottom) {
            if staticRendering {
                // Snapshots can't draw a scroll view (an AppKit view): show one card.
                card(Card(rawValue: snapshotPage) ?? .agenda)
                    .frame(width: width, height: Metrics.tileHeight, alignment: .topLeading)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(Card.allCases) { card in
                            self.card(card)
                                .frame(width: width, height: Metrics.tileHeight, alignment: .topLeading)
                                .id(card.rawValue)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.never)
                .scrollPosition(id: $page)
            }
            PageDots(count: Card.allCases.count, current: staticRendering ? snapshotPage : (page ?? 0), palette: palette)
                .padding(.bottom, 3)
        }
        .frame(width: width, height: Metrics.tileHeight)
    }

    @ViewBuilder
    private func card(_ card: Card) -> some View {
        switch card {
        case .agenda:
            AgendaCard(calendar: services.calendar, claude: services.claude, cells: cells, palette: palette)
        case .batteries:
            BatteriesCard(batteries: services.batteries, cells: cells, palette: palette)
        case .slack:
            SlackCard(slack: services.slack, cells: cells, palette: palette, connect: services.connectSlack)
        }
    }
}

struct PageDots: View {
    let count: Int
    let current: Int
    let palette: Palette

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? palette.text.opacity(0.8) : palette.secondary.opacity(0.35))
                    .frame(width: 4.5, height: 4.5)
            }
        }
        .animation(.easeOut(duration: 0.2), value: current)
    }
}

/// Small header shared by the cards: symbol, title, and something on the right.
private struct CardHeader<Trailing: View>: View {
    let symbol: String
    let title: String
    let palette: Palette
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(title).font(.system(size: 10.5, weight: .semibold))
            Spacer(minLength: 4)
            trailing
        }
        .foregroundStyle(palette.secondary)
        .lineLimit(1)
        .frame(height: 12)
    }
}

private struct LinkButton: View {
    let title: String
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.accent)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Calendar, or the Claude limit

struct AgendaCard: View {
    let calendar: CalendarService
    let claude: ClaudeBridge
    let cells: Int
    let palette: Palette

    var body: some View {
        let showEvents = calendar.access == .granted && !calendar.today.isEmpty
        let connect: (() -> Void)? = calendar.access == .notAsked ? { calendar.requestAccess() } : nil
        return Group {
            if showEvents {
                TimelineView(.everyMinute) { context in events(now: context.date) }
            } else {
                ClaudeLimitView(limits: claude.limits, cells: cells, palette: palette, connectCalendar: connect)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
    }

    private func events(now: Date) -> some View {
        let list = calendar.today
        let shown = Array(list.prefix(cells == 1 ? 1 : 2))
        let relative: (String, Bool)? = list.first.map { CalendarTile.relative($0, now: now) }
        return VStack(alignment: .leading, spacing: 3) {
            CardHeader(symbol: "calendar", title: cells == 1 ? "Next" : "Today", palette: palette) {
                if cells > 1, let relative {
                    Text(relative.0)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(relative.1 ? palette.accent : palette.secondary)
                }
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { index, event in
                row(event, isNext: index == 0)
            }
            if cells > 1 && list.count > 2 {
                Text("+\(list.count - 2) more today").font(.system(size: 9.5)).foregroundStyle(palette.secondary)
            }
        }
    }

    private func row(_ event: CalendarService.Event, isNext: Bool) -> some View {
        HStack(spacing: 7) {
            // A bar like Calendar's, in the accent for the next event.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isNext ? palette.accent : palette.secondary.opacity(0.45))
                .frame(width: 3, height: cells == 1 ? 34 : 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(event.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(cells == 1 ? 2 : 1)
                Text(detail(event))
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func detail(_ event: CalendarService.Event) -> String {
        if cells == 1 { return CalendarTile.start(event) }
        return [CalendarTile.range(event), event.location ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Your Claude plan usage: the 5-hour and the weekly window, with when each resets.
struct ClaudeLimitView: View {
    let limits: ClaudeBridge.Limits?
    let cells: Int
    let palette: Palette
    let connectCalendar: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardHeader(symbol: "sparkle", title: cells == 1 ? "Claude" : "Claude limit", palette: palette) {
                if let connectCalendar, cells > 1 {
                    LinkButton(title: "Connect Calendar", palette: palette, action: connectCalendar)
                } else if let limits, cells == 3 {
                    TimelineView(.everyMinute) { context in
                        Text(Self.age(limits.updated, now: context.date)).font(.system(size: 9.5))
                    }
                }
            }
            if let limits, limits.fiveHour != nil || limits.sevenDay != nil {
                if let five = limits.fiveHour { row(cells == 1 ? "5 h" : "5 hours", five, weekly: false) }
                if let week = limits.sevenDay { row("Week", week, weekly: true) }
            } else {
                Text(cells == 1 ? "No data yet" : "Shows after your next Claude Code reply, once the status line is set up "
                     + "(menu → Claude Code).")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ label: String, _ window: ClaudeBridge.Limits.Window, weekly: Bool) -> some View {
        let used = min(max(window.usedPercent, 0), 100)
        let color = used >= 95 ? palette.critical : used >= 80 ? palette.warning : palette.accent
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(palette.text)
                Spacer(minLength: 2)
                Text("\(Int(used.rounded()))%").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(palette.text)
                if cells > 1, let resets = window.resetsAt {
                    Text("· " + Self.resetText(resets, weekly: weekly)).font(.system(size: 9.5)).foregroundStyle(palette.secondary)
                }
            }
            .lineLimit(1)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.secondary.opacity(palette.isDark ? 0.25 : 0.18))
                    Capsule().fill(color).frame(width: max(4, geometry.size.width * used / 100))
                }
            }
            .frame(height: 4)
        }
    }

    /// "updated now", "updated 4 min ago", "updated 2 h ago".
    static func age(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "updated now" }
        if minutes < 60 { return "updated \(minutes) min ago" }
        return "updated \(minutes / 60) h ago"
    }

    /// "resets 18:00" for today, otherwise with the weekday.
    static func resetText(_ date: Date, weekly: Bool) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "resets \(time)" }
        return "resets " + date.formatted(.dateTime.weekday(.abbreviated)) + " \(time)"
    }
}

// MARK: - Batteries

struct BatteriesCard: View {
    let batteries: BatteryService
    let cells: Int
    let palette: Palette

    var body: some View {
        let limit = cells == 3 ? 4 : cells == 2 ? 3 : 1
        let rings = Self.rings(batteries.devices)
        VStack(alignment: .leading, spacing: 6) {
            CardHeader(symbol: "battery.75percent", title: "Batteries", palette: palette) {
                if cells > 1 { bluetoothStatus }
            }
            if rings.isEmpty {
                Text("No battery to show.").font(.system(size: 10)).foregroundStyle(palette.secondary)
            } else {
                HStack(spacing: cells == 1 ? 0 : 12) {
                    ForEach(rings.prefix(limit)) { ring in BatteryRing(ring: ring, palette: palette) }
                }
                .frame(maxWidth: .infinity, alignment: cells == 1 ? .center : .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var bluetoothStatus: some View {
        switch batteries.bluetooth {
        case .off:
            LinkButton(title: cells == 3 ? "Show AirPods" : "AirPods", palette: palette, action: batteries.enableBluetooth)
        case .denied:
            LinkButton(title: "Allow Bluetooth", palette: palette, action: batteries.openBluetoothSettings)
        case .unavailable:
            Text("Bluetooth off").font(.system(size: 9.5))
        case .waiting, .on:
            EmptyView()
        }
    }

    struct Ring: Identifiable {
        var id: String
        var symbol: String
        var level: Int
        var charging: Bool
        var label: String
    }

    /// One ring per battery; AirPods get a second ring for the case.
    static func rings(_ devices: [BatteryService.Device]) -> [Ring] {
        devices.flatMap { device -> [Ring] in
            guard let level = device.level else { return [] }
            var list = [Ring(id: device.id, symbol: device.symbol, level: level, charging: device.charging, label: device.name)]
            if let caseLevel = device.caseLevel {
                list.append(Ring(id: device.id + "-case", symbol: "airpods.chargingcase", level: caseLevel,
                                 charging: false, label: "Case"))
            }
            return list
        }
    }
}

/// Like Apple's Batteries widget: a ring with the device inside, the level below.
struct BatteryRing: View {
    let ring: BatteriesCard.Ring
    let palette: Palette

    var body: some View {
        let color = ring.level <= 10 ? palette.critical : ring.level <= 20 ? palette.warning : palette.accent
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(palette.secondary.opacity(palette.isDark ? 0.25 : 0.18), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: CGFloat(ring.level) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: ring.symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.text)
                if ring.charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(palette.accent)
                        .offset(x: 13, y: -13)
                }
            }
            .frame(width: 32, height: 32)
            Text("\(ring.level)%").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(palette.text)
        }
        .help(ring.label)
    }
}

// MARK: - Slack

struct SlackCard: View {
    let slack: SlackService
    let cells: Int
    let palette: Palette
    let connect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            CardHeader(symbol: "number", title: "Slack", palette: palette) {
                if cells > 1, let team = slack.team { Text(team).font(.system(size: 9.5)) }
            }
            switch slack.state {
            case .notConnected:
                Text(cells == 1 ? "Not connected" : "See your newest messages here.")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
                LinkButton(title: "Connect Slack", palette: palette, action: connect)
            case .loading where slack.messages.isEmpty:
                Text("Loading…").font(.system(size: 10)).foregroundStyle(palette.secondary)
            case .failed(let reason) where slack.messages.isEmpty:
                Text(reason).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(2)
                LinkButton(title: "Reconnect", palette: palette, action: connect)
            default:
                if slack.messages.isEmpty {
                    Text("No new messages since yesterday.").font(.system(size: 10)).foregroundStyle(palette.secondary)
                }
                ForEach(slack.messages.prefix(cells == 1 ? 1 : 2)) { message in
                    row(message).onTapGesture { slack.open(message) }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
    }

    private func row(_ message: SlackService.Message) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(message.author).font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.text)
                if cells > 1 && message.channel != message.author {
                    Text(message.channel).font(.system(size: 10)).foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 2)
                if cells > 1 {
                    Text(Self.time(message.date)).font(.system(size: 9.5).monospacedDigit()).foregroundStyle(palette.secondary)
                }
            }
            Text(message.text).font(.system(size: 10)).foregroundStyle(palette.secondary)
        }
        .lineLimit(1)
        .contentShape(Rectangle())
    }

    static func time(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
}

// MARK: - Snapshot page

private struct CardPageKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    /// Which card a snapshot shows (snapshots can't scroll).
    var cardPage: Int {
        get { self[CardPageKey.self] }
        set { self[CardPageKey.self] = newValue }
    }
}
