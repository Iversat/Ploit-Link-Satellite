import Foundation
import SwiftUI

enum SiteSkyCondition: String, CaseIterable, Identifiable {
    case unknown, clear, cloudy, fog, rain, snow, thunderstorm
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unknown: return "Не указано"
        case .clear: return "Ясно"
        case .cloudy: return "Облачно"
        case .fog: return "Туман"
        case .rain: return "Дождь"
        case .snow: return "Снег"
        case .thunderstorm: return "Гроза"
        }
    }
}

enum SiteWindCondition: String, CaseIterable, Identifiable {
    case unknown, calm, noticeable, strong
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unknown: return "Не указан"
        case .calm: return "Слабый / штиль"
        case .noticeable: return "Ощутимый"
        case .strong: return "Сильный"
        }
    }
}

struct SiteWeather: Equatable {
    let sampledAt: Date
    let sky: SiteSkyCondition
    let wind: SiteWindCondition
    let temperatureC: Double?

    func isStale(at date: Date) -> Bool {
        let age = date.timeIntervalSince(sampledAt)
        return age > 3600 || age < -300
    }

    var outdoorAdvice: String? {
        if sky == .thunderstorm {
            return "При грозе перенесите сканирование открытой местности."
        }
        if sky == .snow || (sky == .rain && (temperatureC.map { $0 <= 0 } ?? false)) {
            return "Проверьте снег и наледь на антенне перед сеансом."
        }
        if wind == .strong {
            return "Закрепите внешнюю антенну: ветер мешает удерживать направление."
        }
        if sky == .rain {
            return "Проверьте защиту внешнего модуля и разъёмов от воды."
        }
        return nil
    }

    static func parseTemperature(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "−", with: "-")
        guard let value = Double(normalized), value.isFinite, (-90...60).contains(value) else { return nil }
        return value
    }
}

struct SiteWeatherForecast: Codable, Equatable {
    let sampledAt: Date
    let interval: TimeInterval
    let temperatureC: Double?
    let cloudCover: Double?
    let precipitationMM: Double?
    let windMS: Double?
    let weatherCode: Int?

    var observation: SiteWeather {
        let sky: SiteSkyCondition
        switch weatherCode {
        case 0: sky = .clear
        case 1, 2, 3: sky = .cloudy
        case 45, 48: sky = .fog
        case 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82: sky = .rain
        case 71, 73, 75, 77, 85, 86: sky = .snow
        case 95, 96, 99: sky = .thunderstorm
        default: sky = .unknown
        }
        let wind: SiteWindCondition
        if let windMS { wind = windMS >= 10 ? .strong : (windMS >= 3 ? .noticeable : .calm) }
        else { wind = .unknown }
        return SiteWeather(sampledAt: sampledAt, sky: sky, wind: wind, temperatureC: temperatureC)
    }
    func isStale(at date: Date) -> Bool { observation.isStale(at: date) }
}

enum SiteWeatherError: Error { case invalidCoordinates, invalidResponse, unavailable }

enum SiteWeatherAPI {
    static func location(for observer: Observer?) -> Observer? {
        guard let observer, observer.latitude.isFinite, observer.longitude.isFinite,
              (-90...90).contains(observer.latitude), (-180...180).contains(observer.longitude) else { return nil }
        return Observer(latitude: (observer.latitude * 100).rounded() / 100,
                        longitude: (observer.longitude * 100).rounded() / 100, altitudeM: 0)
    }

    static func requestURL(observer: Observer) throws -> URL {
        guard let location = location(for: observer) else { throw SiteWeatherError.invalidCoordinates }
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.latitude)),
            URLQueryItem(name: "longitude", value: String(location.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,cloud_cover,precipitation,wind_speed_10m,weather_code"),
            URLQueryItem(name: "wind_speed_unit", value: "ms"),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
            URLQueryItem(name: "precipitation_unit", value: "mm"),
            URLQueryItem(name: "timezone", value: "GMT"),
            URLQueryItem(name: "timeformat", value: "unixtime")
        ]
        guard let result = url.url else { throw SiteWeatherError.invalidCoordinates }
        return result
    }

    static func decode(_ data: Data) throws -> SiteWeatherForecast {
        struct Response: Decodable {
            struct Current: Decodable {
                let time: Double
                let interval: Double?
                let temperature_2m: Double?
                let cloud_cover: Double?
                let precipitation: Double?
                let wind_speed_10m: Double?
                let weather_code: Int?
            }
            let current: Current
        }
        let current = try JSONDecoder().decode(Response.self, from: data).current
        func valid(_ value: Double?, range: ClosedRange<Double>) -> Double? {
            guard let value, value.isFinite, range.contains(value) else { return nil }
            return value
        }
        guard current.time.isFinite, current.time > 0 else { throw SiteWeatherError.invalidResponse }
        let temperature = valid(current.temperature_2m, range: -100...70)
        let cloud = valid(current.cloud_cover, range: 0...100)
        let precipitation = valid(current.precipitation, range: 0...1000)
        let wind = valid(current.wind_speed_10m, range: 0...200)
        guard temperature != nil || cloud != nil || precipitation != nil || wind != nil else {
            throw SiteWeatherError.invalidResponse
        }
        return SiteWeatherForecast(sampledAt: Date(timeIntervalSince1970: current.time),
                                   interval: valid(current.interval, range: 1...86400) ?? 900,
                                   temperatureC: temperature, cloudCover: cloud, precipitationMM: precipitation,
                                   windMS: wind, weatherCode: current.weather_code)
    }
}

@MainActor final class SiteWeatherService: ObservableObject {
    struct CacheEntry: Codable {
        let location: Observer
        let forecast: SiteWeatherForecast
        let fetchedAt: Date
        func isFresh(at date: Date) -> Bool {
            let age = date.timeIntervalSince(fetchedAt)
            // A stale provider sample remains labelled stale, without polling it every tick.
            return age >= 0 && age < 900
        }
    }
    typealias Loader = (URLRequest) async throws -> (Data, URLResponse)
    @Published private(set) var weather: SiteWeather?
    @Published private(set) var forecast: SiteWeatherForecast?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var fetchedAt: Date?
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private let loader: Loader
    private let now: () -> Date
    private let cacheURL: URL?
    private var cache: [String: CacheEntry] = [:]
    private var activeLocation: Observer?
    private var lastAttempt: Date?
    private var failures: [String: Date] = [:]
    private var networkAvailable = true

    init(session: URLSession? = nil, cacheURL: URL? = nil, persistsCache: Bool = true,
         now: @escaping () -> Date = Date.init, loader: Loader? = nil) {
        self.now = now
        self.cacheURL = persistsCache ? (cacheURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Weather/current.json")) : nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        let session = session ?? URLSession(configuration: configuration)
        self.loader = loader ?? { try await session.data(for: $0) }
        if let cacheURL = self.cacheURL, let data = try? Data(contentsOf: cacheURL), data.count <= 100_000,
           let entries = try? JSONDecoder().decode([CacheEntry].self, from: data) {
            for entry in entries.prefix(8) where SiteWeatherAPI.location(for: entry.location) == entry.location && entry.forecast.sampledAt.timeIntervalSince1970 > 0 {
                cache[Self.key(entry.location)] = entry
            }
        }
    }

    deinit { task?.cancel() }

    private static func key(_ location: Observer) -> String {
        "\(location.latitude)/\(location.longitude)"
    }

    func useLocation(_ observer: Observer?) {
        let location = SiteWeatherAPI.location(for: observer)
        guard location != activeLocation else { return }
        cancel()
        activeLocation = location
        let entry = location.flatMap { cache[Self.key($0)] }
        forecast = entry?.forecast; fetchedAt = entry?.fetchedAt
        weather = nil; errorMessage = nil
    }

    func load(observer: Observer) {
        refreshIfNeeded(observer: observer, networkAvailable: networkAvailable, force: true)
    }

    func refreshIfNeeded(observer: Observer?, networkAvailable: Bool, force: Bool = false) {
        if !self.networkAvailable && networkAvailable { errorMessage = nil }
        self.networkAvailable = networkAvailable
        useLocation(observer)
        guard let location = activeLocation else {
            if force { errorMessage = "Для погоды нужны корректные координаты." }
            return
        }
        guard networkAvailable else {
            if isLoading { cancel() }
            let message = forecast == nil ? "Нет интернета. Условия можно указать вручную." : "Нет интернета. Показаны сохранённые данные."
            if errorMessage != message { errorMessage = message }
            return
        }
        guard !isLoading else { return }
        let date = now(), key = Self.key(location)
        if !force, cache[key]?.isFresh(at: date) == true { return }
        if let lastAttempt {
            let elapsed = date.timeIntervalSince(lastAttempt)
            if elapsed >= 0 && elapsed < (force ? 30 : 60) { return }
        }
        if !force, let failed = failures[key] {
            let elapsed = date.timeIntervalSince(failed)
            if elapsed >= 0 && elapsed < 300 { return }
        }
        guard let url = try? SiteWeatherAPI.requestURL(observer: location) else {
            errorMessage = "Для погоды нужны корректные координаты."
            return
        }
        let id = UUID(); requestID = id
        lastAttempt = date
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        isLoading = true; errorMessage = nil
        let loader = loader
        task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let (data, response) = try await loader(request)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      data.count <= 100_000 else { throw SiteWeatherError.unavailable }
                let forecast = try SiteWeatherAPI.decode(data)
                guard let self, self.requestID == id else { return }
                let entry = CacheEntry(location: location, forecast: forecast, fetchedAt: self.now())
                self.cache[key] = entry
                self.forecast = forecast; self.fetchedAt = entry.fetchedAt
                self.failures[key] = nil
                self.saveCache()
                self.isLoading = false; self.task = nil
            } catch {
                guard !Task.isCancelled, let self, self.requestID == id else { return }
                self.failures[key] = self.now()
                self.errorMessage = self.forecast == nil ? "Погода недоступна. Повторная проверка — через несколько минут." : "Не удалось обновить погоду. Показаны сохранённые данные."
                self.isLoading = false; self.task = nil
            }
        }
    }

    func cancel() {
        requestID = UUID()
        task?.cancel(); task = nil; isLoading = false
    }

    private func saveCache() {
        let entries = Array(cache.values.sorted { $0.fetchedAt > $1.fetchedAt }.prefix(8))
        cache = Dictionary(uniqueKeysWithValues: entries.map { (Self.key($0.location), $0) })
        guard let cacheURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    func record(sky: SiteSkyCondition, wind: SiteWindCondition, temperatureC: Double?, at date: Date = Date()) {
        let temperature = temperatureC.flatMap { $0.isFinite && (-90...60).contains($0) ? $0 : nil }
        guard sky != .unknown || wind != .unknown || temperature != nil else { return }
        weather = SiteWeather(sampledAt: date, sky: sky, wind: wind, temperatureC: temperature)
    }
    func clear() {
        cancel(); weather = nil; forecast = nil; fetchedAt = nil; errorMessage = nil
        activeLocation = nil; cache = [:]; failures = [:]; lastAttempt = nil
        if let cacheURL { try? FileManager.default.removeItem(at: cacheURL) }
    }
}

struct SiteWeatherView: View {
    let observer: Observer?
    @ObservedObject var service: SiteWeatherService
    @State private var sky: SiteSkyCondition = .unknown
    @State private var wind: SiteWindCondition = .unknown
    @State private var temperature = ""
    @State private var expanded = false

    private var temperatureIsValid: Bool {
        temperature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || SiteWeather.parseTemperature(temperature) != nil
    }
    private var hasConditions: Bool {
        sky != .unknown || wind != .unknown || SiteWeather.parseTemperature(temperature) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack {
                    Label("Местные условия", systemImage: "cloud.sun").font(.headline)
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("siteWeatherDisclosure")
            .accessibilityValue(expanded ? "Развёрнуто" : "Свёрнуто")
            if expanded {
        VStack(alignment: .leading, spacing: 12) {
            onlineWeather
            Divider()
            Text("Наблюдение вручную").font(.subheadline.weight(.semibold))
            Text("Можно указать условия на месте без интернета. Эти записи остаются на устройстве.")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Text("Небо и осадки")
                Spacer()
                Picker("Небо и осадки", selection: $sky) {
                    ForEach(SiteSkyCondition.allCases) { value in Text(value.title).tag(value) }
                }.labelsHidden()
            }
            HStack {
                Text("Ветер")
                Spacer()
                Picker("Ветер", selection: $wind) {
                    ForEach(SiteWindCondition.allCases) { value in Text(value.title).tag(value) }
                }.labelsHidden()
            }
            HStack {
                Text("Температура, °C")
                Spacer()
                TextField("Неизвестно", text: $temperature)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing).frame(maxWidth: 120)
                    .accessibilityLabel("Температура воздуха")
            }
            if !temperatureIsValid {
                Text("Укажите число от −90 до 60 или оставьте поле пустым.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button {
                service.record(sky: sky, wind: wind, temperatureC: SiteWeather.parseTemperature(temperature))
            } label: {
                Text(service.weather == nil ? "Сохранить условия" : "Обновить наблюдение")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }.buttonStyle(.bordered).disabled(!hasConditions || !temperatureIsValid)
                .accessibilityIdentifier("recordSiteWeather")
            if let weather = service.weather {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    weatherDetails(weather, at: context.date)
                }
            }
            Text("Облачность сама по себе не определяет связь на 145/435 МГц. Крыша, деревья, намокание и наледь на антенне влияют отдельно. Погода к будущему сеансу может измениться.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 10)
            }
        }
        .onAppear { service.useLocation(observer) }
        .onChange(of: locationKey) { _, _ in service.useLocation(observer) }
    }

    // Discard a local observation when moving to a different weather area.
    private var locationKey: String {
        guard let location = SiteWeatherAPI.location(for: observer) else { return "unknown" }
        return "\(location.latitude)/\(location.longitude)"
    }

    private var onlineWeather: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Погода обновляется автоматически при открытии приложения и появлении сети. Open-Meteo получает координаты, округлённые до 0,01°, и IP-адрес.")
                .font(.caption).foregroundStyle(.secondary)
            if service.isLoading {
                HStack {
                    ProgressView().tint(.white)
                    Text("Загрузка погоды…").font(.subheadline)
                    Spacer()
                    Button("Отмена") { service.cancel() }
                }
            } else {
                Button {
                    if let location = SiteWeatherAPI.location(for: observer) { service.load(observer: location) }
                } label: {
                    Label(service.forecast == nil ? "Загрузить погоду" : "Обновить погоду", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .satelliteGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true)
                }.buttonStyle(.plain).disabled(SiteWeatherAPI.location(for: observer) == nil)
                    .accessibilityIdentifier("loadSiteWeather")
            }
            if SiteWeatherAPI.location(for: observer) == nil {
                Text("Укажите геопозицию для загрузки погоды.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = service.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if let forecast = service.forecast {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    forecastDetails(forecast, at: context.date)
                }
            }
            HStack(spacing: 12) {
                Link("Погода: Open-Meteo", destination: URL(string: "https://open-meteo.com/")!)
                Link("CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
            }.font(.caption)
            Link("Условия и конфиденциальность", destination: URL(string: "https://open-meteo.com/en/terms")!)
                .font(.caption)
        }
    }

    private func forecastDetails(_ weather: SiteWeatherForecast, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Погодная модель на \(weather.sampledAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            if weather.isStale(at: date) {
                Text("Данные старше часа или время устройства неверно — обновите погоду.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow { Text("Температура"); Text(value(weather.temperatureC, suffix: " °C")) }
                GridRow { Text("Облачность"); Text(value(weather.cloudCover, suffix: " %", decimals: 0)) }
                GridRow { Text("Ветер"); Text(value(weather.windMS, suffix: " м/с")) }
                GridRow {
                    Text("Осадки за \(Int(weather.interval / 60)) мин")
                    Text(value(weather.precipitationMM, suffix: " мм"))
                }
            }.font(.subheadline).monospacedDigit()
            if !weather.isStale(at: date), let advice = weather.observation.outdoorAdvice {
                Text(advice).font(.caption).foregroundStyle(.orange)
            }
            Text("Модель текущей погоды, не измерение радиосигнала. Числа округлены; к сеансу условия могут измениться.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func value(_ number: Double?, suffix: String, decimals: Int = 1) -> String {
        guard let number else { return "Нет данных" }
        return number.formatted(.number.precision(.fractionLength(decimals))) + suffix
    }

    private func weatherDetails(_ weather: SiteWeather, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Наблюдение на \(weather.sampledAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            Text(summary(weather)).font(.subheadline)
            if weather.isStale(at: date) {
                Text("Наблюдению больше часа или время устройства изменилось. Проверьте условия снова.")
                    .font(.caption).foregroundStyle(.orange)
            } else if let advice = weather.outdoorAdvice {
                Text(advice).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func summary(_ weather: SiteWeather) -> String {
        var items: [String] = []
        if weather.sky != .unknown { items.append(weather.sky.title) }
        if weather.wind != .unknown { items.append("Ветер: \(weather.wind.title.lowercased())") }
        if let temperature = weather.temperatureC {
            items.append(temperature.formatted(.number.precision(.fractionLength(0...1))) + " °C")
        }
        return items.joined(separator: " · ")
    }
}
