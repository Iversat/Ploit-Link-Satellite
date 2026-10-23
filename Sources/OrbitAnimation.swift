import Foundation

// Simulation time advances from a monotonic clock, independently of UI timers.
struct OrbitClock {
    var date: Date
    var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    var rate: Double = 0
    var limit: Date = .distantFuture
    func value(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Date {
        min(limit,date.addingTimeInterval(max(0,now-uptime)*rate))
    }
}

struct OrbitMotion {
    let start: Date
    let step: Double
    let samples: [OrbitalState]
    var end: Date { start.addingTimeInterval(Double(max(0,samples.count-1))*step) }
    func state(at date: Date) -> OrbitalState? {
        let t=date.timeIntervalSince(start)/step
        guard step>0,samples.count>=2,t>=0,t<=Double(samples.count-1) else { return nil }
        let i=min(samples.count-2,Int(t)),f=t-Double(i),a=samples[i],b=samples[i+1]
        func lerp(_ a: Double,_ b: Double) -> Double { a+(b-a)*f }
        return OrbitalState(position:OrbitPoint(x:lerp(a.position.x,b.position.x),y:lerp(a.position.y,b.position.y),z:lerp(a.position.z,b.position.z)),
                            latitude:lerp(a.latitude,b.latitude),longitude:AimMath.wrap(a.longitude+AimMath.wrap(b.longitude-a.longitude)*f),
                            altitudeKm:lerp(a.altitudeKm,b.altitudeKm),periodSeconds:lerp(a.periodSeconds,b.periodSeconds))
    }
}

// Playback and display-link callbacks are serialized on the main actor.
@MainActor final class OrbitRenderFeed {
    struct Frame {
        var clock=OrbitClock(date:Date())
        var tracks: [Int:OrbitMotion]=[:]
        var active=true
        var revision: UInt64=0
    }
    private var frame=Frame()
    var onStop: (() -> Void)?
    func snapshot() -> Frame { frame }
    func update(clock: OrbitClock,tracks: [Int:OrbitMotion]) {
        frame.clock=clock; frame.tracks=tracks; frame.active=true
        frame.revision &+= 1
    }
    func stop() {
        frame.active=false; frame.tracks=[:]
        onStop?()
    }
}
