import SwiftUI

enum HomePanel: String, Identifiable {
    case satellites, passes, settings
    var id: String { rawValue }
}

@MainActor final class AppModel: ObservableObject {
    @Published var satellites: [Satellite] = []
    @Published var selectedID = UserDefaults.standard.integer(forKey: "selectedSatellite") == 0 ? 25544 : UserDefaults.standard.integer(forKey: "selectedSatellite")
    @Published var modeID = "aprs"
    @Published var look: Look?
    @Published var futureLook: Look?
    @Published var clock = Date()
    @Published var fleetElements: [Int:Elements] = [:]
    @Published var sessionWindows: [Int:[PassWindow]] = [:]
    @Published var calculatingSessions = false
    @Published var orbitPresented = false
    @Published var homePanel: HomePanel?
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
    @Published var minElevation: Double = 20
    @Published var clearSkyConfirmed = false
    @Published var axis: AimAxis = AimAxis(rawValue:UserDefaults.standard.string(forKey:"aimAxis") ?? "") ?? .top {
        didSet { sensors.axis = axis; UserDefaults.standard.set(axis.rawValue,forKey:"aimAxis") }
    }
    @Published var pointingStyle: PointingStyle = PointingStyle(rawValue:UserDefaults.standard.string(forKey:"pointingStyle") ?? "") ?? .radar {
        didSet { UserDefaults.standard.set(pointingStyle.rawValue,forKey:"pointingStyle") }
    }
    @Published var pointingIntro = false
    let sensors = Sensors()
    private let engine = OrbitEngine()
    private let fleetEngine = OrbitEngine()
    private let store = ElementStore()
    private var ticker: Task<Void, Never>?
    private var selectionToken = UUID()
    private var refreshToken = UUID()
    private var passTask: Task<Void, Never>?
    private var passObserver: Observer?
    private var lastPrediction = Date.distantPast
    private var activated = false
    private var fleetTask: Task<Void,Never>?
    private var fleetToken = UUID()
    private var sessionsObserver: Observer?
    private var sessionsMask: Double = -1
    private var sessionsUpdated = Date.distantPast
    private var screenshotMode = false
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
    var aboveMask: Bool { (look?.elevation ?? -90) >= max(10,minElevation) }
    var trackingMotion: TrackingMotion? {
        guard !training, let look, let futureLook else { return nil }
        return TrackingMotion(current:look,future:futureLook)
    }
    func session(for id: Int, at date: Date? = nil) -> PassWindow? {
        SessionText.window(sessionWindows[id] ?? (id == selectedID ? passes:[]),at:date ?? clock)
    }
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
        guard let angularError, angularError < 5, sensors.northIsTrue, sensors.headingAccuracy >= 0, sensors.headingAccuracy <= 20 else { return false }
        if training { return true }
        guard usable, clearSkyConfirmed, let look else { return false }
        return AimMath.withinSkyWindow(targetElevation:look.elevation,axisElevation:sensors.elevation,minimum:minElevation)
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
            screenshotMode = true
            manualLocation = true; manualLat = "48.708"; manualLon = "44.513"
            if preview.contains("orbits") { orbitPresented = true }
            else if preview == "--ui-screenshot-settings" { homePanel = .settings }
            else if preview.contains("catalogue") { homePanel = .satellites }
            else if !preview.contains("home") {
                training = true; pointing = true
                axis = preview.contains("back") ? .back : .top
                pointingStyle = preview.contains("earth") ? .earth : .radar
                let seeking = preview.contains("seeking") || preview == "--ui-screenshot-pointing"
                sensors.preview(azimuth:seeking ? 95 : 135,elevation:seeking ? 25 : 45,axis:axis)
                pointingIntro = preview.contains("intro")
            }
            Task {
                await select(id:selectedID)
                if preview.contains("unavailable") || preview.contains("skycheck") {
                    fleetTask?.cancel(); fleetToken=UUID(); passTask?.cancel()
                    predicting=false; calculatingSessions=false; training=false
                    let elevation=preview.contains("unavailable") ? -22.0:45.0
                    look=Look(azimuth:135,elevation:elevation,rangeKm:1200,rangeRate:0,latitude:0,longitude:0,altitudeKm:400)
                    sensors.preview(azimuth:135,elevation:45,axis:axis)
                    let now=Date(); clock=now
                    let unavailable=preview.contains("unavailable")
                    let pass=PassWindow(rise:now.addingTimeInterval(unavailable ? 600:-60).timeIntervalSince1970,culmination:now.addingTimeInterval(unavailable ? 750:90).timeIntervalSince1970,set:now.addingTimeInterval(unavailable ? 900:240).timeIntervalSince1970,maxElevation:60,inProgress:!unavailable)
                    sessionWindows[selectedID]=[pass]; passes=[pass]
                }
            }
            if preview.contains("settings-stress") {
                ticker=Task { [weak self] in
                    while !Task.isCancelled {
                        await self?.tick()
                        try? await Task.sleep(nanoseconds:500_000_000)
                    }
                }
            }
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
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
    func deactivate() { activated = false; ticker?.cancel(); ticker = nil; fleetTask?.cancel(); fleetToken=UUID(); calculatingSessions=false; sensors.stop(); UIApplication.shared.isIdleTimerDisabled = false }
    func select(id: Int) async {
        let token = UUID(); selectionToken = token
        refreshToken = UUID(); updating = false
        clearSkyConfirmed=false
        selectedID = id; modeID = satellite?.primaryMode.id ?? "aprs"
        UserDefaults.standard.set(id, forKey: "selectedSatellite")
        look = nil; futureLook = nil; elements = nil; passes = []; error = nil
        passTask?.cancel(); predicting = false; passObserver = nil; lastPrediction = .distantPast
        let cached = await store.cached(id: id)
        guard selectionToken == token else { return }
        elements = cached
        fleetElements[id] = cached
        await loadFleetElements()
        guard selectionToken == token else { return }
        await tick()
        if !screenshotMode && (cached == nil || (cached?.ageDays() ?? 99) > 1) { await refresh() }
    }
    func loadFleetElements() async {
        for id in satellites.map(\.id) where fleetElements[id] == nil {
            fleetElements[id]=await store.cached(id:id)
        }
    }
    func refresh() async {
        guard !updating else { return }
        let id = selectedID, token = UUID(); refreshToken = token; updating = true
        defer { if refreshToken == token { updating = false } }
        do {
            let value = try await store.update(id: id)
            guard refreshToken == token, selectedID == id else { return }
            elements = value; fleetElements[id] = value; error = nil; lastPrediction = .distantPast
            await tick()
        } catch { if refreshToken == token { self.error = error.localizedDescription } }
    }
    func tick(at date: Date = Date()) async {
        clock = date
        sensors.axis = axis
        if let observer {
            let moved=sessionsObserver.map { abs($0.latitude-observer.latitude)+abs($0.longitude-observer.longitude)>0.03 } ?? true
            if !calculatingSessions && (moved || sessionsMask != minElevation || clock.timeIntervalSince(sessionsUpdated)>300) { refreshSessions() }
        }
        guard let elements, let observer, elements.ageDays(at:date)<=14 else { look = nil; futureLook=nil; return }
        let token = selectionToken
        do {
            let date=clock
            let position = try await engine.look(elements: elements, observer: observer, date: date)
            let future = try await engine.look(elements: elements, observer: observer, date: date.addingTimeInterval(10))
            guard token == selectionToken else { return }
            look = position; futureLook = future
            if !aboveMask && clearSkyConfirmed { clearSkyConfirmed=false }
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
                let values = try await fleetEngine.passes(elements: elements, observer: observer, date: Date(), minElevation: mask)
                guard !Task.isCancelled, token == selectionToken else { return }
                passes = values; sessionWindows[elements.norad] = values; passObserver = observer; lastPrediction = Date()
            } catch { if !Task.isCancelled, token == selectionToken { self.error = error.localizedDescription } }
        }
    }
    func refreshSessions(force: Bool = false) {
        guard let observer, !calculatingSessions || force else { return }
        fleetTask?.cancel()
        let token=UUID(),date=Date(),mask=minElevation
        fleetToken=token; calculatingSessions=true
        if sessionsObserver.map({abs($0.latitude-observer.latitude)+abs($0.longitude-observer.longitude)>0.03}) ?? true || sessionsMask != mask { sessionWindows=[:] }
        sessionsObserver=observer; sessionsMask=mask
        let ids=satellites.map(\.id)
        fleetTask=Task {
            defer { if fleetToken==token { calculatingSessions=false; sessionsUpdated=Date() } }
            // Load the complete offline catalogue before any network request.
            for id in ids {
                guard !Task.isCancelled, fleetToken==token else { return }
                if fleetElements[id] == nil { fleetElements[id] = await store.cached(id:id) }
            }
            for id in ids {
                guard !Task.isCancelled, fleetToken==token else { return }
                if let value=fleetElements[id], value.ageDays(at:date)<=14,
                   let windows=try? await fleetEngine.passes(elements:value,observer:observer,date:date,minElevation:mask) {
                    guard fleetToken==token else { return }; sessionWindows[id]=windows
                }
            }
            guard !screenshotMode else { return }
            for id in ids {
                guard !Task.isCancelled, fleetToken==token else { return }
                if force || (fleetElements[id]?.ageDays(at:date) ?? 999)>1 {
                    if let value=try? await store.update(id:id) {
                        guard fleetToken==token else { return }
                        fleetElements[id]=value
                        if selectedID==id { elements=value; lastPrediction = .distantPast }
                        if let windows=try? await fleetEngine.passes(elements:value,observer:observer,date:date,minElevation:mask) {
                            guard fleetToken==token else { return }; sessionWindows[id]=windows
                        }
                    }
                }
            }
        }
    }
    func saveSettings() {
        UserDefaults.standard.set(manualLocation, forKey: "manualLocation")
        UserDefaults.standard.set(manualLat, forKey: "manualLat")
        UserDefaults.standard.set(manualLon, forKey: "manualLon")
        lastPrediction = .distantPast; passObserver = nil; look = nil; futureLook = nil; passes = []
        refreshSessions(force:true)
        Task { await tick() }
    }
    func enterPointing(training: Bool = false) { self.training = training; clearSkyConfirmed=false; pointing = true; UIApplication.shared.isIdleTimerDisabled = true }
    func leavePointing() { pointing = false; training = false; clearSkyConfirmed=false; pointingIntro = false; UIApplication.shared.isIdleTimerDisabled = false }
}
