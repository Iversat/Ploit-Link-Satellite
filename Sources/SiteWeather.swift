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

@MainActor final class SiteWeatherService: ObservableObject {
    @Published private(set) var weather: SiteWeather?
    func record(sky: SiteSkyCondition, wind: SiteWindCondition, temperatureC: Double?, at date: Date = Date()) {
        let temperature = temperatureC.flatMap { $0.isFinite && (-90...60).contains($0) ? $0 : nil }
        guard sky != .unknown || wind != .unknown || temperature != nil else { return }
        weather = SiteWeather(sampledAt: date, sky: sky, wind: wind, temperatureC: temperature)
    }
    func clear() { weather = nil }
}

struct SiteWeatherView: View {
    let observer: Observer?
    @StateObject private var service = SiteWeatherService()
    @State private var sky: SiteSkyCondition = .unknown
    @State private var wind: SiteWindCondition = .unknown
    @State private var temperature = ""

    private var temperatureIsValid: Bool {
        temperature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || SiteWeather.parseTemperature(temperature) != nil
    }
    private var hasConditions: Bool {
        sky != .unknown || wind != .unknown || SiteWeather.parseTemperature(temperature) != nil
    }

    var body: some View {
        DisclosureGroup {
        VStack(alignment: .leading, spacing: 12) {
            Text("Укажите погоду вручную. Это наблюдение на месте, без загрузки прогноза и передачи координат.")
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
        } label: {
            Label("Местные условия", systemImage: "cloud.sun").font(.headline)
        }
        .accessibilityIdentifier("siteWeatherDisclosure")
        .onChange(of: locationKey) { _, _ in service.clear() }
    }

    // Discard a local observation when moving to a different weather area.
    private var locationKey: String {
        guard let observer, observer.latitude.isFinite, observer.longitude.isFinite else { return "unknown" }
        return "\((observer.latitude * 100).rounded())/\((observer.longitude * 100).rounded())"
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
