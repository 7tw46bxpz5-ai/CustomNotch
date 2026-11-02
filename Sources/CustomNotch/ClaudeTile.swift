import SwiftUI

/// The Claude limit page of the cards: your plan's 5-hour and weekly usage, with when each window resets.
/// A window whose reset time has passed has rolled over, so it shows as renewed (0 %) instead of the old value.
struct ClaudeLimitCard: View {
    let claude: ClaudeBridge
    let cells: Int
    let palette: Palette

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let limits = claude.limits
        VStack(alignment: .leading, spacing: 3) {
            CardHeader(symbol: "sparkle", title: "Claude", palette: palette) {
                if cells > 1, let limits, limits.fiveHour != nil || limits.sevenDay != nil {
                    // "updated 4 min ago" only where it fits next to the title.
                    ViewThatFits(in: .horizontal) {
                        Text("updated " + Self.age(limits.updated, now: now))
                        Text(Self.age(limits.updated, now: now))
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .font(.system(size: 9.5))
                }
            }
            if let limits, limits.fiveHour != nil || limits.sevenDay != nil {
                VStack(alignment: .leading, spacing: cells == 1 ? 5 : 4) {
                    if let five = limits.fiveHour { row(.fiveHour, five, now: now) }
                    if let week = limits.sevenDay { row(.week, week, now: now) }
                }
            } else {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        Text(cells == 1 ? "Connect in the menu bar."
             : cells == 2 ? "Connect Claude Code in the menu bar. Shows after its next reply."
             : "Connect Claude Code from the menu bar icon. Your usage shows after its next reply.")
            .font(.system(size: 10))
            .foregroundStyle(palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 1)
            .accessibilityLabel("Claude limit: no data yet. Connect Claude Code from the menu bar icon, "
                                + "then it shows after the next reply.")
    }

    // MARK: Rows

    enum Kind {
        case fiveHour, week

        var title: String { self == .fiveHour ? "5 hours" : "Week" }
        var shortTitle: String { self == .fiveHour ? "5h" : "Week" }
        var spoken: String { self == .fiveHour ? "5-hour" : "weekly" }
    }

    /// What a window shows right now.
    struct Reading: Equatable {
        var used: Double          // 0…100
        var renewed: Bool         // the reset time has passed: a fresh window
        var resetsAt: Date?

        init(_ window: ClaudeBridge.Limits.Window, now: Date) {
            if let resets = window.resetsAt, resets <= now {
                used = 0
                renewed = true
                resetsAt = nil
            } else {
                used = min(max(window.usedPercent, 0), 100)
                renewed = false
                resetsAt = window.resetsAt
            }
        }
    }

    private func row(_ kind: Kind, _ window: ClaudeBridge.Limits.Window, now: Date) -> some View {
        let reading = Reading(window, now: now)
        return VStack(alignment: .leading, spacing: cells == 1 ? 2 : 3) {
            if cells == 1 {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(kind.shortTitle)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(palette.secondary)
                        .fixedSize()
                    Spacer(minLength: 0)
                    Text("\(Int(reading.used.rounded()))%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            } else {
                // The fullest line that fits; the reset time is never cut off.
                ViewThatFits(in: .horizontal) {
                    if cells > 2 {
                        line(reading, label: kind.title, reset: resetText(reading, now: now, prefix: true))
                    }
                    line(reading, label: kind.shortTitle, reset: resetText(reading, now: now, prefix: false))
                    line(reading, label: kind.shortTitle, reset: resetText(reading, now: now, prefix: false, symbol: false))
                    line(reading, label: kind.shortTitle,
                         reset: resetText(reading, now: now, prefix: false, symbol: false, compact: true))
                }
            }
            UsageBar(used: reading.used, color: color(reading), palette: palette)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenLabel(kind, reading, now: now))
        .help(Self.spokenLabel(kind, reading, now: now))
    }

    private func percent(_ reading: Reading) -> some View {
        Text("\(Int(reading.used.rounded()))%")
            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(palette.text)
            .fixedSize()
    }

    private func line(_ reading: Reading, label: String, reset: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            percent(reading)
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(palette.secondary)
            Spacer(minLength: 6)
            reset
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(palette.secondary)
        }
        .lineLimit(1)
    }

    /// "resets Wed 21:00" (three cells), "↻ Wed 21:00", or "Renewed" once the window has rolled over.
    private func resetText(_ reading: Reading, now: Date, prefix: Bool, symbol: Bool = true, compact: Bool = false) -> Text {
        if reading.renewed { return Text("Renewed") }
        guard let resets = reading.resetsAt else { return Text("") }
        let time = Self.resetTime(resets, now: now, compact: compact)
        if prefix { return Text("resets " + time) }
        if !symbol { return Text(time) }
        return Text(Image(systemName: "arrow.clockwise")).font(.system(size: 8, weight: .semibold)) + Text(" " + time)
    }

    private func color(_ reading: Reading) -> Color {
        reading.used >= 95 ? palette.critical : reading.used >= 80 ? palette.warning : palette.accent
    }

    // MARK: Text

    /// "23:41" today, otherwise with the weekday ("Wed 21:00"), in the system's format. `compact` keeps only
    /// the weekday for a later day (never a bare time, which would read as today).
    static func resetTime(_ date: Date, now: Date, compact: Bool = false) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDate(date, inSameDayAs: now) { return time }
        let weekday = date.formatted(.dateTime.weekday(.abbreviated))
        return compact ? weekday : weekday + " " + time
    }

    /// "now", "4 min ago", "2 h ago", "3 d ago".
    static func age(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes) min ago" }
        if minutes < 48 * 60 { return "\(minutes / 60) h ago" }
        return "\(minutes / 1440) d ago"
    }

    /// "Claude 5-hour limit, 23 percent used, resets 23:41".
    static func spokenLabel(_ kind: Kind, _ reading: Reading, now: Date) -> String {
        let name = "Claude \(kind.spoken) limit"
        if reading.renewed { return "\(name) renewed, 0 percent used" }
        var text = "\(name), \(Int(reading.used.rounded())) percent used"
        if let resets = reading.resetsAt { text += ", resets " + resetTime(resets, now: now) }
        return text
    }
}

/// A slim capsule meter, like the usage bars in Apple's Settings.
private struct UsageBar: View {
    let used: Double
    let color: Color
    let palette: Palette

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.secondary.opacity(palette.isDark ? 0.25 : 0.18))
                if used > 0 {
                    Capsule().fill(color).frame(width: max(4, geometry.size.width * used / 100))
                }
            }
        }
        .frame(height: 4)
    }
}
