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

// A tiny locked value transfer; the render thread never calls JavaScript or SwiftUI.
final class OrbitRenderFeed {
    struct Frame {
        var clock=OrbitClock(date:Date())
        var tracks: [Int:OrbitMotion]=[:]
        var pathDates: [Int:Date]=[:]
        var ground=false
        var active=true
    }
    private let lock=NSLock()
    private var frame=Frame()
    func snapshot() -> Frame { lock.lock(); defer { lock.unlock() }; return frame }
    func update(clock: OrbitClock,tracks: [Int:OrbitMotion],pathDates: [Int:Date]) {
        lock.lock(); defer { lock.unlock() }
        frame.clock=clock; frame.tracks=tracks; frame.pathDates=pathDates; frame.active=true
    }
    func setGround(_ value: Bool) { lock.lock(); frame.ground=value; lock.unlock() }
    func stop() { lock.lock(); frame.active=false; frame.tracks=[:]; lock.unlock() }
}
