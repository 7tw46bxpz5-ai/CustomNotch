import SwiftUI
import Foundation

/// Weather from Open-Meteo (free, no key): now, the chance of rain hour by hour, and the week.
/// The only data sent is the city name (to find it) and its coordinates (to get the forecast).
@MainActor @Observable
final class WeatherService {
    struct Report: Codable, Equatable {
        var temperature: Double
        var code: Int
        var isDay: Bool
        var high: Double
        var low: Double
        var fetched: Date
        var location: WeatherLocation
        /// Hour by hour from the hour before the fetch, 48 of them. Missing in reports cached by older versions.
        var hours: [Hour]? = nil
        /// Today first, up to 7 days. Missing in reports cached by older versions.
        var days: [Day]? = nil
        /// The place's time zone ("Europe/Lisbon"), for hour labels and weekdays; nil means this Mac's.
        var timeZone: String? = nil
    }

    struct Hour: Codable, Equatable {
        var time: Date              // start of the hour
        var chance: Double          // probability of rain or snow, 0…100
        var amount: Double          // millimetres in this hour (always mm; only compared, never shown)
    }

    struct Day: Codable, Equatable {
        var date: Date              // noon of that day in the place's time zone
        var code: Int               // WMO code of the day's dominant weather
        var high: Double
        var low: Double
        var chance: Double          // highest probability of rain or snow, 0…100
    }

    enum Status: Equatable { case idle, loading, failed(String) }

    private(set) var report: Report?
    private(set) var status: Status = .idle

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let session = URLSession(configuration: .ephemeral)
    @ObservationIgnored private static let cacheKey = "weatherReport"
    @ObservationIgnored private static let maxAge: TimeInterval = 30 * 60

    init(settings: Settings, preview: Report? = nil) {
        self.settings = settings
        if let preview {
            report = preview
        } else if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
                  let cached = try? JSONDecoder().decode(Report.self, from: data),
                  cached.location == settings.weatherLocation {
            report = cached
        }
    }

    /// Called when the island opens: fetches if there is no report, it is older than 30 minutes, or it was
    /// cached before the forecast was added.
    func refreshIfStale() {
        guard let location = settings.weatherLocation, status != .loading else { return }
        if let report, report.location == location, report.hours != nil, report.days != nil,
           Date().timeIntervalSince(report.fetched) < Self.maxAge { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard let location = settings.weatherLocation else { report = nil; return }
        status = .loading
        do {
            let fresh = try await fetch(location)
            report = fresh
            status = .idle
            if let data = try? JSONEncoder().encode(fresh) { UserDefaults.standard.set(data, forKey: Self.cacheKey) }
        } catch {
            status = .failed("Can't reach Open-Meteo")
        }
    }

    /// Finds a city by name with Open-Meteo's geocoding service.
    func geocode(_ name: String) async throws -> WeatherLocation? {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        struct Response: Decodable {
            struct Place: Decodable { let name: String; let country: String?; let latitude: Double; let longitude: Double }
            let results: [Place]?
        }
        let response: Response = try await get(components.url!)
        guard let place = response.results?.first else { return nil }
        return WeatherLocation(name: place.name, country: place.country ?? "",
                               latitude: place.latitude, longitude: place.longitude)
    }

    static func forecastURL(_ location: WeatherLocation) -> URL {
        let us = Locale.current.measurementSystem == .us
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", location.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", location.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "hourly", value: "precipitation_probability,precipitation"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "forecast_days", value: "7"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "temperature_unit", value: us ? "fahrenheit" : "celsius"),
        ]
        return components.url!
    }

    private func fetch(_ location: WeatherLocation) async throws -> Report {
        var request = URLRequest(url: Self.forecastURL(location), timeoutInterval: 15)
        request.setValue("CustomNotch/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try Self.report(from: data, location: location)
    }

    /// Decodes Open-Meteo's forecast. Any hourly or daily value can be null; those hours or days are left out.
    static func report(from data: Data, location: WeatherLocation, fetched: Date = Date()) throws -> Report {
        struct Response: Decodable {
            struct Current: Decodable { let temperature_2m: Double; let weather_code: Int; let is_day: Int }
            struct Hourly: Decodable {
                let time: [String]
                let precipitation_probability: [Double?]?
                let precipitation: [Double?]?
            }
            struct Daily: Decodable {
                let time: [String]
                let weather_code: [Int?]?
                let temperature_2m_max: [Double?]
                let temperature_2m_min: [Double?]
                let precipitation_probability_max: [Double?]?
            }
            let timezone: String?
            let utc_offset_seconds: Int?
            let current: Current
            let hourly: Hourly?
            let daily: Daily
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let zone = response.timezone.flatMap(TimeZone.init(identifier:))
            ?? response.utc_offset_seconds.flatMap(TimeZone.init(secondsFromGMT:)) ?? .current
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = zone

        // 48 hours from the one before the fetch: enough for a 24-hour window even when the report is a while old.
        var hours: [Hour] = []
        if let hourly = response.hourly {
            parser.dateFormat = "yyyy-MM-dd'T'HH:mm"
            let from = fetched.addingTimeInterval(-2 * 3600)
            for (index, string) in hourly.time.enumerated() {
                guard let time = parser.date(from: string), time > from,
                      let chance = hourly.precipitation_probability?[safe: index] ?? nil else { continue }
                let amount = hourly.precipitation?[safe: index] ?? nil
                hours.append(Hour(time: time, chance: chance, amount: amount ?? 0))
                if hours.count == 48 { break }
            }
        }

        var days: [Day] = []
        let daily = response.daily
        parser.dateFormat = "yyyy-MM-dd HH:mm"
        for (index, string) in daily.time.enumerated() {
            guard let date = parser.date(from: string + " 12:00"),
                  let high = daily.temperature_2m_max[safe: index] ?? nil,
                  let low = daily.temperature_2m_min[safe: index] ?? nil else { continue }
            let code = (daily.weather_code?[safe: index] ?? nil) ?? response.current.weather_code
            let chance = (daily.precipitation_probability_max?[safe: index] ?? nil) ?? 0
            days.append(Day(date: date, code: code, high: high, low: low, chance: chance))
        }

        let current = response.current
        return Report(temperature: current.temperature_2m, code: current.weather_code, isDay: current.is_day == 1,
                      high: days.first?.high ?? current.temperature_2m, low: days.first?.low ?? current.temperature_2m,
                      fetched: fetched, location: location, hours: hours, days: days, timeZone: response.timezone)
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("CustomNotch/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: WMO weather codes

    /// A still SF Symbol for the WMO code (drawn in multicolour).
    static func symbol(code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 66: return "cloud.rain.fill"
        case 65, 67, 82: return "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 80, 81: return isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 95: return "cloud.bolt.fill"
        case 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func summary(code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55, 56, 57: return "Drizzle"
        case 61, 63, 66: return "Rain"
        case 65, 67: return "Heavy rain"
        case 71, 73, 75, 77: return "Snow"
        case 80, 81, 82: return "Showers"
        case 85, 86: return "Snow showers"
        case 95, 96, 99: return "Thunderstorm"
        default: return ""
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

extension WeatherService.Report {
    /// The hours from the one that contains `now`, at most `count`.
    func upcomingHours(_ count: Int, now: Date) -> [WeatherService.Hour] {
        Array((hours ?? []).filter { $0.time.addingTimeInterval(3600) > now }.prefix(count))
    }

    /// The days from today (in the place's time zone) on, at most `count`.
    func upcomingDays(_ count: Int, now: Date) -> [WeatherService.Day] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.startOfDay(for: now)
        return Array((days ?? []).filter { $0.date >= today }.prefix(count))
    }

    var zone: TimeZone { timeZone.flatMap(TimeZone.init(identifier:)) ?? .current }

    /// A believable report for snapshots and previews: partly cloudy now, showers a few hours from now (so the
    /// chart always has something to show, whatever the time), and a changeable week.
    static func sample(location: WeatherLocation) -> Self {
        let now = Date()
        let hourStart = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        let rain: [Int: (Double, Double)] = [2: (15, 0), 3: (35, 0.2), 4: (60, 0.8), 5: (80, 1.9), 6: (70, 1.2),
                                             7: (45, 0.4), 8: (25, 0.1), 9: (10, 0), 15: (10, 0), 16: (20, 0.1)]
        let hours = (-2..<46).map { offset in
            let (chance, amount) = rain[offset] ?? (offset < 0 ? 0 : 5, 0)
            return WeatherService.Hour(time: hourStart.addingTimeInterval(Double(offset) * 3600),
                                       chance: chance, amount: amount)
        }
        let week: [(code: Int, high: Double, low: Double, chance: Double)] = [
            (80, 20, 14, 80), (61, 17, 13, 70), (3, 18, 12, 30), (2, 21, 13, 10),
            (0, 23, 15, 0), (1, 24, 16, 5), (95, 19, 14, 60),
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
        let days = week.enumerated().map { index, day in
            WeatherService.Day(date: calendar.date(byAdding: .day, value: index, to: noon) ?? noon,
                               code: day.code, high: day.high, low: day.low, chance: day.chance)
        }
        return Self(temperature: 18, code: 2, isDay: true, high: 20, low: 14, fetched: now, location: location,
                    hours: hours, days: days, timeZone: TimeZone.current.identifier)
    }
}

// MARK: - Tile: Weather

/// Two pages, swiped like the cards: now with the chance of rain over the next hours, and the week.
struct WeatherTile: View {
    let weather: WeatherService
    let cells: Int
    let palette: Palette
    let chooseCity: () -> Void

    @State private var page: Int? = 0
    @Environment(\.staticRendering) private var staticRendering
    @Environment(\.cardPage) private var snapshotPage

    var body: some View {
        if let report = weather.report {
            pager(report)
        } else if weather.status == .loading {
            message("Loading weather…")
        } else if case .failed(let reason) = weather.status {
            message(reason)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("No city yet").font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.text)
                Button(action: chooseCity) {
                    Text("Choose City…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(palette.control, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func pager(_ report: WeatherService.Report) -> some View {
        let width = Metrics.tileWidth(cells: cells)
        // A report cached by an older version (or a very old one) has no week left: just today until it is refetched.
        let pages = report.upcomingDays(1, now: Date()).isEmpty ? 1 : 2
        let shown = min(max(snapshotPage, 0), pages - 1)
        return ZStack(alignment: .bottom) {
            if pages == 1 {
                pageView(0, report).frame(width: width, height: Metrics.tileHeight, alignment: .topLeading)
            } else if staticRendering {
                // Snapshots can't draw a scroll view (an AppKit view): show one page.
                pageView(shown, report).frame(width: width, height: Metrics.tileHeight, alignment: .topLeading)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(0..<pages, id: \.self) { index in
                            pageView(index, report)
                                .frame(width: width, height: Metrics.tileHeight, alignment: .topLeading)
                                .id(index)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.never)
                .scrollPosition(id: $page)
            }
            if pages > 1 {
                PageDots(count: pages, current: staticRendering ? shown : (page ?? 0), palette: palette)
                    .padding(.bottom, 3)
            }
        }
        .frame(width: width, height: Metrics.tileHeight)
    }

    @ViewBuilder
    private func pageView(_ index: Int, _ report: WeatherService.Report) -> some View {
        TimelineView(.everyMinute) { context in
            if index == 0 {
                WeatherNowPage(report: report, cells: cells, palette: palette, now: context.date)
            } else {
                WeatherWeekPage(report: report, cells: cells, palette: palette, now: context.date)
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(palette.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The blue Apple Weather uses for precipitation, a shade that holds up on each tile colour.
private extension Palette {
    var rain: Color { isDark ? Color(hex: 0x5AB4FF) : Color(hex: 0x1A73D9) }
}

/// A multicolour weather symbol. The multicolour cloud is white: on a light tile it gets a soft edge.
private struct WeatherSymbol: View {
    let code: Int
    let isDay: Bool
    let size: CGFloat
    let palette: Palette

    var body: some View {
        Image(systemName: WeatherService.symbol(code: code, isDay: isDay))
            .symbolRenderingMode(.multicolor)
            .font(.system(size: size))
            .shadow(color: .black.opacity(palette.isDark ? 0 : 0.18), radius: 1.2, y: 0.5)
            .accessibilityLabel(WeatherService.summary(code: code))
    }
}

// MARK: Page 1: now and the rain over the next hours

private struct WeatherNowPage: View {
    let report: WeatherService.Report
    let cells: Int
    let palette: Palette
    let now: Date

    /// Below this chance in every hour the chart gives way to a line of text.
    static let rainThreshold: Double = 20

    var body: some View {
        let small = cells == 1
        let hours = report.upcomingHours(cells == 3 ? 24 : 12, now: now)
        let rainy = hours.contains { $0.chance >= Self.rainThreshold }
        VStack(alignment: .leading, spacing: 0) {
            if small { compactHeader } else { header }
            Spacer(minLength: 0)
            if hours.isEmpty {
                // No hourly data (an old cached report, or one that has run out): say nothing about rain.
                Text(WeatherService.summary(code: report.code))
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.secondary)
                    .minimumScaleFactor(0.86)
            } else if !rainy {
                dry(hours)
            } else {
                RainChart(hours: hours, cells: cells, palette: palette, zone: report.zone)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, small ? 8 : 10)
        .padding(.top, small ? 7 : 8)
        .padding(.bottom, 12)       // clear of the page dots
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var temperature: String { "\(Int(report.temperature.rounded()))°" }
    private var highLow: String { "H:\(Int(report.high.rounded()))° L:\(Int(report.low.rounded()))°" }

    /// Temperature and symbol on the left, place and high/low on the right.
    private var header: some View {
        HStack(alignment: .center, spacing: 5) {
            // The temperature never shortens; the place and high/low give way instead.
            // The line is trimmed to the digits' height (they have no descender), so the chart can sit closer.
            Text(temperature)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(palette.text)
                .fixedSize()
                .frame(height: 24)
            WeatherSymbol(code: report.code, isDay: report.isDay, size: 16, palette: palette)
                .fixedSize()
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(cells == 3 ? "\(report.location.name) · \(WeatherService.summary(code: report.code))"
                                : report.location.name)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(palette.text)
                Text(highLow)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(palette.secondary)
                    .minimumScaleFactor(0.9)
            }
        }
    }

    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                Text(temperature)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(palette.text)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)
                    .frame(height: 19)
                Spacer(minLength: 2)
                WeatherSymbol(code: report.code, isDay: report.isDay, size: 14, palette: palette)
            }
            Text("\(Int(report.high.rounded()))° / \(Int(report.low.rounded()))°")
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(palette.secondary)
                .padding(.top, 3)
        }
    }

    /// No rain worth a chart: say so instead. Open-Meteo sometimes forecasts a little rain at a low chance;
    /// that gets a mention rather than an empty chart.
    private func dry(_ hours: [WeatherService.Hour]) -> some View {
        let span = hours.count
        let light = hours.first { $0.amount >= 0.1 }
        let text: String
        let spoken: String
        if let light {
            let time = RainChart.hourText(light.time, zone: report.zone)
            text = cells == 1 ? "Light rain" : "Light rain around \(time)"
            spoken = "Light rain possible around \(time)"
        } else {
            text = cells == 1 ? "No rain" : "No rain next \(span) h"
            spoken = "No rain expected in the next \(span) hours"
        }
        return HStack(spacing: 4) {
            Image(systemName: light == nil ? "umbrella" : "cloud.drizzle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(light == nil ? palette.secondary : palette.rain)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(palette.secondary)
                .minimumScaleFactor(0.86)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}

/// The chance of rain per hour as bars (0–100 %, not scaled to the maximum), with a few hour labels.
private struct RainChart: View {
    let hours: [WeatherService.Hour]
    let cells: Int
    let palette: Palette
    let zone: TimeZone

    var body: some View {
        let width = Metrics.tileWidth(cells: cells) - 2 * (cells == 1 ? 8 : 10)
        let count = CGFloat(max(hours.count, 1))
        let gap: CGFloat = cells == 3 ? 2.5 : cells == 2 ? 3 : 1.5
        let barWidth = (width - gap * (count - 1)) / count
        let height: CGFloat = cells == 1 ? 12 : 16
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(hours.enumerated()), id: \.offset) { _, hour in
                    let value = min(max(hour.chance, 0), 100) / 100
                    ZStack(alignment: .bottom) {
                        // A faint track per hour keeps the time axis readable where it's dry.
                        RoundedRectangle(cornerRadius: min(barWidth / 2, 1.5))
                            .fill(palette.secondary.opacity(palette.isDark ? 0.16 : 0.13))
                        RoundedRectangle(cornerRadius: min(barWidth / 2, 1.5))
                            .fill(palette.rain)
                            .frame(height: value * height >= 1 ? max(2, value * height) : 0)
                    }
                    .frame(width: barWidth, height: height)
                }
            }
            ZStack(alignment: .topLeading) {
                ForEach(labels, id: \.index) { label in
                    let center = CGFloat(label.index) * (barWidth + gap) + barWidth / 2
                    if label.index == 0 {
                        Text(label.text).fixedSize()
                    } else {
                        Text(label.text).fixedSize()
                            .frame(width: 40)
                            .offset(x: center - 20)
                    }
                }
            }
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(palette.secondary)
            .frame(width: width, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    /// "Now" under the first bar, then a clock hour every third of the window (every half at one cell).
    private var labels: [(index: Int, text: String)] {
        let step = cells == 1 ? 6 : cells == 3 ? 6 : 4
        var result: [(Int, String)] = [(0, "Now")]
        var index = step
        while index < hours.count - 1 {
            result.append((index, Self.hourText(hours[index].time, zone: zone)))
            index += step
        }
        return result
    }

    /// A short clock hour: "15" (or "09") with a 24-hour clock, "3PM" with a 12-hour one.
    static func hourText(_ date: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        let twelveHour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? false
        if twelveHour {
            formatter.setLocalizedDateFormatFromTemplate("ha")
            return formatter.string(from: date).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{202F}", with: "")
        }
        formatter.dateFormat = "HH"
        return formatter.string(from: date)
    }

    /// "Chance of rain from 15:00 to 19:00, up to 80 percent" for VoiceOver (the first spell of rain).
    private var summary: String {
        guard let peak = hours.max(by: { $0.chance < $1.chance }) else { return "" }
        let isWet = { (hour: WeatherService.Hour) in hour.chance >= WeatherNowPage.rainThreshold }
        guard let firstIndex = hours.firstIndex(where: isWet) else { return "No rain expected" }
        let run = hours[firstIndex...].prefix(while: isWet)
        let first = run.first!, last = run.last!
        let more = hours[(firstIndex + run.count)...].contains(where: isWet)
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.timeStyle = .short
        let end = formatter.string(from: last.time.addingTimeInterval(3600))
        let start = first.time <= hours[0].time ? "now" : formatter.string(from: first.time)
        return "Chance of rain from \(start) to \(end), up to \(Int(peak.chance.rounded())) percent" + (more ? ", more later" : "")
    }
}

// MARK: Page 2: the week

private struct WeatherWeekPage: View {
    let report: WeatherService.Report
    let cells: Int
    let palette: Palette
    let now: Date

    var body: some View {
        let days = report.upcomingDays(cells == 1 ? 3 : 7, now: now)
        let inset: CGFloat = cells == 3 ? 6 : 3
        // Equal columns, whatever their text: a wide "100%" must not push its neighbours aside.
        let width = (Metrics.tileWidth(cells: cells) - 2 * inset) / CGFloat(max(days.count, 1))
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                column(day, isToday: index == 0)
                    .frame(width: width)
            }
        }
        .padding(.horizontal, inset)
        .padding(.top, 6)           // 62 pt of rows end at 68, clear of the page dots at 72
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func column(_ day: WeatherService.Day, isToday: Bool) -> some View {
        VStack(spacing: 0) {
            Text(weekday(day.date, isToday: isToday))
                .font(.system(size: cells == 2 ? 9 : 9.5, weight: isToday ? .semibold : .medium))   // "Wed" in 22 pt
                .foregroundStyle(isToday ? palette.text : palette.secondary)
                .minimumScaleFactor(0.95)
                .frame(height: 12)
            WeatherSymbol(code: day.code, isDay: true, size: cells == 3 ? 14 : 13, palette: palette)
                .frame(height: 17)
            // The chance of rain, like Apple Weather, only when it's worth mentioning.
            chance(day)
                .frame(height: 10)
            Text("\(Int(day.high.rounded()))°")
                .font(.system(size: 10.5, weight: .medium))     // proportional digits: "-12°" fits a 22 pt column
                .foregroundStyle(palette.text)
                .minimumScaleFactor(0.86)       // never below 9 pt
                .frame(height: 12)
            Text("\(Int(day.low.rounded()))°")
                .font(.system(size: 10))
                .foregroundStyle(palette.secondary)
                .minimumScaleFactor(0.9)
                .frame(height: 11)
        }
        .lineLimit(1)
        .padding(.horizontal, 1)            // keeps neighbouring values from touching
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(day, isToday: isToday))
    }

    /// "80%". Below three cells the columns are about 22 pt wide: the per-cent sign is drawn smaller, and a
    /// rare "100" goes without it, so neighbouring values never touch (the digits stay at 9 pt).
    @ViewBuilder
    private func chance(_ day: WeatherService.Day) -> some View {
        if day.chance >= 20 {
            let percent = Int((day.chance / 10).rounded()) * 10
            let weight: Font.Weight = cells == 3 ? .semibold : .medium
            let value = Text("\(percent)").font(.system(size: 9, weight: weight))
            let sign = Text("%").font(.system(size: cells == 3 ? 9 : 6.5, weight: weight))
            (cells < 3 && percent >= 100 ? value : Text("\(value)\(sign)"))
                .foregroundStyle(palette.rain)
                .fixedSize()
        } else {
            Color.clear
        }
    }

    private func weekday(_ date: Date, isToday: Bool) -> String {
        if isToday && cells == 3 { return "Today" }
        let formatter = DateFormatter()
        formatter.timeZone = report.zone
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: date).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private func spoken(_ day: WeatherService.Day, isToday: Bool) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = report.zone
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        var parts = [isToday ? "Today" : formatter.string(from: day.date), WeatherService.summary(code: day.code),
                     "high \(Int(day.high.rounded()))°", "low \(Int(day.low.rounded()))°"]
        if day.chance >= 20 { parts.append("\(Int(day.chance.rounded())) percent chance of rain") }
        return parts.joined(separator: ", ")
    }
}
