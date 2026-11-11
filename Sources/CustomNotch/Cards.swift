import SwiftUI

/// The swipeable field: cards side by side, flipped with a two-finger swipe on the trackpad (they snap
/// into place), with page dots like iOS. Order: the Claude limit, upcoming events, batteries, Slack.
/// Lists inside a card scroll vertically; a horizontal swipe still flips the cards.
struct CardsTile: View {
    let services: Services
    let cells: Int
    let palette: Palette

    enum Card: Int, CaseIterable, Identifiable {
        case claude, agenda, batteries, slack
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
                card(Card(rawValue: snapshotPage) ?? .claude)
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
            PageDots(count: Card.allCases.count, current: staticRendering ? snapshotPage : (page ?? 0), palette: palette,
                     select: { index in withAnimation(.snappy) { page = index } })
                .padding(.bottom, 1)
        }
        .frame(width: width, height: Metrics.tileHeight)
    }

    @ViewBuilder
    private func card(_ card: Card) -> some View {
        switch card {
        case .agenda:
            AgendaCard(calendar: services.calendar, cells: cells, palette: palette)
        case .claude:
            ClaudeLimitCard(claude: services.claude, cells: cells, palette: palette)
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
    /// When set, clicking a dot goes to that page (like UIPageControl).
    var select: ((Int) -> Void)? = nil

    var body: some View {
        HStack(spacing: select == nil ? 5 : 0) {
            ForEach(0..<count, id: \.self) { index in
                let dot = Circle()
                    .fill(index == current ? palette.text.opacity(0.8) : palette.secondary.opacity(0.35))
                    .frame(width: 4.5, height: 4.5)
                if let select {
                    dot
                        .frame(width: 9.5, height: 9)
                        .contentShape(Rectangle())
                        .onTapGesture { select(index) }
                } else {
                    dot
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

/// Small header shared by the cards: symbol, title, and something on the right.
struct CardHeader<Trailing: View>: View {
    let symbol: String
    let title: String
    var titleColor: Color? = nil
    let palette: Palette
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            if !title.isEmpty {
                Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(titleColor ?? palette.secondary)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
            trailing
        }
        .foregroundStyle(palette.secondary)
        .lineLimit(1)
        .frame(height: 12)
    }
}

struct LinkButton: View {
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

/// The body of a card below its header: scrolls vertically when there's more than fits (the header stays),
/// and fades out above the page dots. Snapshots can't draw a scroll view, so they get the first rows, clipped.
struct CardList<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.staticRendering) private var staticRendering

    /// The list stops this far above the tile's bottom edge, so it never runs under the page dots.
    static var bottomClearance: CGFloat { 9 }
    /// Rows fade out over this distance at the bottom: there's more to scroll to.
    static var fade: CGFloat { 7 }

    var body: some View {
        Group {
            if staticRendering {
                VStack(alignment: .leading, spacing: 0) { content }
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) { content }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, Self.fade)
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.fade)
            }
        }
        .padding(.bottom, Self.bottomClearance)
    }
}

// MARK: - Calendar

/// What's coming up in the next 7 days, from every calendar in the Calendar app, grouped by day.
struct AgendaCard: View {
    let calendar: CalendarService
    let cells: Int
    let palette: Palette

    var body: some View {
        Group {
            switch calendar.access {
            case .notAsked:
                notice(cells == 1 ? "See what's next." : "See your next events here.",
                       link: "Connect Calendar", action: calendar.requestAccess)
            case .denied:
                notice(cells == 1 ? "No access." : "Custom Notch can't read your calendar.",
                       link: "Open Settings", action: calendar.openSettings)
            case .granted:
                TimelineView(.everyMinute) { context in agenda(now: context.date) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
    }

    private func notice(_ text: String, link: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            CardHeader(symbol: "calendar", title: cells == 1 ? "" : "Calendar", palette: palette) { EmptyView() }
            Text(text).font(.system(size: 10)).foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LinkButton(title: link, palette: palette, action: action)
        }
    }

    // MARK: Agenda

    struct Day: Identifiable {
        var date: Date          // start of the day
        var events: [CalendarService.Event]
        var id: Date { date }
    }

    /// Events that haven't ended, by day. One still running from an earlier day counts for today.
    /// Timed events first in each day, all-day ones after them (like the cards always did).
    static func days(_ events: [CalendarService.Event], now: Date) -> [Day] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var days: [Date: [CalendarService.Event]] = [:]
        for event in events where event.end > now {
            days[max(calendar.startOfDay(for: event.start), today), default: []].append(event)
        }
        return days.keys.sorted().map { date in
            Day(date: date, events: days[date]!.sorted {
                ($0.isAllDay ? 1 : 0, $0.start) < ($1.isAllDay ? 1 : 0, $1.start)
            })
        }
    }

    /// "Today", "Tomorrow", then the weekday and date ("Wed 5 Nov").
    static func dayTitle(_ date: Date, short: Bool = false) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if short { return date.formatted(.dateTime.weekday(.abbreviated)) }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func agenda(now: Date) -> some View {
        let days = Self.days(calendar.upcoming, now: now)
        // The next event: the first timed one that hasn't ended, or else the first all-day one.
        let all = days.flatMap(\.events)
        let next = all.first { !$0.isAllDay } ?? all.first
        let soon = next.map { CalendarTile.relative($0, now: now, short: cells == 1) }.flatMap { $0.1 ? $0.0 : nil }
        let firstTitle = days.first.map { Self.dayTitle($0.date, short: cells == 1) } ?? (cells == 1 ? "" : "Calendar")
        return VStack(alignment: .leading, spacing: 3) {
            if cells == 1, let soon {
                // One cell: the countdown is the header ("25 min", "Now").
                CardHeader(symbol: "calendar", title: soon, titleColor: palette.accent, palette: palette) { EmptyView() }
            } else {
                CardHeader(symbol: "calendar", title: firstTitle, palette: palette) {
                    if let soon {
                        Text(soon).font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.accent)
                    }
                }
            }
            if days.isEmpty {
                Text(cells == 1 ? "No upcoming events" : "No events in the next 7 days")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.secondary)
                    .padding(.top, 2)
            } else {
                CardList {
                    ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                        if index > 0 {
                            Text(Self.dayTitle(day.date, short: cells == 1))
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(palette.secondary)
                                .lineLimit(1)
                                .padding(.top, 4)
                                .padding(.bottom, 2)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(Array(day.events.enumerated()), id: \.offset) { _, event in
                            row(event, isNext: event == next, now: now)
                                .padding(.vertical, 1.5)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ event: CalendarService.Event, isNext: Bool, now: Date) -> some View {
        let running = !event.isAllDay && event.start <= now
        let timeColor = isNext && running ? palette.accent : palette.secondary
        // A bar like Calendar's, in the accent for the next event.
        let bar = RoundedRectangle(cornerRadius: 1.5)
            .fill(isNext ? palette.accent : palette.secondary.opacity(0.45))
            .frame(width: 3)
        let title = Text(event.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.text)
        if cells == 1 {
            // Narrow: title (up to two lines) over the start time.
            HStack(alignment: .top, spacing: 6) {
                bar
                VStack(alignment: .leading, spacing: 0) {
                    title.lineLimit(2)
                    ViewThatFits(in: .horizontal) {
                        ForEach(details(event, running: running), id: \.self) { Text($0) }
                    }
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(timeColor)
                    .lineLimit(1)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        } else {
            // Wider: one line per event, so more of the day fits; the time on the right.
            HStack(alignment: .center, spacing: 6) {
                bar.frame(height: 14)
                title.lineLimit(1).layoutPriority(1)
                Spacer(minLength: 6)
                // The title comes first; the time keeps room for its shortest form and shows the fullest
                // one that fits in what's left.
                let choices = details(event, running: running)
                ZStack(alignment: .trailing) {
                    Text(choices.last ?? "").fixedSize().hidden()       // never narrower than the shortest
                    ViewThatFits(in: .horizontal) {
                        ForEach(choices, id: \.self) { Text($0) }
                    }
                }
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(timeColor)
                .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The time of a row, fullest first: three cells "14:30 – 15:00 · Studio B", two cells "14:30";
    /// a running event says until when. The last choice is always short.
    private func details(_ event: CalendarService.Event, running: Bool) -> [String] {
        let end = event.end.formatted(date: .omitted, time: .shortened)
        var list: [String] = []
        if cells == 3 {
            let range = running ? "Now – " + end : CalendarTile.range(event)
            if let location = event.location, !location.isEmpty { list.append(range + " · " + location) }
            list.append(range)
        }
        list.append(running ? "until " + end : CalendarTile.start(event))
        if running { list.append("Now") }
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }      // ViewThatFits needs distinct choices
    }
}

// MARK: - Batteries

struct BatteriesCard: View {
    let batteries: BatteryService
    let cells: Int
    let palette: Palette

    var body: some View {
        let rings = Self.shown(Self.rings(batteries.devices), limit: cells == 3 ? 5 : cells == 2 ? 3 : 1)
        VStack(alignment: .leading, spacing: 5) {
            CardHeader(symbol: "battery.75percent", title: cells == 1 ? "" : "Batteries", palette: palette) {
                if cells > 1 { bluetoothStatus }
            }
            if rings.isEmpty {
                Text("No battery to show.").font(.system(size: 10)).foregroundStyle(palette.secondary)
            } else {
                HStack(spacing: cells == 1 ? 0 : 12) {
                    ForEach(rings) { ring in BatteryRing(ring: ring, palette: palette) }
                }
                .frame(maxWidth: .infinity, alignment: cells == 1 ? .center : .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    /// When not all fit, the fullest ones give way: the lowest battery is always shown. They keep their order.
    static func shown(_ rings: [Ring], limit: Int) -> [Ring] {
        guard rings.count > limit else { return rings }
        let keep = Set(rings.indices.sorted { (rings[$0].level, $0) < (rings[$1].level, $1) }.prefix(limit))
        return rings.indices.filter(keep.contains).map { rings[$0] }
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
        VStack(spacing: 2) {
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
                        .offset(x: 12, y: -12)
                }
            }
            .frame(width: 30, height: 30)
            Text("\(ring.level)%").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(palette.text)
        }
        .help(ring.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ring.label), \(ring.level) percent\(ring.charging ? ", charging" : "")")
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
                LinkButton(title: cells == 1 ? "Connect" : "Connect Slack", palette: palette, action: connect)
            case .loading where slack.messages.isEmpty:
                Text("Loading…").font(.system(size: 10)).foregroundStyle(palette.secondary)
            case .failed(let reason) where slack.messages.isEmpty:
                Text(reason).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(2)
                LinkButton(title: "Reconnect", palette: palette, action: connect)
            default:
                if slack.messages.isEmpty {
                    Text(cells == 1 ? "No new messages" : "No new messages since yesterday.")
                        .font(.system(size: 10)).foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    CardList {
                        ForEach(slack.messages) { message in
                            row(message)
                                .padding(.vertical, 2)
                                .onTapGesture { slack.open(message) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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
