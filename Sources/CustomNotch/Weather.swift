import SwiftUI
import Foundation

/// Current weather from Open-Meteo (free, no key). The only data sent is the city name
/// (to find it) and its coordinates (to get the forecast).
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

    /// Called when the island opens: fetches only if there is no report or it is older than 30 minutes.
    func refreshIfStale() {
        guard let location = settings.weatherLocation, status != .loading else { return }
        if let report, report.location == location, Date().timeIntervalSince(report.fetched) < Self.maxAge { return }
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

    private func fetch(_ location: WeatherLocation) async throws -> Report {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", location.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", location.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "temperature_unit", value: Locale.current.measurementSystem == .us ? "fahrenheit" : "celsius"),
        ]
        struct Response: Decodable {
            struct Current: Decodable { let temperature_2m: Double; let weather_code: Int; let is_day: Int }
            struct Daily: Decodable { let temperature_2m_max: [Double]; let temperature_2m_min: [Double] }
            let current: Current
            let daily: Daily
        }
        let response: Response = try await get(components.url!)
        return Report(temperature: response.current.temperature_2m, code: response.current.weather_code,
                      isDay: response.current.is_day == 1,
                      high: response.daily.temperature_2m_max.first ?? response.current.temperature_2m,
                      low: response.daily.temperature_2m_min.first ?? response.current.temperature_2m,
                      fetched: Date(), location: location)
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

// MARK: - Tile: Weather

struct WeatherTile: View {
    let weather: WeatherService
    let cells: Int
    let palette: Palette
    let chooseCity: () -> Void

    var body: some View {
        if let report = weather.report {
            reportView(report)
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

    private func reportView(_ report: WeatherService.Report) -> some View {
        // Sizes measured from the reference screenshot; one cell gets a tighter version.
        let small = cells == 1
        let place = cells == 3 ? "\(report.location.name) · \(WeatherService.summary(code: report.code))" : report.location.name
        let high = Int(report.high.rounded()), low = Int(report.low.rounded())
        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(Int(report.temperature.rounded()))°")
                    .font(.system(size: small ? 24 : 35, weight: .light))
                    .foregroundStyle(palette.text)
                Text(place)
                    .font(.system(size: small ? 10 : 10.5))
                    .foregroundStyle(palette.secondary)
                Spacer(minLength: 0)
                Text(small ? "\(high)° \(low)°" : "H \(high)°  L \(low)°")
                    .font(.system(size: small ? 9.5 : 10))
                    .foregroundStyle(palette.secondary)
            }
            .lineLimit(1)
            .padding(.leading, small ? 8 : 9)
            .padding(.top, small ? 6 : 2.5)
            .padding(.bottom, small ? 8 : 8.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Image(systemName: WeatherService.symbol(code: report.code, isDay: report.isDay))
                .symbolRenderingMode(.multicolor)
                // The multicolour cloud is white: on a light tile it needs a soft edge to stay visible.
                .shadow(color: .black.opacity(palette.isDark ? 0 : 0.18), radius: 1.2, y: 0.5)
                .font(.system(size: small ? 14 : 26))
                .padding(.top, small ? 8 : 10)
                .padding(.trailing, small ? 6 : 8)
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
