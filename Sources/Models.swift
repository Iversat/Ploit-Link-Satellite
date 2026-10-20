import Foundation

struct RadioMode: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var uplinkMHz: Double?
    var downlinkMHz: Double?
    var detail: String
    var canRelay: Bool
}

struct Satellite: Codable, Identifiable, Hashable {
    var id: Int
    var name: String
    var subtitle: String
    var kind: String
    var modes: [RadioMode]
    var status: String
    var source: String
    var checked: String
    var primaryMode: RadioMode { modes[0] }
}

struct Elements: Codable, Equatable {
    var norad: Int
    var line1: String
    var line2: String
    var fetchedAt: Date
    var epoch: Date? {
        guard line1.count >= 32 else { return nil }
        let text = String(line1.dropFirst(18).prefix(14))
        guard let yy = Int(text.prefix(2)), let day = Double(text.dropFirst(2)), day >= 1, day < 367 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = yy < 57 ? 2000 + yy : 1900 + yy
        return calendar.date(from: DateComponents(year: year, month: 1, day: 1))?.addingTimeInterval((day - 1) * 86400)
    }
    func ageDays(at date: Date = Date()) -> Double { abs(date.timeIntervalSince(epoch ?? .distantPast)) / 86400 }
    func valid(for id: Int) -> Bool {
        guard norad == id, line1.count == 69, line2.count == 69,
              line1.hasPrefix("1 "), line2.hasPrefix("2 "),
              Int(line1.dropFirst(2).prefix(5).trimmingCharacters(in: .whitespaces)) == id,
              Int(line2.dropFirst(2).prefix(5).trimmingCharacters(in: .whitespaces)) == id,
              epoch != nil else { return false }
        return Self.checksum(line1) && Self.checksum(line2)
    }
    static func checksum(_ line: String) -> Bool {
        guard line.count == 69, let final = line.last?.wholeNumberValue else { return false }
        let sum = line.dropLast().reduce(0) { $0 + ($1.wholeNumberValue ?? ($1 == "-" ? 1 : 0)) }
        return sum % 10 == final
    }
    static func parse(_ text: String, id: Int, date: Date = Date()) -> Elements? {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let a = lines.first(where: { $0.hasPrefix("1 ") }), let b = lines.first(where: { $0.hasPrefix("2 ") }) else { return nil }
        let value = Elements(norad: id, line1: a, line2: b, fetchedAt: date)
        return value.valid(for: id) ? value : nil
    }
}

struct Observer: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var altitudeM: Double
    static let preview = Observer(latitude: 48.708, longitude: 44.513, altitudeM: 100)
}

struct Look: Codable {
    var azimuth: Double
    var elevation: Double
    var rangeKm: Double
    var rangeRate: Double
    var latitude: Double
    var longitude: Double
    var altitudeKm: Double
    func downlink(_ MHz: Double) -> Double { MHz * (1 - rangeRate / 299792.458) }
    func uplink(_ MHz: Double) -> Double { MHz * (1 + rangeRate / 299792.458) }
}

struct PassWindow: Codable, Identifiable {
    var rise: Double
    var culmination: Double
    var set: Double
    var maxElevation: Double
    var inProgress: Bool
    var id: Double { rise }
    var riseDate: Date { Date(timeIntervalSince1970: rise) }
    var setDate: Date { Date(timeIntervalSince1970: set) }
    var duration: TimeInterval { self.set - rise }
    func contains(_ date: Date) -> Bool { riseDate <= date && date < setDate }
}

enum SessionText {
    static func window(_ passes: [PassWindow], at date: Date) -> PassWindow? {
        passes.filter { $0.setDate > date }.min { $0.rise < $1.rise }
    }
    private static func formatter(_ format: String) -> DateFormatter {
        let value=DateFormatter(); value.locale = .autoupdatingCurrent
        value.timeZone = .autoupdatingCurrent; value.dateFormat=format; return value
    }
    private static let clockFormat=formatter("HH:mm")
    private static let timestampFormat=formatter("d MMM · HH:mm:ss")
    static func clock(_ date: Date) -> String { clockFormat.string(from:date) }
    static func timestamp(_ date: Date) -> String { timestampFormat.string(from:date) }
    static func countdown(_ seconds: TimeInterval) -> String {
        let value=max(0,Int(ceil(seconds))),hours=value/3600,minutes=value%3600/60
        if hours>0 { return "\(hours) ч \(minutes) мин" }
        if minutes>0 { return "\(minutes) мин \(value%60) с" }
        return "\(value) с"
    }
    static func interval(_ pass: PassWindow) -> String { "\(clock(pass.riseDate))–\(clock(pass.setDate))" }
    static func title(_ pass: PassWindow, at date: Date) -> String {
        pass.contains(date) ? "Сеанс сейчас · ещё \(countdown(pass.setDate.timeIntervalSince(date)))" : "До сеанса \(countdown(pass.riseDate.timeIntervalSince(date)))"
    }
}

struct OrbitPoint: Codable, Equatable {
    var x: Double; var y: Double; var z: Double
    // ECF +X is Greenwich, +Y is 90°E, +Z is the north pole.
    // SceneKit's sphere front is longitude 0, at scene +Z.
    var sceneX: Float { Float(y/6378.137) }
    var sceneY: Float { Float(z/6378.137) }
    var sceneZ: Float { Float(x/6378.137) }
}
struct OrbitalState: Codable {
    var position: OrbitPoint
    var latitude: Double
    var longitude: Double
    var altitudeKm: Double
    var periodSeconds: Double
}
struct OrbitalTrajectory: Codable {
    var orbit: [OrbitPoint]
    var ground: [OrbitPoint]
}

struct TrackingMotion {
    var bearingRate: Double
    var elevationRate: Double
    init(current: Look, future: Look, seconds: Double = 10) {
        bearingRate=abs(cos(current.elevation * .pi/180))<0.05 ? 0:AimMath.wrap(future.azimuth-current.azimuth)/seconds
        elevationRate=(future.elevation-current.elevation)/seconds
    }
    var instruction: String {
        let horizontal=abs(bearingRate)<0.02 ? nil : bearingRate>0 ? "вправо":"влево"
        let vertical=abs(elevationRate)<0.02 ? nil : elevationRate>0 ? "выше":"ниже"
        let parts=[horizontal,vertical].compactMap{$0}
        return parts.isEmpty ? "Следуйте за спутником" : "Дальше: "+parts.joined(separator:" · ")
    }
}

enum AimAxis: String, CaseIterable, Identifiable {
    case top, back
    var id: String { rawValue }
    var title: String { self == .top ? "Верхняя грань" : "Заднее стекло" }
    var instruction: String { self == .top ? "Направьте верхнюю грань iPhone на спутник" : "Направьте заднее стекло iPhone на спутник" }
}

enum PointingStyle: String, CaseIterable, Identifiable {
    case radar, earth
    var id: String { rawValue }
    var title: String { self == .radar ? "Круг" : "Земля" }
}

struct DirectionVector: Equatable {
    var north: Double
    var west: Double
    var up: Double
    var negative: DirectionVector { .init(north:-north,west:-west,up:-up) }
    func cross(_ b: DirectionVector) -> DirectionVector {
        .init(north:west*b.up-up*b.west,west:up*b.north-north*b.up,up:north*b.west-west*b.north)
    }
    func dot(_ b: DirectionVector) -> Double { north*b.north + west*b.west + up*b.up }
}

struct DeviceBasis {
    var x: DirectionVector
    var y: DirectionVector
    var z: DirectionVector
    func vector(for axis: AimAxis) -> DirectionVector { axis == .top ? y : z.negative }
}

// Azimuthal projection in the phone's screen axes, looking through rear glass (-Z).
// Unlike azimuth/elevation differences this also follows roll and works at zenith.
struct RearAimProjection {
    var x: Double
    var y: Double
    var angle: Double
    var behind: Bool
    init(azimuth: Double, elevation: Double, basis: DeviceBasis) {
        let az=azimuth * .pi/180, el=elevation * .pi/180
        let target=DirectionVector(north:cos(el)*cos(az),west:-cos(el)*sin(az),up:sin(el))
        let right=target.dot(basis.x), down = -target.dot(basis.y)
        let forward=target.dot(basis.z.negative)
        angle=acos(min(1,max(-1,forward))) * 180 / .pi
        behind=forward<0
        let length=hypot(right,down), radius=min(1,angle/45)
        if length>0.000001 { x=right/length*radius; y=down/length*radius }
        else { x=0; y=forward<0 ? -1:0 }
    }
}

// No free camera translation or inertia: the globe always remains at the origin.
struct GlobeCamera {
    var yaw: Double = 0
    var pitch: Double = 0
    var zoom: Double = 1
    mutating func drag(x: Double, y: Double, width: Double) {
        yaw=AimMath.wrap(yaw-x/max(1,width)*180)
        pitch=min(85,max(-85,pitch+y/max(1,width)*180))
    }
    mutating func magnify(_ scale: Double) { zoom=min(1.65,max(0.8,zoom*scale)) }
    var unitPosition: (x: Double,y: Double,z: Double) {
        let a=yaw * .pi/180,p=pitch * .pi/180
        return (sin(a)*cos(p),sin(p),cos(a)*cos(p))
    }
}

struct GlobeDrag {
    private var start=GlobeCamera()
    private var horizontal: Bool?
    mutating func begin(_ camera: GlobeCamera) { start=camera; horizontal=nil }
    mutating func update(x: Double, y: Double, width: Double) -> GlobeCamera {
        if horizontal == nil, hypot(x,y)>=6 { horizontal=abs(x)>=abs(y) }
        var result=start
        if let horizontal { result.drag(x:horizontal ? x:0,y:horizontal ? 0:y,width:width) }
        return result
    }
}

enum AimMath {
    static func withinSkyWindow(targetElevation: Double, axisElevation: Double, minimum: Double) -> Bool {
        targetElevation >= max(10,minimum) && axisElevation >= max(10,minimum)
    }
    static func wrap(_ degrees: Double) -> Double { ((degrees + 180).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) - 180 }
    static func separation(az1: Double, el1: Double, az2: Double, el2: Double) -> Double {
        let d = Double.pi / 180
        let dot = sin(el1*d)*sin(el2*d) + cos(el1*d)*cos(el2*d)*cos((az1-az2)*d)
        return acos(min(1, max(-1, dot))) / d
    }
    // Core Motion's north-referenced frame: X north, Y west, Z up.
    // Rotation-matrix rows express device axes in that reference frame.
    static func direction(north: Double, west: Double, up: Double) -> (az: Double, el: Double) {
        let az = atan2(-west, north) * 180 / .pi
        return ((az + 360).truncatingRemainder(dividingBy: 360), atan2(up, hypot(north, west)) * 180 / .pi)
    }
    static func direction(axis: AimAxis, basis: DeviceBasis) -> (az: Double, el: Double) {
        let v = basis.vector(for:axis)
        return direction(north:v.north,west:v.west,up:v.up)
    }
    // A complete orthonormal pose, used by deterministic simulator previews/tests.
    // Switching axes reprojects this same pose; it never reuses the old direction.
    static func pose(azimuth: Double, elevation: Double, aiming axis: AimAxis) -> DeviceBasis {
        let az = azimuth * .pi / 180, el = elevation * .pi / 180
        let target = DirectionVector(north:cos(el)*cos(az),west:-cos(el)*sin(az),up:sin(el))
        let side = DirectionVector(north:sin(az),west:cos(az),up:0)
        if axis == .top { return .init(x:side,y:target,z:side.cross(target)) }
        let z = target.negative
        return .init(x:side.cross(z),y:side,z:z)
    }
}
