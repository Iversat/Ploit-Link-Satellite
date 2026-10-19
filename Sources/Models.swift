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
}

enum AimAxis: String, CaseIterable, Identifiable {
    case top, back
    var id: String { rawValue }
    var title: String { self == .top ? "Верхний торец" : "Задняя сторона" }
}

enum AimMath {
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
}
