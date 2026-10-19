import Foundation
import JavaScriptCore

enum OrbitError: LocalizedError {
    case engine, propagation, network, invalidElements
    var errorDescription: String? {
        switch self {
        case .engine: return "Не удалось загрузить расчёт орбит."
        case .propagation: return "Нет корректного решения орбиты. Обновите TLE."
        case .network: return "Не удалось обновить орбиту. Сохранённые данные доступны офлайн."
        case .invalidElements: return "Источник вернул некорректные орбитальные данные."
        }
    }
}

actor OrbitEngine {
    private var context: JSContext?
    private var installed: Elements?
    private func prepare(_ elements: Elements) throws -> JSContext {
        if context == nil {
            guard let js = JSContext(),
                  let vendor = Bundle.main.url(forResource: "satellite.min", withExtension: "js"),
                  let wrapper = Bundle.main.url(forResource: "orbit", withExtension: "js") else { throw OrbitError.engine }
            js.evaluateScript(try String(contentsOf: vendor, encoding: .utf8))
            js.evaluateScript(try String(contentsOf: wrapper, encoding: .utf8))
            guard js.exception == nil else { throw OrbitError.engine }
            context = js
        }
        guard let js = context else { throw OrbitError.engine }
        js.exception = nil
        if installed != elements {
            let result = js.objectForKeyedSubscript("installTLE")?.call(withArguments: [elements.line1, elements.line2])
            guard result?.toBool() == true, js.exception == nil else { throw OrbitError.invalidElements }
            installed = elements
        }
        return js
    }
    func look(elements: Elements, observer: Observer, date: Date) throws -> Look {
        let js = try prepare(elements)
        guard let json = js.objectForKeyedSubscript("lookJSON")?.call(withArguments: [date.timeIntervalSince1970 * 1000, observer.latitude, observer.longitude, observer.altitudeM])?.toString(),
              js.exception == nil, let data = json.data(using: .utf8), let result = try? JSONDecoder().decode(Look.self, from: data) else { throw OrbitError.propagation }
        return result
    }
    func passes(elements: Elements, observer: Observer, date: Date, minElevation: Double) throws -> [PassWindow] {
        let js = try prepare(elements)
        guard let json = js.objectForKeyedSubscript("passesJSON")?.call(withArguments: [date.timeIntervalSince1970 * 1000, observer.latitude, observer.longitude, observer.altitudeM, minElevation])?.toString(),
              js.exception == nil, let data = json.data(using: .utf8) else { throw OrbitError.propagation }
        return try JSONDecoder().decode([PassWindow].self, from: data)
    }
}

actor ElementStore {
    private let folder: URL
    init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orbits", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    func cached(id: Int) -> Elements? {
        if let data = try? Data(contentsOf: folder.appendingPathComponent("\(id).json")),
           let value = try? JSONDecoder().decode(Elements.self, from: data), value.valid(for: id) { return value }
        guard let url = Bundle.main.url(forResource: "seed-tle", withExtension: "json"), let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([Elements].self, from: data) else { return nil }
        return values.first { $0.norad == id && $0.valid(for: id) }
    }
    func update(id: Int) async throws -> Elements {
        // Only NORAD ID is sent; user's position never leaves the device.
        let url = URL(string: "https://celestrak.org/NORAD/elements/gp.php?CATNR=\(id)&FORMAT=TLE")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("PloitSatellite/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 32000,
              let text = String(data: data, encoding: .utf8) else { throw OrbitError.network }
        guard let result = Elements.parse(text, id: id), result.ageDays() < 30 else { throw OrbitError.invalidElements }
        try JSONEncoder().encode(result).write(to: folder.appendingPathComponent("\(id).json"), options: .atomic)
        return result
    }
}
