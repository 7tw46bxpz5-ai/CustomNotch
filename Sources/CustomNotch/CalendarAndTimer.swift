import SwiftUI
import AppKit
import EventKit

// MARK: - Next calendar event

/// The next event from Calendar (EventKit), read-only. Access is asked only from the tile's button.
@MainActor @Observable
final class CalendarService {
    struct Event: Equatable {
        var title: String
        var start: Date
        var end: Date
        var location: String?
        var isAllDay: Bool
        var calendar: String
    }

    enum Access: Equatable { case notAsked, granted, denied }

    private(set) var access: Access
    private(set) var next: Event?
    /// What's left of today (for the cards); empty means the card shows the Claude limit instead.
    private(set) var today: [Event] = []
    /// Everything that hasn't ended in the next 7 days, from all calendars in the Calendar app (iCloud, Google,
    /// Exchange… whatever is added in System Settings → Internet Accounts), sorted by start.
    private(set) var upcoming: [Event] = []

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private let isPreview: Bool

    init(preview: Event? = nil, today previewToday: [Event]? = nil) {
        isPreview = preview != nil || previewToday != nil
        next = preview
        today = previewToday ?? preview.map { [$0] } ?? []
        upcoming = previewToday ?? preview.map { [$0] } ?? []
        access = isPreview ? .granted : Self.currentAccess()
        guard !isPreview else { return }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notAsked
        default: return .denied        // denied, restricted, or write-only (can't read events)
        }
    }

    func requestAccess() {
        Task {
            _ = try? await store.requestFullAccessToEvents()
            access = Self.currentAccess()
            refresh()
        }
    }

    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    /// The first timed event that hasn't ended in the next 7 days, or else the next all-day event.
    func refresh() {
        guard !isPreview else { return }
        access = Self.currentAccess()
        guard access == .granted else { next = nil; today = []; upcoming = []; return }
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        let predicate = store.predicateForEvents(withStart: start, end: now.addingTimeInterval(7 * 86_400), calendars: nil)
        let upcoming = store.events(matching: predicate)
            .filter { $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
        func make(_ event: EKEvent) -> Event {
            Event(title: event.title ?? "Event", start: event.startDate, end: event.endDate,
                  location: event.location?.components(separatedBy: .newlines).first,
                  isAllDay: event.isAllDay, calendar: event.calendar?.title ?? "")
        }
        next = (upcoming.first { !$0.isAllDay } ?? upcoming.first).map(make)
        let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? now
        // Timed events first, all-day ones after them.
        today = upcoming.filter { $0.startDate < endOfToday }
            .sorted { ($0.isAllDay ? 1 : 0, $0.startDate) < ($1.isAllDay ? 1 : 0, $1.startDate) }
            .map(make)
        self.upcoming = upcoming.map(make)
    }
}

// MARK: - Focus timer

/// A 25-minute focus timer with start/pause and reset. It keeps running while the island is closed
/// (only its end time is stored, no ticking) and shows a peek when it's done.
@MainActor @Observable
final class FocusTimer {
    static let length: TimeInterval = 25 * 60

    private(set) var endDate: Date?
    private(set) var pausedRemaining: TimeInterval = FocusTimer.length

    var isRunning: Bool { endDate != nil }
    var isReset: Bool { !isRunning && pausedRemaining >= Self.length }

    @ObservationIgnored var onFinish: (() -> Void)?
    @ObservationIgnored private var finishWork: DispatchWorkItem?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let isPreview: Bool

    init(preview remaining: TimeInterval? = nil) {
        isPreview = remaining != nil
        if let remaining {
            endDate = Date().addingTimeInterval(remaining)
            return
        }
        // Pick up a session that was running when the app quit.
        let savedEnd = defaults.double(forKey: Keys.end)
        let savedRemaining = defaults.double(forKey: Keys.remaining)
        if savedEnd > 0, Date(timeIntervalSince1970: savedEnd) > Date() {
            endDate = Date(timeIntervalSince1970: savedEnd)
            scheduleFinish()
        } else if savedRemaining > 0 && savedEnd == 0 {
            pausedRemaining = savedRemaining
        }
        // Finish straight away if the session ended while the Mac was asleep.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let end = self.endDate, end <= Date() else { return }
                self.finishWork?.cancel()
                self.finish()
            }
        }
    }

    func remaining(at date: Date) -> TimeInterval {
        endDate.map { max(0, $0.timeIntervalSince(date)) } ?? pausedRemaining
    }

    func startPause() {
        if let endDate {
            pausedRemaining = max(0, endDate.timeIntervalSinceNow)
            self.endDate = nil
            finishWork?.cancel()
        } else {
            if pausedRemaining <= 0 { pausedRemaining = Self.length }
            endDate = Date().addingTimeInterval(pausedRemaining)
            scheduleFinish()
        }
        save()
    }

    func reset() {
        endDate = nil
        pausedRemaining = Self.length
        finishWork?.cancel()
        save()
    }

    private func scheduleFinish() {
        guard !isPreview, let endDate else { return }
        finishWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        finishWork = work
        // Wall-clock time keeps counting while the Mac sleeps (the default clock doesn't).
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, endDate.timeIntervalSinceNow), execute: work)
    }

    private func finish() {
        endDate = nil
        pausedRemaining = Self.length
        save()
        onFinish?()
    }

    private func save() {
        guard !isPreview else { return }
        defaults.set(endDate?.timeIntervalSince1970 ?? 0, forKey: Keys.end)
        defaults.set(pausedRemaining, forKey: Keys.remaining)
    }

    private enum Keys {
        static let end = "focusTimerEnd"
        static let remaining = "focusTimerRemaining"
    }
}

// MARK: - Tile: Calendar

struct CalendarTile: View {
    let calendar: CalendarService
    let cells: Int
    let palette: Palette

    var body: some View {
        Group {
            switch calendar.access {
            case .notAsked:
                message(title: "Next Event", detail: cells > 1 ? "From your calendars." : nil,
                        button: cells > 1 ? "Connect Calendar" : "Connect", action: calendar.requestAccess)
            case .denied:
                message(title: "Access is off", detail: nil, button: cells > 1 ? "Open Settings" : "Settings",
                        action: calendar.openSettings)
            case .granted:
                if let event = calendar.next {
                    TimelineView(.everyMinute) { context in eventView(event, now: context.date) }
                } else {
                    message(title: "No events", detail: "Nothing in the next 7 days.", button: nil, action: {})
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func eventView(_ event: CalendarService.Event, now: Date) -> some View {
        let (when, soon) = Self.relative(event, now: now, short: cells == 1)
        return VStack(alignment: .leading, spacing: 2) {
            header(when, tint: soon ? palette.accent : palette.secondary)
                .padding(.bottom, 2)
            Text(event.title)
                .font(.system(size: cells == 1 ? 11.5 : 13, weight: .semibold))
                .foregroundStyle(palette.text)
                .lineLimit(cells == 1 ? 2 : 1)
            Text(cells == 1 ? Self.start(event) : Self.range(event))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
            if cells > 1, let location = event.location, !location.isEmpty {
                Text(location).font(.system(size: 10.5)).foregroundStyle(palette.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
    }

    /// The small calendar symbol and a word, as the first line of every state (sized like the cards' headers,
    /// so the two line up side by side).
    private func header(_ text: String?, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "calendar").font(.system(size: 10, weight: .semibold))
            if let text { Text(text).font(.system(size: 10.5, weight: .semibold)).lineLimit(1) }
        }
        .foregroundStyle(tint)
        .frame(height: 12)
    }

    /// Same rhythm as an event: header, a title, then a detail line or a button.
    private func message(title: String, detail: String?, button: String?, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            header(cells > 1 ? "Calendar" : nil, tint: palette.secondary)
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: cells == 1 ? 11.5 : 13, weight: .semibold))
                .foregroundStyle(palette.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail).font(.system(size: 10.5)).foregroundStyle(palette.secondary).lineLimit(2)
            }
            if let button {
                Button(action: action) {
                    Text(button).font(.system(size: 10.5, weight: .medium)).foregroundStyle(palette.accent).lineLimit(1)
                }
                .buttonStyle(.plain)
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
    }

    /// "Now" and "In 25 min" are highlighted; later events show the day.
    static func relative(_ event: CalendarService.Event, now: Date, short: Bool = false) -> (String, Bool) {
        if event.start <= now { return ("Now", true) }
        let minutes = Int(event.start.timeIntervalSince(now) / 60)
        if minutes < 60 { return (short ? "\(max(minutes, 1)) min" : "In \(max(minutes, 1)) min", true) }
        let calendar = Calendar.current
        if calendar.isDateInToday(event.start) { return ("Today", false) }
        if calendar.isDateInTomorrow(event.start) { return ("Tomorrow", false) }
        return (event.start.formatted(.dateTime.weekday(.wide)), false)
    }

    static func start(_ event: CalendarService.Event) -> String {
        event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened)
    }

    static func range(_ event: CalendarService.Event) -> String {
        if event.isAllDay { return "All day" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }
}

// MARK: - Focus timer

struct FocusTimerTile: View {
    let timer: FocusTimer
    let cells: Int
    let palette: Palette

    var body: some View {
        // Ticks once a second, only while running and while the island is open.
        TimelineView(.animation(minimumInterval: 1, paused: !timer.isRunning)) { context in
            let remaining = timer.remaining(at: context.date)
            if cells == 1 {
                VStack(spacing: 3) {
                    ring(remaining, size: 48).onTapGesture(perform: timer.startPause)
                    if !timer.isReset {
                        Button("Reset", action: timer.reset)
                            .buttonStyle(.plain)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(palette.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: cells == 3 ? 14 : 11) {
                    ring(remaining, size: 60)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Focus").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.text)
                        // Side by side at three cells, stacked at two.
                        let layout = cells == 3 ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                        layout {
                            pill(timer.isRunning ? "Pause" : (timer.isReset ? "Start" : "Resume"), primary: true,
                                 action: timer.startPause)
                            pill("Reset", primary: false, action: timer.reset)
                                .opacity(timer.isReset ? 0.45 : 1)
                                .disabled(timer.isReset)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func ring(_ remaining: TimeInterval, size: CGFloat) -> some View {
        let fraction = remaining / FocusTimer.length
        let seconds = Int(remaining.rounded(.up))
        return ZStack {
            Circle().stroke(palette.control, lineWidth: 4)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(timer.isRunning ? palette.accent : palette.secondary.opacity(0.6),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.system(size: size > 55 ? 13 : 11, weight: .medium).monospacedDigit())
                .foregroundStyle(palette.text)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
    }

    private func pill(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(primary ? palette.accent : palette.text)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(primary ? palette.controlActive : palette.control, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
