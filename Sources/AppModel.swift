import SwiftUI
import Network

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
    @Published private(set) var sessionContexts: [Int:SessionPredictionContext] = [:]
    @Published var autoSelectSatellite = UserDefaults.standard.bool(forKey:"autoSelectSatellite") {
        didSet {
            UserDefaults.standard.set(autoSelectSatellite,forKey:"autoSelectSatellite")
            if !autoSelectSatellite { automaticSelectionTask?.cancel(); automaticSelectionTask=nil }
        }
    }
    @Published var calculatingSessions = false
    private(set) var localSessionsReady = false
    @Published var orbitPresented = false
    @Published var scannerPresented = false
    @Published var nightSkyPresented = false
    @Published var pointingMessages = false
    @Published var homePanel: HomePanel?
    private(set) var orbitInitialDate: Date?
    private(set) var orbitInitialSatelliteID: Int?
    private var orbitPending = false
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
    let weatherService = SiteWeatherService()
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
    private var automaticSelectionTask: Task<Void,Never>?
    private var activationTask: Task<Void,Never>?
    private var remoteTask: Task<Void,Never>?
    private var remoteToken = UUID()
    private var networkCleanup: Task<Void,Never>?
    private var networkMonitor: NWPathMonitor?
    private var networkToken = UUID()
    private var networkAvailable = false
    private var nextRemoteCheck = Date.distantPast
    var recommendedSession: SessionRecommendation? {
        SessionRecommendation.best(satellites:satellites,windows:sessionWindows,contexts:sessionContexts,
                                   elements:fleetElements,observer:observer,minimumElevation:minElevation,
                                   date:clock,preferredID:selectedID)
    }
    var automaticSelectionAllowed: Bool { autoSelectSatellite && !pointing && !orbitPresented && !scannerPresented && !nightSkyPresented && !orbitPending && homePanel == nil && (!calculatingSessions || localSessionsReady) }
    func beginLocalSessionCalculation() { localSessionsReady=false; calculatingSessions=true }
    func completeLocalSessionCalculation() {
        localSessionsReady=true
        applyAutomaticSelectionIfNeeded()
    }
    func applyAutomaticSelectionIfNeeded() {
        guard automaticSelectionAllowed, automaticSelectionTask == nil, let candidate=recommendedSession else { return }
        if candidate.satellite.id == selectedID {
            let preferred=SessionRecommendation.preferredRelayMode(in:candidate.satellite,preferredID:modeID) ?? candidate.mode
            if modeID != preferred.id { modeID=preferred.id }
            return
        }
        automaticSelectionTask=Task { [weak self] in
            guard let self else { return }
            defer { automaticSelectionTask=nil }
            guard !Task.isCancelled, automaticSelectionAllowed,
                  let current=recommendedSession, current.satellite.id != selectedID else { return }
            await select(id:current.satellite.id,preferredModeID:current.mode.id)
        }
    }
    func selectManually(id: Int) async {
        autoSelectSatellite=false
        await select(id:id)
    }
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
            if preview.contains("night-sky") { nightSkyPresented = true }
            else if preview.contains("demo-chat") {
                training = true; pointing = true; pointingMessages = true
                pointingStyle = .radar
                axis = preview.contains("back") ? .back:.top
                sensors.preview(azimuth:135,elevation:45,axis:axis)
            }
            else if preview.contains("orbits") { orbitPresented = true }
            else if preview.contains("site-") { scannerPresented = true }
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
        startNetworkMonitoring()
        activationTask = Task { await select(id: selectedID) }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
    func deactivate() {
        activated=false; ticker?.cancel(); ticker=nil
        activationTask?.cancel(); activationTask=nil; selectionToken=UUID(); refreshToken=UUID(); updating=false
        passTask?.cancel(); predicting=false
        fleetTask?.cancel(); fleetToken=UUID(); calculatingSessions=false; localSessionsReady=false
        automaticSelectionTask?.cancel(); automaticSelectionTask=nil
        stopNetworkRequests()
        networkMonitor?.cancel(); networkMonitor=nil; networkToken=UUID(); networkAvailable=false
        sensors.stop(); UIApplication.shared.isIdleTimerDisabled=false
    }
    private func startNetworkMonitoring() {
        let token=UUID(); networkToken=token
        let monitor=NWPathMonitor(); networkMonitor=monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available=path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.activated, self.networkToken==token else { return }
                self.networkAvailable=available
                if !available { self.stopNetworkRequests() }
                self.weatherService.refreshIfNeeded(observer:self.observer,networkAvailable:available)
                if available { self.nextRemoteCheck = .distantPast; self.refreshRemoteDataIfNeeded() }
            }
        }
        monitor.start(queue:DispatchQueue(label:"ru.ploit.satellite.connectivity"))
    }
    private func stopNetworkRequests() {
        remoteTask?.cancel(); remoteTask=nil; remoteToken=UUID()
        weatherService.cancel()
        let previous=networkCleanup
        networkCleanup=Task { await previous?.value; await store.cancelUpdates() }
    }
    private func refreshRemoteDataIfNeeded() {
        guard activated, !screenshotMode, networkAvailable, remoteTask==nil else { return }
        let date=Date()
        guard date>=nextRemoteCheck || nextRemoteCheck.timeIntervalSince(date)>60 else { return }
        nextRemoteCheck=date.addingTimeInterval(60)
        let token=networkToken, requestToken=UUID(); remoteToken=requestToken
        let ids=[selectedID]+satellites.map(\.id).filter{$0 != selectedID}
        remoteTask=Task { [weak self] in
            guard let self else { return }
            await networkCleanup?.value
            defer { if remoteToken==requestToken { remoteTask=nil } }
            var changed=false
            for id in ids {
                guard !Task.isCancelled, activated, networkAvailable, networkToken==token else { return }
                guard await store.needsUpdate(id:id) else { continue }
                if let value=try? await store.update(id:id) {
                    guard !Task.isCancelled, activated, networkAvailable, networkToken==token else { return }
                    if fleetElements[id] != value {
                        fleetElements[id]=value; changed=true
                        if selectedID==id { elements=value; lastPrediction = .distantPast; error=nil }
                    }
                }
            }
            guard !Task.isCancelled, activated, networkAvailable, networkToken==token, remoteToken==requestToken else { return }
            if changed { sessionsUpdated = .distantPast; refreshSessions(force:true) }
        }
    }
    func select(id: Int, preferredModeID: String? = nil) async {
        let token = UUID(); selectionToken = token
        refreshToken = UUID(); updating = false
        clearSkyConfirmed=false
        selectedID = id; modeID = satellite?.primaryMode.id ?? "aprs"
        if let preferredModeID, satellite?.modes.contains(where:{$0.id == preferredModeID}) == true { modeID=preferredModeID }
        UserDefaults.standard.set(id, forKey: "selectedSatellite")
        look = nil; futureLook = nil; elements = nil; passes = []; error = nil
        passTask?.cancel(); predicting = false; passObserver = nil; lastPrediction = .distantPast
        let cached = await store.cached(id: id)
        guard !Task.isCancelled, selectionToken == token else { return }
        elements = cached
        fleetElements[id] = cached
        await loadFleetElements()
        guard !Task.isCancelled, selectionToken == token else { return }
        await tick()
        refreshRemoteDataIfNeeded()
    }
    func loadFleetElements() async {
        for id in satellites.map(\.id) where fleetElements[id] == nil {
            guard !Task.isCancelled else { return }
            fleetElements[id]=await store.cached(id:id)
        }
    }
    func refresh() async {
        guard !updating else { return }
        let id = selectedID, token = UUID(); refreshToken = token; updating = true
        defer { if refreshToken == token { updating = false } }
        do {
            await networkCleanup?.value
            let value = try await store.update(id: id)
            guard !Task.isCancelled, refreshToken == token, selectedID == id else { return }
            elements = value; fleetElements[id] = value; error = nil; lastPrediction = .distantPast
            refreshSessions(force:true)
            await tick()
        } catch { if refreshToken == token { self.error = error.localizedDescription } }
    }
    func tick(at date: Date = Date()) async {
        clock = date
        sensors.axis = axis
        if activated && !screenshotMode {
            weatherService.refreshIfNeeded(observer:observer,networkAvailable:networkAvailable)
            refreshRemoteDataIfNeeded()
        }
        if let observer {
            let moved=sessionsObserver.map { !SessionPredictionContext.sameLocation($0,observer) } ?? true
            if !calculatingSessions && (moved || sessionsMask != minElevation || clock.timeIntervalSince(sessionsUpdated)>300) { refreshSessions() }
        }
        applyAutomaticSelectionIfNeeded()
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
                guard self.observer.map({SessionPredictionContext.sameLocation($0,observer)}) == true,
                      minElevation == mask, fleetElements[elements.norad] == elements else { return }
                passes = values; sessionWindows[elements.norad] = values; passObserver = observer; lastPrediction = Date()
                sessionContexts[elements.norad]=SessionPredictionContext(observer:observer,minimumElevation:mask,elements:elements)
            } catch { if !Task.isCancelled, token == selectionToken { self.error = error.localizedDescription } }
        }
    }
    func refreshSessions(force: Bool = false) {
        guard let observer else {
            fleetTask?.cancel(); fleetToken=UUID(); calculatingSessions=false; localSessionsReady=false
            sessionWindows=[:]; sessionContexts=[:]; sessionsObserver=nil
            return
        }
        guard !calculatingSessions || force else { return }
        fleetTask?.cancel()
        let token=UUID(),date=Date(),mask=minElevation
        fleetToken=token; beginLocalSessionCalculation()
        if sessionsObserver.map({!SessionPredictionContext.sameLocation($0,observer)}) ?? true || sessionsMask != mask { sessionWindows=[:]; sessionContexts=[:] }
        sessionsObserver=observer; sessionsMask=mask
        let ids=satellites.map(\.id)
        fleetTask=Task {
            defer { if fleetToken==token { calculatingSessions=false; sessionsUpdated=Date(); applyAutomaticSelectionIfNeeded() } }
            // Load the complete offline catalogue before any network request.
            for id in ids {
                guard !Task.isCancelled, fleetToken==token else { return }
                if fleetElements[id] == nil { fleetElements[id] = await store.cached(id:id) }
            }
            for id in ids {
                guard !Task.isCancelled, fleetToken==token else { return }
                if let value=fleetElements[id], value.ageDays(at:date)<=14,
                   let windows=try? await fleetEngine.passes(elements:value,observer:observer,date:date,minElevation:mask) {
                    guard !Task.isCancelled, fleetToken==token else { return }
                    sessionWindows[id]=windows
                    sessionContexts[id]=SessionPredictionContext(observer:observer,minimumElevation:mask,elements:value)
                }
            }
            completeLocalSessionCalculation()
        }
    }
    func saveSettings() {
        UserDefaults.standard.set(manualLocation, forKey: "manualLocation")
        UserDefaults.standard.set(manualLat, forKey: "manualLat")
        UserDefaults.standard.set(manualLon, forKey: "manualLon")
        lastPrediction = .distantPast; passObserver = nil; look = nil; futureLook = nil; passes = []
        sessionWindows=[:]; sessionContexts=[:]
        refreshSessions(force:true)
        Task { await tick() }
    }
    func prepareOrbit(date: Date? = nil, satelliteID: Int? = nil) {
        orbitInitialDate = date
        orbitInitialSatelliteID = satelliteID ?? selectedID
        orbitPending = true
    }
    func presentPreparedOrbit() {
        guard orbitPending else { return }
        orbitPending = false
        leavePointing()
        orbitPresented = true
    }
    func openOrbits() {
        prepareOrbit()
        presentPreparedOrbit()
    }
    func enterPointing(training: Bool = false) { self.training = training; pointingMessages=false; clearSkyConfirmed=false; pointing = true; UIApplication.shared.isIdleTimerDisabled = true }
    func leavePointing() { pointing = false; training = false; pointingMessages=false; clearSkyConfirmed=false; pointingIntro = false; UIApplication.shared.isIdleTimerDisabled = false }
}
