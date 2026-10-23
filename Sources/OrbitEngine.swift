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
        try Task.checkCancellation()
        let js = try prepare(elements)
        guard let json = js.objectForKeyedSubscript("lookJSON")?.call(withArguments: [date.timeIntervalSince1970 * 1000, observer.latitude, observer.longitude, observer.altitudeM])?.toString(),
              js.exception == nil, let data = json.data(using: .utf8), let result = try? JSONDecoder().decode(Look.self, from: data) else { throw OrbitError.propagation }
        try Task.checkCancellation()
        return result
    }
    func passes(elements: Elements, observer: Observer, date: Date, minElevation: Double) throws -> [PassWindow] {
        try Task.checkCancellation()
        let js = try prepare(elements)
        guard let json = js.objectForKeyedSubscript("passesJSON")?.call(withArguments: [date.timeIntervalSince1970 * 1000, observer.latitude, observer.longitude, observer.altitudeM, minElevation])?.toString(),
              js.exception == nil, let data = json.data(using: .utf8) else { throw OrbitError.propagation }
        try Task.checkCancellation()
        return try JSONDecoder().decode([PassWindow].self, from: data)
    }
    func state(elements: Elements, date: Date) throws -> OrbitalState {
        try Task.checkCancellation()
        let js=try prepare(elements)
        guard let json=js.objectForKeyedSubscript("stateJSON")?.call(withArguments:[date.timeIntervalSince1970*1000])?.toString(),
              js.exception == nil, let data=json.data(using:.utf8) else { throw OrbitError.propagation }
        try Task.checkCancellation()
        return try JSONDecoder().decode(OrbitalState.self,from:data)
    }
    func trajectory(elements: Elements, date: Date) throws -> OrbitalTrajectory {
        try Task.checkCancellation()
        let js=try prepare(elements)
        guard let json=js.objectForKeyedSubscript("trajectoryJSON")?.call(withArguments:[date.timeIntervalSince1970*1000])?.toString(),
              js.exception == nil, let data=json.data(using:.utf8) else { throw OrbitError.propagation }
        try Task.checkCancellation()
        return try JSONDecoder().decode(OrbitalTrajectory.self,from:data)
    }
    func motion(elements: Elements,date: Date,seconds: Double) throws -> OrbitMotion {
        try Task.checkCancellation()
        let js=try prepare(elements),step=5.0
        guard let json=js.objectForKeyedSubscript("motionJSON")?.call(withArguments:[date.timeIntervalSince1970*1000,seconds,step])?.toString(),
              js.exception == nil,let data=json.data(using:.utf8) else { throw OrbitError.propagation }
        try Task.checkCancellation()
        return OrbitMotion(start:date,step:step,samples:try JSONDecoder().decode([OrbitalState].self,from:data))
    }
}

actor ElementStore {
    typealias Loader = (URLRequest) async throws -> (Data, URLResponse)
    private struct RefreshState: Codable {
        var checkedAt: Date?
        var attemptedAt: Date?
    }
    private struct Pending {
        let token: UUID
        let task: Task<Elements, Error>
    }
    private let folder: URL
    private let seedURL: URL?
    private let loader: Loader
    private let now: () -> Date
    private var refreshState: [Int: RefreshState] = [:]
    private var pending: [Int: Pending] = [:]
    private var celestrakRetryAfter: Date = .distantPast
    init(folder: URL? = nil, seedURL: URL? = nil, now: @escaping () -> Date = Date.init, loader: Loader? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orbits", isDirectory: true)
        self.seedURL = seedURL ?? Bundle.main.url(forResource:"seed-tle",withExtension:"json")
        self.now = now
        self.loader = loader ?? { try await URLSession.shared.data(for: $0) }
        try? FileManager.default.createDirectory(at:self.folder,withIntermediateDirectories:true)
        if let data=try? Data(contentsOf:self.folder.appendingPathComponent("refresh-state.json")),
           let state=try? JSONDecoder().decode([Int:RefreshState].self,from:data) { refreshState=state }
    }
    func cached(id: Int) -> Elements? {
        var candidates: [Elements]=[]
        if let data = try? Data(contentsOf: folder.appendingPathComponent("\(id).json")),
           let value = try? JSONDecoder().decode(Elements.self, from: data), value.valid(for: id) { candidates.append(value) }
        if let seedURL,let data=try? Data(contentsOf:seedURL),let values=try? JSONDecoder().decode([Elements].self,from:data) {
            candidates.append(contentsOf:values.filter{$0.norad==id && $0.valid(for:id)})
        }
        return candidates.max { ($0.epoch ?? .distantPast)<($1.epoch ?? .distantPast) }
    }
    static func parseSatNOGS(_ data: Data,id: Int,date: Date = Date()) throws -> Elements {
        struct Entry: Decodable { let norad_cat_id: Int; let tle1: String; let tle2: String }
        let candidates=try JSONDecoder().decode([Entry].self,from:data).filter{$0.norad_cat_id==id}
            .compactMap{Elements.parse($0.tle1+"\n"+$0.tle2,id:id,date:date)}
        guard let result=candidates.filter({$0.ageDays(at:date)<30}).max(by:{($0.epoch ?? .distantPast)<($1.epoch ?? .distantPast)}) else { throw OrbitError.invalidElements }
        return result
    }
    func needsUpdate(id: Int) -> Bool {
        let date=now()
        if let checked=refreshState[id]?.checkedAt {
            let age=date.timeIntervalSince(checked)
            if age>=0 && age<7200 && cached(id:id) != nil { return false }
        }
        if let attempt=refreshState[id]?.attemptedAt {
            let age=date.timeIntervalSince(attempt)
            if age>=0 && age<300 { return false }
        }
        return true
    }
    func update(id: Int) async throws -> Elements {
        try Task.checkCancellation()
        if let pending=pending[id] {
            let result=try await pending.task.value
            try Task.checkCancellation()
            return result
        }
        guard needsUpdate(id:id) else {
            if let cached=cached(id:id) { return cached }
            throw OrbitError.network
        }
        let token=UUID()
        let task=Task { try await download(id:id) }
        pending[id]=Pending(token:token,task:task)
        defer { if pending[id]?.token==token { pending[id]=nil } }
        let result=try await task.value
        try Task.checkCancellation()
        return result
    }
    func cancelUpdates() {
        for request in pending.values { request.task.cancel() }
        pending=[:]
    }
    private func saveRefreshState() {
        if let data=try? JSONEncoder().encode(refreshState) {
            try? data.write(to:folder.appendingPathComponent("refresh-state.json"),options:.atomic)
        }
    }
    private func download(id: Int) async throws -> Elements {
        refreshState[id,default:RefreshState()].attemptedAt=now()
        saveRefreshState()
        // Only NORAD ID is sent; user's position never leaves the device.
        let sources=["https://celestrak.org/NORAD/elements/gp.php?CATNR=\(id)&FORMAT=TLE",
                     "https://db.satnogs.org/api/tle/?norad_cat_id=\(id)"]
        var lastError: Error=OrbitError.network
        for (index,source) in sources.enumerated() {
            try Task.checkCancellation()
            if index==0 && now()<celestrakRetryAfter { continue }
            do {
                var request=URLRequest(url:URL(string:source)!,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:15)
                request.setValue("PLS/1.5",forHTTPHeaderField:"User-Agent")
                let (data,response)=try await loader(request)
                try Task.checkCancellation()
                if index==0,let http=response as? HTTPURLResponse,[403,429].contains(http.statusCode) {
                    celestrakRetryAfter=now().addingTimeInterval(7200)
                }
                guard let http=response as? HTTPURLResponse,http.statusCode==200,data.count<32000 else { throw OrbitError.network }
                let date=now()
                let candidates: [Elements]
                if index==0 {
                    candidates=String(data:data,encoding:.utf8).flatMap{Elements.parse($0,id:id,date:date)}.map{[$0]} ?? []
                } else {
                    candidates=[try Self.parseSatNOGS(data,id:id,date:date)]
                }
                guard let remote=candidates.filter({$0.ageDays(at:date)<30}).max(by:{($0.epoch ?? .distantPast)<($1.epoch ?? .distantPast)}) else { throw OrbitError.invalidElements }
                // A provider can lag behind the bundled or previously downloaded orbit.
                let cached=cached(id:id)
                let result=(cached?.epoch ?? .distantPast)>(remote.epoch ?? .distantPast) ? cached! : remote
                try JSONEncoder().encode(result).write(to:folder.appendingPathComponent("\(id).json"),options:.atomic)
                refreshState[id,default:RefreshState()].checkedAt=date
                saveRefreshState()
                return result
            } catch {
                try Task.checkCancellation()
                lastError=error
            }
        }
        throw lastError
    }
}
