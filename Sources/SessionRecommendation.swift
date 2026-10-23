import Foundation

struct SessionPredictionContext {
    let observer: Observer
    let minimumElevation: Double
    let elements: Elements

    // Ignore small GPS jitter; settings edits explicitly discard the cached context.
    static func sameLocation(_ a: Observer, _ b: Observer) -> Bool {
        abs(a.latitude-b.latitude)+abs(AimMath.wrap(a.longitude-b.longitude)) <= 0.03 && abs(a.altitudeM-b.altitudeM) <= 100
    }
    func matches(observer: Observer, minimumElevation: Double, elements: Elements) -> Bool {
        Self.sameLocation(self.observer,observer) && self.minimumElevation == minimumElevation && self.elements == elements
    }
}

struct SessionRecommendation {
    let satellite: Satellite
    let mode: RadioMode
    let window: PassWindow
    let date: Date
    let minimumElevation: Double
    var isCurrent: Bool { window.contains(date) }
    var isWithinHour: Bool { !isCurrent && window.riseDate.timeIntervalSince(date) <= 3600 }
    var headline: String {
        if isCurrent { return "Окно видимости сейчас · \(satellite.name)" }
        if isWithinHour { return "В течение часа · \(satellite.name)" }
        return "Ближайший пролёт · \(satellite.name)"
    }
    var detail: String {
        let duration=isCurrent ? "Ещё \(SessionText.countdown(window.setDate.timeIntervalSince(date)))" : "Через \(SessionText.countdown(window.riseDate.timeIntervalSince(date)))"
        return "\(duration) · \(SessionText.interval(window)) · выше \(Int(minimumElevation))°"
    }
    static func best(satellites: [Satellite], windows: [Int:[PassWindow]], contexts: [Int:SessionPredictionContext],
                     elements: [Int:Elements], observer: Observer?, minimumElevation: Double,
                     date: Date, preferredID: Int? = nil) -> SessionRecommendation? {
        guard let observer, observer.latitude.isFinite, observer.longitude.isFinite, observer.altitudeM.isFinite,
              (-90...90).contains(observer.latitude), (-180...180).contains(observer.longitude), minimumElevation.isFinite else { return nil }
        let candidates=satellites.compactMap { satellite -> SessionRecommendation? in
            guard let mode=satellite.modes.first(where:{ mode in
                mode.canRelay && (mode.uplinkMHz.map{$0.isFinite && $0>0} ?? false) && (mode.downlinkMHz.map{$0.isFinite && $0>0} ?? false)
            }), let tle=elements[satellite.id], tle.valid(for:satellite.id), tle.ageDays(at:date)<=3,
            let context=contexts[satellite.id], context.matches(observer:observer,minimumElevation:minimumElevation,elements:tle) else { return nil }
            let valid=(windows[satellite.id] ?? []).filter { pass in
                pass.rise.isFinite && pass.set.isFinite && pass.culmination.isFinite && pass.maxElevation.isFinite &&
                pass.rise < pass.set && (pass.rise...pass.set).contains(pass.culmination) &&
                pass.maxElevation >= max(10,minimumElevation) && pass.maxElevation<=90 && pass.setDate>date &&
                pass.riseDate<=date.addingTimeInterval(48*3600)
            }
            guard let window=SessionText.window(valid,at:date) else { return nil }
            return Self(satellite:satellite,mode:mode,window:window,date:date,minimumElevation:minimumElevation)
        }
        return candidates.min { a,b in
            let waitA=max(0,a.window.riseDate.timeIntervalSince(date)),waitB=max(0,b.window.riseDate.timeIntervalSince(date))
            if waitA != waitB { return waitA<waitB }
            if (a.satellite.id == preferredID) != (b.satellite.id == preferredID) { return a.satellite.id == preferredID }
            if a.window.maxElevation != b.window.maxElevation { return a.window.maxElevation>b.window.maxElevation }
            return a.satellite.id<b.satellite.id
        }
    }
}
