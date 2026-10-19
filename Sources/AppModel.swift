import SwiftUI

@MainActor final class AppModel: ObservableObject {
    @Published var satellites: [Satellite] = []
    @Published var selectedID = UserDefaults.standard.integer(forKey: "selectedSatellite") == 0 ? 25544 : UserDefaults.standard.integer(forKey: "selectedSatellite")
    @Published var modeID = "aprs"
    @Published var look: Look?
    @Published var passes: [PassWindow] = []
    @Published var elements: Elements?
    @Published var error: String?
    @Published var updating = false
    @Published var predicting = false
    @Published var pointing = false
    @Published var training = false
    @Published var manualLocation = UserDefaults.standard.bool(forKey: "manualLocation")
    @Published var manualLat = UserDefaults.standard.string(forKey: "manualLat") ?? ""
    @Published var manualLon = UserDefaults.standard.string(forKey: "manualLon") ?? ""
    @Published var minElevation: Double = 10
    @Published var axis: AimAxis = AimAxis(rawValue:UserDefaults.standard.string(forKey:"aimAxis") ?? "") ?? .top {
        didSet { sensors.axis = axis; UserDefaults.standard.set(axis.rawValue,forKey:"aimAxis") }
    }
    @Published var pointingStyle: PointingStyle = PointingStyle(rawValue:UserDefaults.standard.string(forKey:"pointingStyle") ?? "") ?? .radar {
        didSet { UserDefaults.standard.set(pointingStyle.rawValue,forKey:"pointingStyle") }
    }
    @Published var pointingIntro = false
    let sensors = Sensors()
    private let engine = OrbitEngine()
    private let store = ElementStore()
    private var ticker: Task<Void, Never>?
    private var selectionToken = UUID()
    private var refreshToken = UUID()
    private var passTask: Task<Void, Never>?
    private var passObserver: Observer?
    private var lastPrediction = Date.distantPast
    private var activated = false
    var satellite: Satellite? { satellites.first { $0.id == selectedID } ?? satellites.first }
    var mode: RadioMode? { satellite?.modes.first { $0.id == modeID } ?? satellite?.primaryMode }
    var observer: Observer? {
        if manualLocation {
            guard let lat = Double(manualLat.replacingOccurrences(of: ",", with: ".")),
                  let lon = Double(manualLon.replacingOccurrences(of: ",", with: ".")),
                  (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
            return Observer(latitude: lat, longitude: lon, altitudeM: 0)
        }
        return sensors.observer
    }
    var stale: Bool { (elements?.ageDays() ?? 999) > 3 }
    var usable: Bool { (elements?.ageDays() ?? 999) <= 14 }
    var aboveHorizon: Bool { (look?.elevation ?? -90) > 0 }
    var target: (az: Double, el: Double)? {
        if training { return (135,45) }
        guard let look, usable else { return nil }
        return (look.azimuth,look.elevation)
    }
    var angularError: Double? {
        guard sensors.motionReady, let target else { return nil }
        return AimMath.separation(az1: sensors.azimuth, el1: sensors.elevation, az2: target.az, el2: target.el)
    }
    var aligned: Bool {
        guard let angularError, angularError < 8, sensors.northIsTrue, sensors.headingAccuracy >= 0, sensors.headingAccuracy <= 20 else { return false }
        return training || (aboveHorizon && usable)
    }
    init() {
        if let url = Bundle.main.url(forResource: "catalog", withExtension: "json"), let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([Satellite].self, from: data) { satellites = decoded }
    }
    func activate() {
        guard !activated else { return }
        activated = true
        #if DEBUG
        if NSClassFromString("XCTestCase") != nil { return }
        if let preview = ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--ui-screenshot-")}) {
            manualLocation = true; manualLat = "48.708"; manualLon = "44.513"
            if preview != "--ui-screenshot-home" {
                training = true; pointing = true
                axis = preview.contains("back") ? .back : .top
                pointingStyle = preview.contains("earth") ? .earth : .radar
                let seeking = preview.contains("seeking") || preview == "--ui-screenshot-pointing"
                sensors.preview(azimuth:seeking ? 95 : 135,elevation:seeking ? 25 : 45,axis:axis)
                pointingIntro = preview.contains("intro")
            }
            Task { await select(id: selectedID) }
            return
        }
        #endif
        sensors.start()
        UIApplication.shared.isIdleTimerDisabled = pointing
        Task { await select(id: selectedID) }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    func deactivate() { activated = false; ticker?.cancel(); ticker = nil; sensors.stop(); UIApplication.shared.isIdleTimerDisabled = false }
    func select(id: Int) async {
        let token = UUID(); selectionToken = token
        refreshToken = UUID(); updating = false
        selectedID = id; modeID = satellite?.primaryMode.id ?? "aprs"
        UserDefaults.standard.set(id, forKey: "selectedSatellite")
        look = nil; elements = nil; passes = []; error = nil
        passTask?.cancel(); predicting = false; passObserver = nil; lastPrediction = .distantPast
        let cached = await store.cached(id: id)
        guard selectionToken == token else { return }
        elements = cached
        await tick()
        if cached == nil || (cached?.ageDays() ?? 99) > 1 { await refresh() }
    }
    func refresh() async {
        guard !updating else { return }
        let id = selectedID, token = UUID(); refreshToken = token; updating = true
        defer { if refreshToken == token { updating = false } }
        do {
            let value = try await store.update(id: id)
            guard refreshToken == token, selectedID == id else { return }
            elements = value; error = nil; lastPrediction = .distantPast
            await tick()
        } catch { if refreshToken == token { self.error = error.localizedDescription } }
    }
    func tick() async {
        sensors.axis = axis
        guard let elements, let observer, usable else { look = nil; return }
        let token = selectionToken
        do {
            let position = try await engine.look(elements: elements, observer: observer, date: Date())
            guard token == selectionToken else { return }
            look = position
            let moved = passObserver.map { abs($0.latitude-observer.latitude) + abs($0.longitude-observer.longitude) > 0.03 } ?? true
            if !predicting && (moved || Date().timeIntervalSince(lastPrediction) > 300) { predict(elements: elements, observer: observer) }
        } catch { if token == selectionToken { self.error = error.localizedDescription; look = nil } }
    }
    private func predict(elements: Elements, observer: Observer) {
        predicting = true
        let token = selectionToken, mask = minElevation
        passTask = Task {
            defer { if token == selectionToken { predicting = false } }
            do {
                let values = try await engine.passes(elements: elements, observer: observer, date: Date(), minElevation: mask)
                guard !Task.isCancelled, token == selectionToken else { return }
                passes = values; passObserver = observer; lastPrediction = Date()
            } catch { if !Task.isCancelled, token == selectionToken { self.error = error.localizedDescription } }
        }
    }
    func saveSettings() {
        UserDefaults.standard.set(manualLocation, forKey: "manualLocation")
        UserDefaults.standard.set(manualLat, forKey: "manualLat")
        UserDefaults.standard.set(manualLon, forKey: "manualLon")
        lastPrediction = .distantPast; passObserver = nil; look = nil; passes = []
        Task { await tick() }
    }
    func enterPointing(training: Bool = false) { self.training = training; pointing = true; UIApplication.shared.isIdleTimerDisabled = true }
    func leavePointing() { pointing = false; training = false; pointingIntro = false; UIApplication.shared.isIdleTimerDisabled = false }
}
